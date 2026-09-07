import SwiftUI
import RoboCore

// MARK: - Duplicates

struct DuplicatesScreen: View {
    @Environment(AppModel.self) private var model
    /// Path-keyed selection (file ids ARE paths — stable). Group UUIDs are
    /// recreated whenever a trash batch prunes groups, so keying by group
    /// orphaned the user's review state mid-session (UI-2).
    @State private var selectedPaths: Set<String> = []
    @State private var confirmTrash = false

    /// Resolved against current groups — stale paths (already trashed) resolve
    /// to nothing and are pruned after each batch.
    private var selectedFiles: [(url: URL, size: Int64)] {
        model.duplicates.flatMap { group in
            group.files.filter { selectedPaths.contains($0.id) }
                .map { ($0.url, $0.size) }
        }
    }

    private var selectedBytes: Int64 {
        selectedFiles.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The scope picker is always visible — J5's flow is "scope
            // Downloads → run", not "run → discover the scope picker".
            if model.duplicatePhase != .running && !model.duplicates.isEmpty {
                headerBar
            } else {
                scopeBar
            }

            if model.duplicatePhase == .running {
                ProgressView(model.duplicateStageText ?? "Scanning for duplicates…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.duplicates.isEmpty {
                ScanPromptView(
                    title: model.duplicatePhase == .done ? "No duplicates found" : "Find duplicate files",
                    message: model.duplicatePhase == .done
                        ? "No byte-identical duplicate files were found in the scanned area."
                        : "Duplicates are verified byte-for-byte (size → partial hash → full hash) before anything is suggested. Only exact copies are reported. The newest copy in each group is kept and the rest are preselected for review.",
                    actionTitle: "Find Duplicates",
                    quickActionTitle: nil,
                    onScan: { model.findDuplicates() },
                    onQuickScan: nil
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .navigationTitle("Duplicates")
        .onAppear {
            if selectedPaths.isEmpty && !model.duplicates.isEmpty {
                preselectKeepNewest(model.duplicates)
            }
        }
        // Preselection happens ONLY when a scan completes — never on data
        // mutations (a trash batch from any screen used to wipe the user's
        // manual deselections and could re-select files they chose to keep).
        .onChange(of: model.duplicatePhase) { old, new in
            if new == .done && old != .done {
                preselectKeepNewest(model.duplicates)
            }
        }
        .confirmationDialog(
            "Move \(selectedFiles.count) duplicate copies to the Trash?",
            isPresented: $confirmTrash,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                let urls = selectedFiles.map(\.url)
                model.trashUserSelected(urls: urls)
                // Prune only the trashed paths — the user's remaining review
                // state (deselections included) survives the batch.
                selectedPaths.subtract(urls.map { $0.path })
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each group keeps at least one copy. Originals stay untouched; removed copies can be restored from the Trash.")
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.duplicates) { group in
                        DuplicateGroupRow(group: group,
                                          selectedPaths: selectedPaths,
                                          onToggle: { toggle($0, in: group) },
                                          onReveal: { url in NSWorkspace.shared.activateFileViewerSelecting([url]) })
                    }
                }
                .padding(16)
            }
            if !selectedFiles.isEmpty {
                footer
            }
        }
    }

    private var headerBar: some View {
        HStack {
            let wasted = model.duplicates.reduce(0) { $0 + $1.wastedBytes }
            Label("\(model.duplicates.count) groups — \(wasted.bytesFormatted) wasted", systemImage: "square.on.square")
                .font(.callout.weight(.medium))
            Spacer()
            Picker("Scope", selection: Binding(
                get: { model.duplicateScope },
                set: { model.duplicateScope = $0 }
            )) {
                ForEach(AppModel.DuplicateScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .frame(width: 140)
            Button("Rescan") { model.findDuplicates() }.controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(Divider(), alignment: .bottom)
    }

    /// Compact scope bar for the empty/running states (the full header
    /// with stats and Rescan appears once results exist).
    private var scopeBar: some View {
        HStack {
            Text("Scope").font(.caption).foregroundStyle(.secondary)
            Picker("Scope", selection: Binding(
                get: { model.duplicateScope },
                set: { model.duplicateScope = $0 }
            )) {
                ForEach(AppModel.DuplicateScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .frame(width: 150)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .overlay(Divider(), alignment: .bottom)
    }

    private var footer: some View {
        HStack {
            Text("\(selectedFiles.count) copies selected · \(selectedBytes.bytesFormatted)")
                .font(.callout.monospacedDigit())
            Spacer()
            Button("Move Selected to Trash…", role: .destructive) { confirmTrash = true }
                .buttonStyle(.borderedProminent).tint(.red)
        }
        .padding(12)
        .background(.regularMaterial)
        .overlay(Divider(), alignment: .top)
    }

    private func toggle(_ file: DuplicateFile, in group: DuplicateGroup) {
        if selectedPaths.contains(file.id) {
            selectedPaths.remove(file.id)
        } else {
            // Keep-one enforcement: at most (count - 1) selectable per group.
            let groupSelected = group.files.filter { selectedPaths.contains($0.id) }.count
            if groupSelected < group.files.count - 1 {
                selectedPaths.insert(file.id)
            }
        }
    }

    /// Preselects every copy except the newest in each group (latest modDate;
    /// ties broken by path) — keep-one is still enforced, the user just reviews
    /// instead of hand-picking.
    private func preselectKeepNewest(_ groups: [DuplicateGroup]) {
        var preselected = Set<String>()
        for group in groups where group.files.count > 1 {
            let sorted = group.files.sorted { a, b in
                let da = a.modDate ?? .distantPast
                let db = b.modDate ?? .distantPast
                if da != db { return da > db }
                return a.url.path < b.url.path
            }
            guard let keep = sorted.first else { continue }
            for file in group.files where file.id != keep.id {
                preselected.insert(file.id)
            }
        }
        guard !preselected.isEmpty else { return }
        selectedPaths = preselected
    }
}

struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    let selectedPaths: Set<String>
    let onToggle: (DuplicateFile) -> Void
    let onReveal: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(group.fileSize.bytesFormatted, systemImage: "doc.on.doc")
                    .font(.callout.weight(.medium).monospacedDigit())
                Text("×\(group.files.count) copies").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(group.wastedBytes.bytesFormatted) wasted")
                    .font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(.orange)
            }
            ForEach(group.files) { file in
                fileRow(file)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    /// A real Button (keyboard + VoiceOver reachable — A11y-1) rather than a
    /// tappable image.
    private func fileRow(_ file: DuplicateFile) -> some View {
        let selected = selectedPaths.contains(file.id)
        return Button {
            onToggle(file)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? Color.red : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.url.lastPathComponent).font(.caption.weight(.medium))
                    Text(file.url.deletingLastPathComponent().path)
                        .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let date = file.modDate {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .opacity(selected ? 0.75 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(file.url.lastPathComponent), \(selected ? "selected for removal" : "kept")")
        .overlay(alignment: .trailing) {
            Button {
                onReveal(file.url)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Reveal \(file.url.lastPathComponent) in Finder")
            .padding(.trailing, 4)
        }
    }
}
