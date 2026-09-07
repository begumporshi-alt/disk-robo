import Foundation

public enum InsightSeverity: Int, Sendable, Comparable {
    case info = 0, success, warning, critical
    public static func < (lhs: InsightSeverity, rhs: InsightSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct Insight: Identifiable, Sendable {
    public let id: String
    public let severity: InsightSeverity
    public let symbolName: String
    public let title: String
    public let detail: String
}

/// Deterministic Robo Insights: converts the latest scan, candidates, duplicates,
/// growth, and volume state into ranked, plain-language findings.
public enum InsightsEngine {
    public static func generate(result: ScanResult?,
                                volume: VolumeInfo?,
                                candidates: [CleanupCandidate],
                                duplicates: [DuplicateGroup],
                                delta: StorageDelta?,
                                health: HealthScore?,
                                fdaGranted: Bool?,
                                freeWarningBytes: Int64 = 20_000_000_000) -> [Insight] {
        var insights: [Insight] = []
        var counter = 0
        func add(_ severity: InsightSeverity, _ symbol: String, _ title: String, _ detail: String) {
            counter += 1
            insights.append(Insight(id: "insight-\(counter)", severity: severity,
                                    symbolName: symbol, title: title, detail: detail))
        }

        // Free-space pressure (critical level never sits above the user's warning level)
        let criticalFreeBytes = min(10_000_000_000, freeWarningBytes)
        if let v = volume {
            if v.availableBytes < criticalFreeBytes {
                add(.critical, "exclamationmark.octagon",
                    "Only \(Format.bytes(v.availableBytes)) free",
                    "macOS performance degrades when free space is very low. Quick Clean can likely help.")
            } else if v.availableBytes < freeWarningBytes {
                add(.warning, "exclamationmark.triangle",
                    "Free space is getting low (\(Format.bytes(v.availableBytes)))",
                    "\(Format.percent(v.freeRatio)) of \(v.name) is available.")
            } else {
                add(.success, "checkmark.circle",
                    "\(Format.bytes(v.availableBytes)) available",
                    "\(Format.percent(v.freeRatio)) of \(v.name) is free.")
            }
        }

        // Safe recoverable
        let green = candidates.filter { $0.risk == .green }
        let greenBytes = green.reduce(0) { $0 + $1.sizeBytes }
        if greenBytes > 1_000_000_000 {
            let top = green.first?.what ?? "caches"
            add(.success, "sparkles",
                "\(Format.bytes(greenBytes)) safely recoverable",
                "High-confidence cleanup (e.g., \(top)) with no data-loss risk. Items go to the Trash.")
        } else if greenBytes > 100_000_000 {
            add(.success, "sparkles",
                "\(Format.bytes(greenBytes)) safely recoverable",
                "Modest amount of regenerable cache data.")
        }

        // Growth
        if let delta = delta, abs(delta.totalDelta) > 1_000_000_000 {
            if let grower = delta.directoryDeltas.first(where: { $0.delta > 0 }) {
                add(delta.totalDelta > 10_000_000_000 ? .warning : .info, "chart.line.uptrend.xyaxis",
                    "Storage grew \(Format.bytes(delta.totalDelta)) since \(Format.relativeDate(delta.fromDate))",
                    "Biggest growth: \(grower.path) (+\(Format.bytes(grower.delta))).")
            } else {
                add(.info, "chart.line.uptrend.xyaxis",
                    "Storage grew \(Format.bytes(delta.totalDelta))",
                    "Spread across many small changes — see History for the breakdown.")
            }
        }

        // Biggest app cache
        if let biggestCache = candidates.filter({ $0.kind == .cache }).max(by: { $0.sizeBytes < $1.sizeBytes }),
           biggestCache.sizeBytes > 2_000_000_000 {
            add(.info, "app.dashed",
                "\(biggestCache.name) cache is \(Format.bytes(biggestCache.sizeBytes))",
                "This app has accumulated a large cache. It is safe to clean and will regrow only as needed.")
        }

        // Largest file
        if let largest = result?.largestFiles.first, largest.size > 5_000_000_000 {
            add(.info, "doc.fill",
                "Largest file: \(largest.name) (\(Format.bytes(largest.size)))",
                "\(largest.url.deletingLastPathComponent().path) — review it in the Files explorer.")
        }

        // Duplicates
        let wasted = duplicates.reduce(0) { $0 + $1.wastedBytes }
        if wasted > 1_000_000_000 {
            add(.info, "square.on.square",
                "\(Format.bytes(wasted)) of duplicate data",
                "\(duplicates.count) verified duplicate groups. Duplicates are byte-identical copies.")
        }

        // Health headline
        if let health = health {
            add(health.value >= 70 ? .success : .warning, "gauge.with.dots.needle.50percent",
                "Disk Health: \(health.value)/100",
                health.headline)
        }

        // Coverage honesty (only when FDA is known-absent — not while the
        // async probe is still in flight)
        if let result = result, result.inaccessibleCount > 50, fdaGranted == false {
            add(.warning, "lock.shield",
                "\(result.inaccessibleCount.formatted()) locations could not be inspected",
                "Grant Full Disk Access in Settings to analyze protected locations — Disk Robo never guesses their size.")
        }

        // Trash (advisory only — measured from scan categories; Disk Robo never empties the Trash)
        let trashBytes = result?.categories[.trash] ?? 0
        if trashBytes > 3_000_000_000 {
            add(.info, "trash",
                "The Trash holds \(Format.bytes(trashBytes))",
                "Emptying the Trash is always your decision — Disk Robo never empties it for you.")
        }

        return insights.sorted { $0.severity > $1.severity }
    }
}
