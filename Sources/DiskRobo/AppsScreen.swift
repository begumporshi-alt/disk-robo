import SwiftUI
import RoboCore

// MARK: - Apps screen

struct AppsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var selectedApp: AppFootprint?

    var body: some View {
        Group {
            switch model.appPhase {
            case .running:
                ProgressView("Measuring application footprints…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .done:
                content
            default:
                ScanPromptView(
                    title: "App Storage Intelligence",
                    message: "See the total footprint of every app — bundle, Application Support, caches, containers, and logs — including data apps hide in your Library.",
                    actionTitle: "Analyze Apps",
                    quickActionTitle: nil,
                    onScan: { model.analyzeApps() },
                    onQuickScan: nil
                )
            }
        }
        .navigationTitle("Apps")
        // UI-4: keep the selection pointing at a live footprint after the
        // model's arrays are replaced (re-analysis) or pruned (uninstalls).
        .onChange(of: model.apps) { _, newApps in
            selectedApp = selectedApp.flatMap { sel in newApps.first { $0.id == sel.id } }
        }
        .onChange(of: model.leftovers) { _, newLeftovers in
            selectedApp = selectedApp.flatMap { sel in newLeftovers.first { $0.id == sel.id } }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            headerBar
            HStack(spacing: 0) {
                List(selection: $selectedApp) {
                    Section("Installed — \(model.apps.count)") {
                        ForEach(model.apps) { app in
                            AppRow(app: app).tag(app)
                        }
                    }
                    if !model.leftovers.isEmpty {
                        Section("Leftovers — data from removed apps") {
                            ForEach(model.leftovers) { leftover in
                                AppRow(app: leftover, isLeftover: true).tag(leftover)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)

                Divider()

                if let app = selectedApp {
                    AppDetail(app: app)
                } else {
                    ContentUnavailableView("Select an application",
                                           systemImage: "app.dashed",
                                           description: Text("Choose an app to see its full storage footprint."))
                }
            }

            if let outcome = model.executionOutcome {
                OutcomeBanner(outcome: outcome) { model.executionOutcome = nil }
            }
        }
    }

    private var headerBar: some View {
        HStack {
            Label("\(model.apps.count) apps · \(model.apps.reduce(0) { $0 + $1.totalBytes }.bytesFormatted) total",
                  systemImage: "app.dashed")
                .font(.callout.weight(.medium))
            Spacer()
            Button("Re-analyze") { model.analyzeApps() }.controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(Divider(), alignment: .bottom)
    }
}

struct AppRow: View {
    let app: AppFootprint
    var isLeftover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isLeftover ? "externaldrive.badge.exclamationmark" : "app")
                .foregroundStyle(isLeftover ? .orange : .accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1)
                if isLeftover {
                    Text("app no longer installed").font(.caption2).foregroundStyle(.orange)
                } else if app.bundleID != nil {
                    Text(app.bundleID!).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            Text(app.totalBytes.bytesFormatted).font(.callout.monospacedDigit())
        }
        .padding(.vertical, 1)
    }
}

struct AppDetail: View {
    @Environment(AppModel.self) private var model
    let app: AppFootprint
    @State private var confirmCleanCaches = false

    /// The green, regenerable portion of this app (spec J6: "Clean caches"
    /// offers only the cache component, never app data).
    private var cachesComponent: AppComponent? {
        app.components.first { $0.kind == .caches }
    }

    private var components: [(String, Int64)] {
        [("Application bundle", app.bundleBytes),
         ("Application Support", app.applicationSupportBytes),
         ("Caches", app.cachesBytes),
         ("Containers", app.containersBytes),
         ("Group Containers", app.groupContainersBytes),
         ("Logs", app.logsBytes),
         ("Saved State", app.savedStateBytes),
         ("Preferences", app.preferencesBytes),
         ("Other library data", app.otherLibraryBytes)]
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(app.name).font(.title2.weight(.semibold))
                    Text(app.totalBytes.bytesFormatted).font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                    if app.isLeftover {
                        Label("The app that created this data is no longer installed. Review before removing — shared folder names can be ambiguous.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                if !components.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(components, id: \.0) { name, bytes in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(name == "Caches" ? Color.green : Color.accentColor)
                                    .frame(width: 8, height: 8)
                                Text(name).font(.callout)
                                Spacer()
                                Text(bytes.bytesFormatted).font(.callout.monospacedDigit())
                                    .foregroundStyle(name == "Caches" ? .green : .primary)
                            }
                        }
                        if app.cachesBytes > 0 {
                            Text("Caches are safe to clean — the app rebuilds them as needed.")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }
                    }
                    .padding(14)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                }

                if !app.isLeftover, let caches = cachesComponent {
                    Button {
                        confirmCleanCaches = true
                    } label: {
                        Label("Clean \(caches.bytes.bytesFormatted) of Caches…", systemImage: "sparkles")
                    }
                    .alert("Move \(app.name)'s caches to the Trash?", isPresented: $confirmCleanCaches) {
                        Button("Move to Trash", role: .destructive) {
                            model.trashUserSelected(urls: [URL(fileURLWithPath: caches.path)])
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("\(app.name) rebuilds its caches as needed — this is the safe, regenerable portion of its footprint. Moves to the Trash, safety-checked.")
                    }
                }

                if !app.path.isEmpty {
                    LabeledRow("Bundle path", app.path)
                }
                if !app.libraryPath.isEmpty {
                    LabeledRow("Data path", app.libraryPath)
                }

                if !app.path.isEmpty {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
