import SwiftUI
import RoboCore

// MARK: - Cleanup Center

struct CleanupScreen: View {
    @Environment(AppModel.self) private var model
    @State private var modeIndex = 0
    @State private var targetGB: Double = 20
    @State private var excludedItemIDs: Set<String> = []

    private var currentMode: CleanMode {
        switch modeIndex {
        case 0: return .quick
        case 1: return .smart
        case 2: return .deep
        default: return .target(gigabytes: targetGB)
        }
    }

    var body: some View {
        Group {
            if model.scanResult == nil && model.candidates.isEmpty {
                ScanPromptView(
                    title: "Nothing to clean yet",
                    message: "Run a scan first — Disk Robo finds cleanup candidates with explanations, risk levels, and honest recoverable-space estimates.",
                    actionTitle: "Quick Scan",
                    quickActionTitle: "Full Scan",
                    onScan: { model.startQuickScan() },
                    onQuickScan: { model.startFullScan() }
                )
            } else {
                content
            }
        }
        .navigationTitle("Cleanup")
        .sheet(isPresented: Binding(
            get: { model.showPlanPreview && model.pendingPlan != nil },
            set: { model.showPlanPreview = $0 }
        )) {
            if let plan = model.pendingPlan {
                PlanPreviewSheet(plan: plan)
            }
        }
    }

    private var content: some View {
        let green = model.candidates.filter { $0.risk == .green }.reduce(0) { $0 + $1.sizeBytes }
        let yellow = model.candidates.filter { $0.risk == .yellow }.reduce(0) { $0 + $1.sizeBytes }
        let orange = model.candidates.filter { $0.risk == .orange }.reduce(0) { $0 + $1.sizeBytes }

        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        StatCard(title: "Safe to Clean", systemImage: "checkmark.seal.fill") {
                            Text(green.bytesFormatted).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(.green)
                            Text("High-confidence, regenerable data").font(.caption).foregroundStyle(.secondary)
                        }
                        StatCard(title: "Review Recommended", systemImage: "eye") {
                            Text(yellow.bytesFormatted).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(.yellow)
                            Text("Downloads, installers, archives").font(.caption).foregroundStyle(.secondary)
                        }
                        StatCard(title: "Important", systemImage: "exclamationmark.triangle") {
                            Text(orange.bytesFormatted).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(.orange)
                            Text("Needs individual review — never auto-planned").font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    modeCard
                    candidateList
                }
                .padding(20)
            }

