import SwiftUI
import RoboCore

// MARK: - Settings

struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var confirmClearHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                permissionsCard
                privacyCard
                notificationsCard
                exclusionsLinkCard
                thresholdsCard
                dataCard
                aboutCard
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Settings")
        .confirmationDialog("Clear all history?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("Clear All History", role: .destructive) {
                model.history.clearAll()
                model.storageIndex?.deleteAllHistory()
                model.refreshHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes \(model.snapshots.count) snapshots and \(model.cleanupRecords.count) logged cleanup actions. Disk Robo's own records only — no files on disk are affected. Growth trends, forecasts, and repeat-offender history start over.")
        }
    }

    private var notificationsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Alerts", systemImage: "bell.badge").font(.headline)
            Toggle("System notifications for storage pressure", isOn: Binding(
                get: { model.settings.settings.notificationsEnabled },
                set: { newValue in model.settings.update { $0.notificationsEnabled = newValue } }
            ))
            .font(.callout)
            Text("macOS asks once for permission. Alerts fire only for real threshold events — free space below your warning level, or a severity-4+ Robo Radar finding after a scan. No marketing, no nagging.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var exclusionsLinkCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Exclusions", systemImage: "nosign").font(.headline)
            Text("\(model.settings.settings.excludedPaths.count) folder(s) excluded from all scans, recommendations, and plans.")
                .font(.callout).foregroundStyle(.secondary)
            NavigationLink {
                ExclusionsScreen()
            } label: {
                Text("Manage Exclusions")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .cardStyle()
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Permissions", systemImage: "lock.shield").font(.headline)
            HStack(spacing: 10) {
                Image(systemName: model.fdaStatus?.granted == true ? "checkmark.shield.fill" : "shield")
                    .font(.title2)
                    .foregroundStyle(model.fdaStatus?.granted == true ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.fdaStatus == nil
                         ? "Checking Full Disk Access…"
                         : model.fdaStatus?.granted == true ? "Full Disk Access granted" : "Full Disk Access not detected")
                        .font(.callout.weight(.medium))
                    Text("Full Disk Access allows Disk Robo to measure storage used by applications and protected user-library locations. Without it, protected folders are reported as inaccessible — never estimated. Disk Robo does not upload scanned file information.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Open System Settings") {
                    openURL(PermissionManager.fullDiskAccessSettingsURL)
                }
                Button("Re-check") { model.recheckPermissions() }
            }
            .controlSize(.small)
        }
        .cardStyle()
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Privacy", systemImage: "hand.raised").font(.headline)
            Text("All analysis happens locally on this Mac. Disk Robo processes metadata only — names, sizes, dates, and locations. It never reads document contents and contains no networking code whatsoever.")
                .font(.callout)
            Text("Snapshots store sizes and folder paths in your own Application Support folder. Nothing ever leaves this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var thresholdsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Thresholds", systemImage: "slider.horizontal.3").font(.headline)
            Toggle("Gentle scan mode", isOn: Binding(
                get: { model.settings.settings.scanGentleMode },
                set: { newValue in model.settings.update { $0.scanGentleMode = newValue } }
            ))
            .font(.callout)
            Text("Two walkers instead of eight, background priority — slower, but quiet on battery. Applies to the next scan.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Free-space warning at").font(.callout)
                Spacer()
                Picker("Free-space warning threshold", selection: Binding(
                    get: { model.settings.settings.freeSpaceWarningGB },
                    set: { newValue in model.settings.update { $0.freeSpaceWarningGB = newValue } }
                )) {
                    ForEach([5, 10, 15, 20, 30, 50], id: \.self) { Text("\($0) GB").tag($0) }
                }
                .frame(width: 100)
                .labelsHidden()
            }
            HStack {
                Text("Duplicate minimum size").font(.callout)
                Spacer()
                Picker("Duplicate minimum size", selection: Binding(
                    get: { model.settings.settings.duplicateMinSizeMB },
                    set: { newValue in model.settings.update { $0.duplicateMinSizeMB = newValue } }
                )) {
                    ForEach([1, 10, 50, 100], id: \.self) { Text("\($0) MB").tag($0) }
                }
                .frame(width: 100)
                .labelsHidden()
            }
        }
        .cardStyle()
    }

    private var dataCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Storage Memory", systemImage: "externaldrive.badge.icloud").font(.headline)
            Text("\(model.snapshots.count) snapshots · \(model.cleanupRecords.count) logged cleanup actions")
                .font(.callout).monospacedDigit()
            Toggle("Save a snapshot after every scan", isOn: Binding(
                get: { model.settings.settings.autoSnapshot },
                set: { newValue in model.settings.update { $0.autoSnapshot = newValue } }
            ))
            .font(.callout)
            Text("Snapshots power Growth Tracker, forecasts, and repeat-offender detection. Turn this off to keep Disk Robo from keeping any history of scans.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Keep snapshots").font(.callout)
                Spacer()
                Picker("Snapshot retention", selection: Binding(
                    get: { model.settings.settings.snapshotRetention },
                    set: { newValue in model.settings.update { $0.snapshotRetention = newValue } }
                )) {
                    ForEach([30, 60, 120, 365], id: \.self) { Text("\($0)").tag($0) }
                }
                .frame(width: 90)
                .labelsHidden()
            }
            Button("Clear All History…", role: .destructive) {
                confirmClearHistory = true
            }
            .controlSize(.small)
            Text("Clearing history does not affect any files on disk — it only removes Disk Robo's own records.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("About", systemImage: "info.circle").font(.headline)
            Text("Disk Robo 0.1.0 — your Mac's storage engineer.")
                .font(.callout)
            Text("Observe → Understand → Diagnose → Recommend → Approve → Act → Verify → Learn")
                .font(.caption).foregroundStyle(.secondary)
        }
        .cardStyle()
    }
}

extension View {
    func cardStyle() -> some View {
        self.padding(16)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.cardStroke))
    }
}
