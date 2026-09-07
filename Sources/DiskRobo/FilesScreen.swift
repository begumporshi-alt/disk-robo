import SwiftUI
import RoboCore
import QuickLookUI

/// Quick Look via QLPreviewView (macOS 14 compatible).
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            return QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        }
        view.previewItem = url as QLPreviewItem
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if (nsView.previewItem as? URL) != url {
            nsView.previewItem = url as QLPreviewItem
        }
    }
}

// MARK: - Files explorer

struct FilesScreen: View {
    @Environment(AppModel.self) private var model
    @State private var minSizeIndex = 1
    @State private var categoryFilter: StorageCategory?
    @State private var searchText = ""
    @State private var selection = Set<String>()
    @State private var quickLookURL: URL?
    @State private var confirmTrash = false
    /// PF-3: the filtered file list is computed ONCE per data/filter change —
    /// the old computed property ran a `fileExists` stat on every row during
    /// every body evaluation (and once more per selected row in selectedBytes).
    @State private var filteredFiles: [FileRecord] = []
    @State private var filesByID: [String: FileRecord] = [:]

    private let sizeThresholds: [(String, Int64)] = [
        ("Any size", 0), ("≥ 100 MB", 100_000_000), ("≥ 500 MB", 500_000_000),
        ("≥ 1 GB", 1_000_000_000), ("≥ 5 GB", 5_000_000_000),
    ]

    private func rebuildFiles() {
        var list = model.scanResult?.largestFiles ?? []
        // Hide items that no longer exist (trashed via Disk Robo are pruned
        // from the model; this covers deletions made outside the app).
        let fm = FileManager.default
        list = list.filter { fm.fileExists(atPath: $0.url.path) }
        let threshold = sizeThresholds[minSizeIndex].1
        if threshold > 0 { list = list.filter { $0.size >= threshold } }
        if let categoryFilter { list = list.filter { $0.category == categoryFilter } }
        if !searchText.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        filteredFiles = list
        filesByID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        content
            .sheet(isPresented: Binding(
                get: { quickLookURL != nil },
                set: { if !$0 { quickLookURL = nil } }
            )) {
                if let url = quickLookURL {
                    QuickLookView(url: url)
                        .frame(minWidth: 520, minHeight: 420)
                }
            }
            .alert(
                "Move \(selection.count) item(s) to the Trash?",
                isPresented: $confirmTrash
            ) {
                Button("Move to Trash", role: .destructive) {
                    let urls = selection.compactMap { filesByID[$0]?.url }
                    model.trashUserSelected(urls: urls)
                    selection.removeAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Items can be restored from the Trash. Disk Robo never empties the Trash for you.")
            }
    }

    /// Split from `body` — the full modifier chain in one expression exceeds
    /// the type-checker's budget (known gotcha).
    private var content: some View {
        Group {
            if model.scanResult == nil {
                emptyState
            } else {
                table
            }
        }
        .navigationTitle("Files")
        .modifier(RebuildTriggers(
            rebuild: rebuildFiles,
            rebuildAndPruneSelection: {
                rebuildFiles()
                selection.formIntersection(Set(filteredFiles.map(\.id)))
            },
            scanStartedAt: model.scanResult?.startedAt,
            outcomeStartedAt: model.executionOutcome?.startedAt,
            minSizeIndex: minSizeIndex,
            categoryFilter: categoryFilter,
            searchText: searchText))
    }

    private var emptyState: some View {
        ScanPromptView(
            title: "No scan results",
            message: "Scan your home to find the largest files, then review, Quick Look, or safely trash them.",
            onScan: { model.startFullScan() },
            onQuickScan: { model.startQuickScan() }
        )
    }

    private var table: some View {
        VStack(spacing: 0) {
            filterBar
            Table(filteredFiles, selection: $selection) {
                TableColumn("Name") { file in
                    HStack(spacing: 6) {
                        Image(systemName: file.isPackage ? "shippingbox" : "doc")
                            .foregroundStyle(Theme.color(for: file.category))
                        Text(file.name).lineLimit(1)
                    }
                }
                TableColumn("Folder") { file in
                    Text(file.url.deletingLastPathComponent().path)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                TableColumn("Size") { file in
                    Text(file.size.bytesFormatted).monospacedDigit()
                }
                .width(min: 80, ideal: 90)

                TableColumn("Category") { file in
                    Text(file.category.displayName).font(.caption)
                }
                TableColumn("Modified") { file in
                    if let date = file.modDate {
                        Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption)
                    }
                }
            }
            if !selection.isEmpty {
                filesActionBar
            }
        }
        .onDeleteCommand {
            if !selection.isEmpty { confirmTrash = true }
        }
    }

    /// Fixed action bar below the table (not a floating overlay) so selection
    /// actions are always clearly visible.
    private var filesActionBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text("\(selection.count) selected")
                .font(.callout.weight(.semibold))
            Text("· \(selectedBytes.bytesFormatted)")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)

            Spacer()

            Button {
                selection.removeAll()
            } label: {
                Text("Clear")
            }
            .controlSize(.regular)

            Button {
                let urls = selection.compactMap { filesByID[$0]?.url }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            } label: {
                Label("Reveal", systemImage: "folder")
            }

            if selection.count == 1, let file = selection.first.flatMap({ filesByID[$0] }) {
                Button {
                    quickLookURL = file.url
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }
            }

            Button(role: .destructive) {
                confirmTrash = true
            } label: {
                Label("Move \(selection.count) to Trash", systemImage: "trash.fill")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.delete, modifiers: [])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(Divider(), alignment: .top)
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Size", selection: $minSizeIndex) {
                ForEach(Array(sizeThresholds.enumerated()), id: \.offset) { index, entry in
                    Text(entry.0).tag(index)
                }
            }
            .frame(width: 130)

            Picker("Category", selection: $categoryFilter) {
                Text("All categories").tag(StorageCategory?.none)
                ForEach(StorageCategory.allCases) { category in
                    Text(category.displayName).tag(StorageCategory?.some(category))
                }
            }
            .frame(width: 170)

            TextField("Search file names", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)

            Spacer()

            Text("\(filteredFiles.count) files")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .overlay(Divider(), alignment: .bottom)
    }

    private var selectedBytes: Int64 {
        selection.reduce(0) { $0 + (filesByID[$1]?.size ?? 0) }
    }
}

/// Rebuilds the cached filtered list whenever the data or filters change.
/// A ViewModifier because the inline modifier chain exceeded the type-checker.
private struct RebuildTriggers: ViewModifier {
    let rebuild: () -> Void
    let rebuildAndPruneSelection: () -> Void
    let scanStartedAt: Date?
    let outcomeStartedAt: Date?
    let minSizeIndex: Int
    let categoryFilter: StorageCategory?
    let searchText: String

    func body(content: Content) -> some View {
        content
            .onAppear(perform: rebuild)
            .onChange(of: scanStartedAt) { _, _ in rebuild() }
            .onChange(of: outcomeStartedAt) { _, _ in rebuildAndPruneSelection() }
            .onChange(of: minSizeIndex) { _, _ in rebuild() }
            .onChange(of: categoryFilter) { _, _ in rebuild() }
            .onChange(of: searchText) { _, _ in rebuild() }
    }
}
