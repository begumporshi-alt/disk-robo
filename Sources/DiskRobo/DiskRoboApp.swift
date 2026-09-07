import SwiftUI
import RoboCore

@main
struct DiskRoboApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Disk Robo") {
            Group {
                if model.settings.settings.onboardingCompleted {
                    MainInterface()
                } else {
                    OnboardingScreen()
                }
            }
            .environment(model)
            .preferredColorScheme(.dark)
            .frame(minWidth: 1180, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 640)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan Home") { model.startFullScan() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Quick Scan") { model.startQuickScan() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Cancel Scan") { model.cancelScan() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(model.scanPhase != .running)
            }
        }

        // Menu bar companion (spec §32) — kept intentionally light: data comes
        // from the already-running model; no extra scanning or polling.
        MenuBarExtra {
            MenuBarDashboard(model: model)
        } label: {
            Label("Disk Robo", systemImage: "internaldrive.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Window frame guard

/// Keeps the main window inside the screen's visible frame (menu bar + Dock).
/// macOS restores the previous frame as-is — on short screens a maximized
/// frame parks the bottom status row underneath the Dock, where it can't be
/// seen or reached. Runs once at launch and again when display geometry
/// changes; never moves a window that already fits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { self.constrainMainWindow() }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    @objc private func screenParametersChanged() {
        DispatchQueue.main.async { self.constrainMainWindow() }
    }

    private func constrainMainWindow() {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }),
              let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        guard frame.width > visible.width || frame.height > visible.height
                || frame.minX < visible.minX || frame.minY < visible.minY
                || frame.maxX > visible.maxX || frame.maxY > visible.maxY else { return }
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: false)
    }
}

// MARK: - Menu bar companion

struct MenuBarDashboard: View {
    /// Injected directly: MenuBarExtra content does not inherit the window
    /// scene's environment.
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                HealthRing(score: model.health?.value, size: 46, lineWidth: 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.primaryVolume.map { "\(Format.bytes($0.availableBytes)) free" } ?? "Disk Robo")
                        .font(.system(.headline, design: .rounded)).monospacedDigit()
                    Text(model.primaryVolume.map { "\(Format.percent($0.freeRatio)) of \($0.name)" } ?? "No volume")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            labelRow(icon: "sparkles", tint: .green,
                     text: greenRecoverableText)

            if let finding = model.radarFindings.first(where: { $0.severity >= 4 }) {
                labelRow(icon: "exclamationmark.triangle", tint: .orange,
                         text: finding.title)
            } else if let finding = model.radarFindings.first {
                labelRow(icon: "dot.radiowaves.left.and.right", tint: .blue,
                         text: finding.title)
            }

            Divider()

            if model.scanPhase == .running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Scanning… \(model.scanProgress.map { Format.bytes($0.bytesSeen) } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button("Quick Scan") { model.startQuickScan() }
                    .controlSize(.small)
            }

            Divider()

            Button {
                model.selectedSection = .overview
                openMainWindow()
            } label: {
                Label("Open Dashboard", systemImage: "square.grid.2x2")
            }
            Button {
                model.selectedSection = .cleanup
                openMainWindow()
            } label: {
                Label("Review Cleanup", systemImage: "sparkles")
            }
            Button {
                model.selectedSection = .assistant
                openMainWindow()
            } label: {
                Label("Ask Robo Assistant", systemImage: "brain.head.profile")
            }

            Divider()

            Text("Disk Robo · on-device only")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 280)
        .buttonStyle(.plain)
    }

    private var greenRecoverableText: String {
        let bytes = model.candidates.filter { $0.risk == .green }.reduce(0) { $0 + $1.sizeBytes }
        return bytes > 0 ? "\(Format.bytes(bytes)) safely recoverable" : "No scan data — run a scan"
    }

    private func labelRow(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
            Text(text).font(.caption).lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }
}

// MARK: - Main window interface

struct MainInterface: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1020, minHeight: 620)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(
            get: { model.selectedSection },
            set: { model.selectedSection = $0 ?? .overview }
        )) {
            ForEach(AppModel.Section.main) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }

            Section("Smart Tools") {
                ForEach(AppModel.Section.smartTools) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
            }

            Section("System") {
                ForEach(AppModel.Section.system) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.appBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            assistantCard
        }
        .frame(minWidth: 205)
    }

    /// Persistent assistant card in the sidebar.
    private var assistantCard: some View {
        Button {
            model.selectedSection = .assistant
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(LinearGradient(colors: [Color.accentColor.opacity(0.75), .purple.opacity(0.75)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 36, height: 36)
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 17))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Robo Assistant").font(.callout.weight(.semibold)).foregroundStyle(.primary)
                    Text("Ask anything about your storage — on-device")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.cardStroke))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        Group {
            switch model.selectedSection {
            case .overview: OverviewScreen()
            case .map: StorageMapScreen()
            case .cleanup: CleanupScreen()
            case .apps: AppsScreen()
            case .duplicates: DuplicatesScreen()
            case .files: FilesScreen()
            case .radar: RadarScreen()
            case .growth: GrowthTrackerScreen()
            case .assistant: AssistantScreen()
            case .developer: DeveloperToolsScreen()
            case .browser: BrowserDataScreen()
            case .uninstaller: UninstallerScreen()
            case .settings: SettingsScreen()
            case .exclusions: ExclusionsScreen()
            case .history: ScanHistoryScreen()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    Button {
                        if model.scanPhase == .running {
                            model.cancelScan()
                        } else {
                            model.startFullScan()
                        }
                    } label: {
                        Text(model.scanPhase == .running ? "Cancel Scan" : "Rescan")
                    }

                    Menu {
                        Button("Scan Home") { model.startFullScan() }
                        Button("Quick Scan") { model.startQuickScan() }
                        Divider()
                        Button("Analyze Apps") { model.analyzeApps() }
                        Button("Find Duplicates") { model.selectedSection = .duplicates }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .navigationTitle("Disk Robo")
        .navigationSubtitle(model.selectedSection.title)
    }
}
