import SwiftUI
import RoboCore

// MARK: - Overview dashboard (v2, matches the Disk Robo design)

struct OverviewScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.warmStarted {
                warmStartBanner
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }
            if model.scanPhase == .running {
                ScanProgressCard(progress: model.scanProgress, onCancel: { model.cancelScan() })
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }
            if case .failed(let message) = model.scanPhase {
                scanFailureCard(message)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }

            ScrollView {
                VStack(spacing: 14) {
                    headerRow
                    HStack(alignment: .top, spacing: 14) {
                        StorageMapCard()
                            .frame(maxWidth: .infinity)
                        VStack(spacing: 14) {
                            TopConsumersPanel()
                            RoboInsightsPanel()
                        }
                        .frame(width: 300)
                    }
                }
                .padding(20)
            }
            StatusBar()
        }
        .navigationTitle("Overview")
    }

    // MARK: Header cards row

    /// Warm-start staleness: the dashboard shows the last scan's restored
    /// tree until the user rescans.
    private var warmStartBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Showing your last scan").font(.callout.weight(.semibold))
                Text("Restored from the storage index — rescan for fresh data.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rescan") { model.startFullScan() }
                .controlSize(.small)
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.orange.opacity(0.25)))
    }

    /// Why a scan failed — the message was previously swallowed (red dot only).
    private func scanFailureCard(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Scan failed").font(.callout.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Try Again") { model.startFullScan() }
                .controlSize(.small)
        }
        .padding(12)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.red.opacity(0.25)))
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 14) {
            VolumeCard()
                .frame(maxWidth: .infinity)
            DiskHealthCard()
                .frame(width: 210)
            RecoverableCard()
                .frame(width: 210)
        }
    }
}

// MARK: - Volume card (name, segmented bar, category legend)

struct VolumeCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        DashboardCard {
            if let volume = model.primaryVolume {
                volumeContent(volume)
            } else {
                ContentUnavailableView("No volume", systemImage: "internaldrive",
                                       description: Text("No internal volume detected."))
            }
        }
    }

    @ViewBuilder
    private func volumeContent(_ volume: VolumeInfo) -> some View {
        let categories = legendCategories
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                HStack(spacing: 10) {
                    Image(systemName: "internaldrive.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(volume.name).font(.headline)
                        Text(volume.isInternal ? "APFS · \(volume.totalBytes.bytesFormatted)" : "External · \(volume.totalBytes.bytesFormatted)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(volume.usedBytes.bytesFormatted).font(.title3.weight(.bold)).monospacedDigit()
                    Text("Used of \(volume.totalBytes.bytesFormatted)").font(.caption).foregroundStyle(.secondary)
                }
            }

            UsageBar(
                segments: categories.map { (Theme.color(for: $0.key), Double($0.value) / Double(max(volume.usedBytes, 1))) },
                height: 12
            )

            // Legend: top 6 categories + Others
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(categories, id: \.key) { category, bytes in
                    HStack(spacing: 6) {
                        Circle().fill(Theme.color(for: category)).frame(width: 8, height: 8)
                        Text(category.displayName).font(.caption).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(bytes.bytesFormatted).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var legendCategories: [(key: StorageCategory, value: Int64)] {
        let all = model.scanResult?.categories ?? [:]
        let sorted = all.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        guard sorted.count > 6 else { return sorted.map { (key: $0.key, value: $0.value) } }
        let top = sorted.prefix(6)
        let rest = sorted.dropFirst(6).reduce(0) { $0 + $1.value }
        return top.map { (key: $0.key, value: $0.value) } + [(key: StorageCategory.other, value: rest)]
    }
}

// MARK: - Disk health card

struct DiskHealthCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        DashboardCard(title: "Disk Health") {
            if let health = model.health {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(health.value)")
                                .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                            Text("/100").font(.callout).foregroundStyle(.secondary)
                        }
                        Text(model.healthVerdict.text)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(model.healthVerdict.color)
                    }
                    Spacer()
                    HealthRing(score: health.value, size: 62)
                }
                Text(health.headline).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("—").font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Run a scan").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HealthRing(score: nil, size: 62)
                }
                Text("Your disk health score appears after the first scan.")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

// MARK: - Recoverable card

struct RecoverableCard: View {
    @Environment(AppModel.self) private var model

    private var greenBytes: Int64 {
        model.candidates.filter { $0.risk == .green }.reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        DashboardCard(title: "Recoverable") {
            VStack(alignment: .leading, spacing: 8) {
                if model.candidates.isEmpty && model.scanResult == nil {
                    Text("—").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("After a scan").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(greenBytes.bytesFormatted)
                        .font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.green)
                    Text("Safely cleanable now").font(.caption).foregroundStyle(.secondary)
                }

                Menu {
                    Button("Quick Clean — greens only") { goClean(mode: .quick) }
                    Button("Smart Clean — greens + yellows") { goClean(mode: .smart) }
                    Button("Deep Clean — everything") { goClean(mode: .deep) }
                } label: {
                    HStack {
                        Text("Review").font(.callout.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.candidates.isEmpty)
            }
        }
    }

    private func goClean(mode: CleanMode) {
        model.buildPlan(mode: mode)
        model.selectedSection = .cleanup
    }
}

// MARK: - Top consumers panel

struct TopConsumersPanel: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        DashboardCard(
            title: "Top Consumers",
            trailing: AnyView(
                Button("View All") { model.selectedSection = .apps }
                    .buttonStyle(.link).font(.caption)
            )
        ) {
            if model.appPhase == .running && model.apps.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring app footprints…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 18)
            } else if model.apps.isEmpty {
                VStack(spacing: 8) {
                    Text("App footprints not analyzed yet.").font(.caption).foregroundStyle(.secondary)
                    Button("Analyze Apps") { model.analyzeApps() }
                        .controlSize(.small)
                }
                .padding(.vertical, 10)
            } else {
                let top = Array(model.apps.prefix(expanded ? 10 : 5))
                VStack(spacing: 10) {
                    ForEach(top) { app in
                        consumerRow(app)
                    }
                    if model.apps.count > 5 {
                        Button(expanded ? "Show Less" : "Show More") { expanded.toggle() }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
    }

    private func consumerRow(_ app: AppFootprint) -> some View {
        let maxBytes = model.apps.first?.totalBytes ?? 1
        return VStack(spacing: 5) {
            HStack(spacing: 9) {
                AppIconView(path: app.isLeftover ? app.libraryPath : app.path, size: 24)
                Text(app.name).font(.callout).lineLimit(1)
                Spacer()
                Text(app.totalBytes.bytesFormatted).font(.callout.monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule().fill(Color.accentColor.opacity(0.75))
                        .frame(width: geo.size.width * CGFloat(Double(app.totalBytes) / Double(max(maxBytes, 1))))
                }
            }
            .frame(height: 4)
        }
    }
}

// MARK: - Robo insights panel

struct RoboInsightsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        DashboardCard(
            title: "Robo Insights",
            trailing: AnyView(
                Button(expanded ? "Less" : "View All") { expanded.toggle() }
                    .buttonStyle(.link).font(.caption)
            )
        ) {
            if model.insights.isEmpty {
                Text(model.scanPhase == .running
                     ? "Insights appear when the scan completes."
                     : "Run a scan to see what Disk Robo noticed.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 11) {
                    ForEach(Array(model.insights.prefix(expanded ? 12 : 4))) { insight in
                        InsightRow(insight: insight)
                    }
                }
            }
        }
    }
}