            if let outcome = model.executionOutcome {
                OutcomeBanner(outcome: outcome) { model.executionOutcome = nil }
            }
        }
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Clean Smart").font(.headline)
            HStack(spacing: 12) {
                Picker("Mode", selection: $modeIndex) {
                    Text("Quick").tag(0)
                    Text("Smart").tag(1)
                    Text("Deep").tag(2)
                    Text("Target").tag(3)
                }
                .pickerStyle(.segmented)
                .frame(width: 320)

                if modeIndex == 3 {
                    HStack(spacing: 4) {
                        TextField("GB", value: $targetGB, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 64)
                            .multilineTextAlignment(.trailing)
                        Text("GB").foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    model.buildPlan(mode: currentMode, excluding: excludedItemIDs)
                } label: {
                    Label("Build Plan", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.candidates.isEmpty)
            }
            Text(modeDescription)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    private var modeDescription: String {
        switch modeIndex {
        case 0: return "Quick Clean includes only green, high-confidence items (caches, logs, build artifacts)."
        case 1: return "Smart Clean adds yellow items (old downloads, installers) for your review."
        case 2: return "Deep Clean lists everything found — orange items require individual selection."
        default: return "Target Cleanup builds the safest plan that reaches your goal — greens first, then yellows."
        }
    }

    private var candidateList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Candidates (\(model.candidates.count))").font(.headline)
            if model.candidates.isEmpty {
                Text("No cleanup candidates found in the last scan. Nice — your disk is tidy.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.candidates) { candidate in
                        CandidateRow(candidate: candidate, isExcluded: excludedItemIDs.contains(candidate.id)) {
                            if excludedItemIDs.contains(candidate.id) {
                                excludedItemIDs.remove(candidate.id)
                            } else {
                                excludedItemIDs.insert(candidate.id)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Candidate row with full explainability

struct CandidateRow: View {
    let candidate: CleanupCandidate
    let isExcluded: Bool
    let onToggle: () -> Void

    @State private var showWhy = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: isExcluded ? "circle" : "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(isExcluded ? Color.secondary : Color.green)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExcluded ? "Include \(candidate.name)" : "Exclude \(candidate.name)")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(candidate.name).font(.callout.weight(.medium)).lineLimit(1)
                    RiskBadge(risk: candidate.risk)
                    if candidate.canReturn {
                        Text("regenerates").font(.caption2).foregroundStyle(.tertiary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary.opacity(0.5), in: Capsule())
                    }
                    Spacer()
                    Text(candidate.sizeBytes.bytesFormatted).font(.callout.monospacedDigit().weight(.medium))
                }
                Text(candidate.what).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(candidate.url.path).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Why?") { showWhy.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
                if showWhy {
                    VStack(alignment: .leading, spacing: 6) {
                        whyRow("Why it exists", candidate.why)
                        whyRow("If you delete it", candidate.impact)
                        whyRow("Can it return", candidate.canReturn ? "Yes — it will be recreated as needed." : "No — once the Trash is emptied, it is gone.")
                        whyRow("Confidence", candidate.confidence.displayName)
                    }
                    .padding(10)
                    .background(Theme.panelFill, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(10)
        .background(isExcluded ? Color.clear : Theme.panelFill, in: RoundedRectangle(cornerRadius: 9))
    }

    private func whyRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption.weight(.semibold)).frame(width: 100, alignment: .leading)
            Text(value).font(.caption)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Plan preview & approval sheet

struct PlanPreviewSheet: View {
    @Environment(AppModel.self) private var model
    let plan: CleanupPlan
    @Environment(\.dismiss) private var dismiss
    @State private var confirmed = false

    /// The plan is the single source of truth: deselected candidates were
    /// filtered out when it was built, so everything listed here is exactly
    /// what the approval token will cover and the executor will trash.
    private var activeItems: [CleanupCandidate] { plan.items }
    private var activeBytes: Int64 {
        activeItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(plan.explanation)
                        .font(.callout)
                        .padding(12)
                        .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

                    ForEach(groupedItems, id: \.kind) { entry in
                        DisclosureGroup("\(kindTitle(entry.kind)) — \(entry.items.reduce(0) { $0 + $1.sizeBytes }.bytesFormatted) (\(entry.items.count))") {
                            ForEach(entry.items) { item in
                                HStack {
                                    Text(item.name).font(.caption).lineLimit(1)
                                    Spacer()
                                    Text(item.sizeBytes.bytesFormatted).font(.caption.monospacedDigit())
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .font(.callout)
                    }

                    Label("Every item moves to the Trash — nothing is permanently deleted. You can restore items from the Trash; Disk Robo never empties it.",
                          systemImage: "trash.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
    }

    private var groupedItems: [(kind: CandidateKind, items: [CleanupCandidate])] {
        let dict = Dictionary(grouping: activeItems, by: \.kind)
        let order: [CandidateKind] = [.cache, .log, .derivedData, .deviceSupport, .simulatorCache,
                                      .packageCache, .oldInstaller, .oldArchive, .oldDownload, .archive]
        return order.filter { dict[$0] != nil }.map { (kind: $0, items: dict[$0]!) }
    }

    private func kindTitle(_ kind: CandidateKind) -> String {
        switch kind {
        case .cache: return "Caches"
        case .log: return "Logs"
        case .derivedData: return "Xcode DerivedData"
        case .deviceSupport: return "iOS Device Support"
        case .simulatorCache: return "Simulator caches"
        case .packageCache: return "Package caches"
        case .oldInstaller: return "Old installers"
        case .oldArchive: return "Old archives"
        case .oldDownload: return "Old downloads"
        case .archive: return "Xcode archives"
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("Action Preview").font(.headline)
            Text("You are about to recover approximately \(activeBytes.bytesFormatted)")
                .font(.title3.weight(.semibold)).foregroundStyle(.green)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            if confirmed {
                Label("Approved — executing…", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button {
                    model.approvePendingPlan()
                    confirmed = true
                    // The model clears showPlanPreview when execution
                    // completes — the sheet's lifetime follows the actual
                    // work, not an arbitrary sleep (UI-5).
                    model.executePendingPlan()
                } label: {
                    Text("Approve & Move \(activeItems.count) Items to Trash")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(activeItems.isEmpty)
            }
            Spacer()
        }
        .padding(14)
    }
}

// MARK: - Outcome banner

struct OutcomeBanner: View {
    let outcome: CleanupExecutionOutcome
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Recovered \(outcome.freedBytes.bytesFormatted)", systemImage: "checkmark.seal.fill")
                    .font(.headline).foregroundStyle(.green)
                Spacer()
                Button("Done", action: onDismiss).controlSize(.small)
            }
            Text("\(outcome.trashedCount) items moved to the Trash.")
                .font(.caption).foregroundStyle(.secondary)
            if !outcome.blockedItems.isEmpty {
                Text("\(outcome.blockedCount) items were blocked for safety — most likely they changed since the scan or sit in protected locations. Re-scan to refresh.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !outcome.failedItems.isEmpty {
                Text("\(outcome.failedCount) items failed to move. They were not modified.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Items remain in the Trash until you empty it — that decision is always yours.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.green.opacity(0.25)))
        .padding(16)
    }
}
