import SwiftUI
import RoboCore

// MARK: - Scan History (Storage Memory: snapshots + cleanup audit log)

struct ScanHistoryScreen: View {
    @Environment(AppModel.self) private var model
    @State private var compareIndexA: Int?
    @State private var compareIndexB: Int?

    var body: some View {
        Group {
            if model.snapshots.count < 1 {
                ContentUnavailableView("No history yet",
                                       systemImage: "clock.arrow.circlepath",
                                       description: Text("Snapshots are saved automatically after each full scan. Over time, Disk Robo can answer “where did my space go?” — see Growth Tracker for comparisons."))
            } else {
                content
            }
        }
        .navigationTitle("Scan History")
    }

    private var fullSnapshots: [Snapshot] {
        model.snapshots.filter { !$0.isQuickScan }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let delta = model.growthDelta ?? manualDelta {
                GrowthDiffView(delta: delta)
            }
            List {
                snapshotSection
                if !model.cleanupRecords.isEmpty {
                    cleanupLogSection
                }
            }
        }
    }

    private var snapshotSection: some View {
        Section("Snapshots — \(model.snapshots.count)") {
            ForEach(Array(model.snapshots.enumerated().reversed()), id: \.element.id) { index, snapshot in
                SnapshotRow(snapshot: snapshot,
                            isA: compareIndexA == index,
                            isB: compareIndexB == index,
                            onSelectA: { compareIndexA = (compareIndexA == index ? nil : index) },
                            onSelectB: { compareIndexB = (compareIndexB == index ? nil : index) })
            }
        }
    }

    private var cleanupLogSection: some View {
        Section("Cleanup Log — last \(min(50, model.cleanupRecords.count)) actions") {
            ForEach(model.cleanupRecords.prefix(50)) { record in
                CleanupLogRow(record: record)
            }
        }
    }

    private var manualDelta: StorageDelta? {
        guard let a = compareIndexA, let b = compareIndexB,
              a < model.snapshots.count, b < model.snapshots.count, a != b else { return nil }
        let older = model.snapshots[min(a, b)]
        let newer = model.snapshots[max(a, b)]
        return GrowthAnalyzer.diff(older, newer)
    }
}

struct CleanupLogRow: View {
    let record: CleanupActionRecord

    private var resultIcon: (symbol: String, tint: Color) {
        switch record.result {
        case CleanupActionRecord.Result.trashed: return ("trash.fill", .secondary)
        case CleanupActionRecord.Result.blocked: return ("xmark.shield", .orange)
        default: return ("exclamationmark.triangle", .red)
        }
    }

    var body: some View {
        HStack {
            Image(systemName: resultIcon.symbol)
                .foregroundStyle(resultIcon.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text((record.path as NSString).lastPathComponent).font(.caption.weight(.medium))
                Text(record.path).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if record.sizeBytes > 0 {
                Text(record.sizeBytes.bytesFormatted).font(.caption.monospacedDigit())
            }
            if let trashPath = record.trashPath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: trashPath)])
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Trash — drag it back to its original folder to restore")
            }
            Text(record.date.formatted(date: .numeric, time: .shortened))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct SnapshotRow: View {
    let snapshot: Snapshot
    let isA: Bool
    let isB: Bool
    let onSelectA: () -> Void
    let onSelectB: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if snapshot.isQuickScan {
                        Text("Quick").font(.caption2.weight(.medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.blue.opacity(0.12), in: Capsule())
                    }
                    Text(snapshot.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.callout.weight(.medium))
                }
                Text("\(snapshot.usedBytes.bytesFormatted) scanned · \(snapshot.filesCount.formatted()) files")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if let free = snapshot.volumeFreeBytes {
                Text("\(free.bytesFormatted) free").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button(isA ? "● A" : "A", action: onSelectA)
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(isA ? Color.accentColor : Color.gray)
            Button(isB ? "● B" : "B", action: onSelectB)
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(isB ? Color.orange : Color.gray)
        }
        .padding(.vertical, 2)
    }
}

struct GrowthDiffView: View {
    let delta: StorageDelta

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Where did my space go?", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.headline)
                Spacer()
                Text("\(delta.fromDate.formatted(date: .abbreviated, time: .omitted)) → \(delta.toDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(GrowthAnalyzer.narratives(for: delta), id: \.self) { line in
                Text("• \(line)").font(.callout)
            }
            if !delta.directoryDeltas.isEmpty {
                Divider()
                ForEach(delta.directoryDeltas.prefix(8)) { dir in
                    HStack(spacing: 8) {
                        Image(systemName: dir.delta > 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(dir.delta > 0 ? .red : .green)
                        Text(dir.path).font(.caption.monospaced())
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(dir.delta > 0 ? "+" : "")\(dir.delta.bytesFormatted)")
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(dir.delta > 0 ? .red : .green)
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .padding(12)
    }
}