struct InsightRow: View {
    let insight: Insight

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.color(for: insight.severity).opacity(0.16))
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: insight.symbolName)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.color(for: insight.severity))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(insight.title).font(.callout.weight(.medium)).lineLimit(2)
                Text(insight.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Bottom status bar

struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @State private var showTargetSheet = false
    @State private var targetGB = 30.0

    var body: some View {
        HStack(spacing: 26) {
            statusItem(icon: nil, dot: scanHealthyColor,
                       title: "Last Scan", value: lastScanText)

            statusItem(icon: "doc.text",
                       title: "Files Scanned",
                       value: model.scanResult.map { $0.filesCount.formatted() } ?? "—")

            statusItem(icon: "speedometer",
                       title: "Scan Speed",
                       value: model.scanSpeedFilesPerSec.map { "\($0.formatted()) files/sec" } ?? "—")

            statusItem(icon: "calendar",
                       title: "Next Scan",
                       value: "Manual")

            Spacer()

            Menu {
                Button("Deep Scan — full home analysis") { model.startFullScan() }
                Button("Quick Scan — known cleanup spots") { model.startQuickScan() }
                Divider()
                Button("Target Cleanup…") { showTargetSheet = true }
                    .disabled(model.candidates.isEmpty)
            } label: {
                Text(model.scanPhase == .running ? "Scanning…" : "Start Deep Scan")
                    .fontWeight(.semibold)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .menuStyle(.borderedButton)
            .menuIndicator(.hidden)
            .disabled(model.scanPhase == .running)
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.cardFill)
        .overlay(Divider(), alignment: .top)
        .sheet(isPresented: $showTargetSheet) {
            TargetCleanupSheet(targetGB: $targetGB)
        }
    }

    private var scanHealthyColor: Color {
        switch model.scanPhase {
        case .running: return .indigo
        case .done: return .green
        case .failed: return .red
        case .idle: return .gray
        }
    }

    private var lastScanText: String {
        guard let date = model.lastScanDate else { return "Never" }
        let relative = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        return model.scanPhase == .running ? "In progress…" : relative
    }

    private func statusItem(icon: String?, dot: Color? = nil, title: String, value: String) -> some View {
        HStack(spacing: 9) {
            if let dot {
                StatusDot(color: dot)
            } else if let icon {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.caption.weight(.medium)).monospacedDigit()
            }
        }
    }
}

// MARK: - Target cleanup sheet

struct TargetCleanupSheet: View {
    @Environment(AppModel.self) private var model
    @Binding var targetGB: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Target Cleanup").font(.headline)
            Text("How much space would you like to recover? Disk Robo builds the safest plan that reaches your goal — greens first, then yellows.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            HStack {
                Slider(value: $targetGB, in: 5...200, step: 5)
                    .frame(width: 240)
                Text("\(Int(targetGB)) GB").font(.callout.weight(.semibold)).monospacedDigit()
                    .frame(width: 60)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Button("Build Plan") {
                    model.buildPlan(mode: .target(gigabytes: targetGB))
                    model.selectedSection = .cleanup
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }
}
