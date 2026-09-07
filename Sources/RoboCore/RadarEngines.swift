import Foundation

// MARK: - Robo Radar

public enum RadarFindingKind: String, Codable, Sendable {
    case freeSpace, rapidGrowth, bigGrower, cacheBloat, duplicateMass, repeatOffender, leftovers, trashBuildup, installerBuildup
}

/// A ranked storage anomaly. Severity 1 (info) … 5 (critical).
public struct RadarFinding: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: RadarFindingKind
    public let severity: Int
    public let title: String
    public let detail: String
    public let recoverableBytes: Int64?
    public let confidence: Confidence
    public let recommendation: String

    public init(id: String, kind: RadarFindingKind, severity: Int, title: String, detail: String,
                recoverableBytes: Int64?, confidence: Confidence, recommendation: String) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
        self.recoverableBytes = recoverableBytes
        self.confidence = confidence
        self.recommendation = recommendation
    }

    public var symbolName: String {
        switch kind {
        case .freeSpace: return "exclamationmark.triangle"
        case .rapidGrowth, .bigGrower: return "chart.line.uptrend.xyaxis"
        case .cacheBloat: return "app.dashed"
        case .duplicateMass: return "square.on.square"
        case .repeatOffender: return "arrow.triangle.2.circlepath"
        case .leftovers: return "externaldrive.badge.exclamationmark"
        case .trashBuildup: return "trash"
        case .installerBuildup: return "shippingbox"
        }
    }
}

/// Anomaly detection: severity × recoverable × confidence × recurrence × risk
/// (spec §6). Deterministic — findings are derived from real scan history.
public enum RadarEngine {
    public static func analyze(volume: VolumeInfo?,
                               snapshots: [Snapshot],
                               candidates: [CleanupCandidate],
                               duplicates: [DuplicateGroup],
                               leftovers: [AppFootprint],
                               offenders: [RepeatOffender],
                               freeWarningBytes: Int64 = 20_000_000_000,
                               criticalFreeBytes: Int64 = 10_000_000_000,
                               trashBytes: Int64 = 0,
                               now: Date = Date()) -> [RadarFinding] {
        var findings: [RadarFinding] = []
        var counter = 0
        func add(_ kind: RadarFindingKind, _ severity: Int, _ title: String, _ detail: String,
                 recoverable: Int64? = nil, confidence: Confidence = .high, recommendation: String) {
            counter += 1
            findings.append(RadarFinding(id: "radar-\(counter)", kind: kind, severity: severity,
                                         title: title, detail: detail, recoverableBytes: recoverable,
                                         confidence: confidence, recommendation: recommendation))
        }

        // --- Free-space pressure ---
        if let v = volume {
            if v.availableBytes < criticalFreeBytes {
                add(.freeSpace, 5,
                    "Critical: only \(Format.bytes(v.availableBytes)) free",
                    "\(Format.percent(v.freeRatio)) of \(v.name) remains. macOS performance degrades at this level.",
                    recommendation: "Run Quick Clean now — it only touches safe, regenerable data.")
            } else if v.availableBytes < freeWarningBytes {
                add(.freeSpace, 4,
                    "Free space below \(Format.bytes(freeWarningBytes)) (\(Format.bytes(v.availableBytes)) left)",
                    "\(Format.percent(v.freeRatio)) of \(v.name) is free.",
                    recommendation: "Review the Cleanup Center before it becomes critical.")
            }
        }

        // --- Growth between the two most recent full snapshots ---
        let full = snapshots.filter { !$0.isQuickScan }.sorted { $0.date < $1.date }
        if full.count >= 2 {
            let older = full[full.count - 2]
            let newer = full[full.count - 1]
            let days = max(0.25, newer.date.timeIntervalSince(older.date) / 86_400)
            let perDay = Double(newer.usedBytes - older.usedBytes) / days
            if perDay > 3_000_000_000 {
                add(.rapidGrowth, 4,
                    "Storage grew \(Format.bytes(Int64(perDay))) per day recently",
                    "Between \(Format.relativeDate(older.date)) and \(Format.relativeDate(newer.date)), scanned storage grew \(Format.bytes(newer.usedBytes - older.usedBytes)).",
                    confidence: .medium,
                    recommendation: "See Growth Tracker for the directory-by-directory breakdown.")
            } else if perDay > 1_000_000_000 {
                add(.rapidGrowth, 3,
                    "Storage grew \(Format.bytes(Int64(perDay * 7))) this week",
                    "Sustained growth of about \(Format.bytes(Int64(perDay))) per day.",
                    confidence: .medium,
                    recommendation: "Check Growth Tracker to find the driver.")
            }
            if let grower = GrowthAnalyzer.diff(older, newer).directoryDeltas.first(where: { $0.delta > 1_000_000_000 }) {
                add(.bigGrower, 3,
                    "\(grower.path) grew \(Format.bytes(grower.delta))",
                    "Largest single-directory increase since \(Format.relativeDate(older.date)).",
                    confidence: .medium,
                    recommendation: "Inspect it in the Storage Map — it may be a cache that regenerates.")
            }
        }

        // --- Single-app cache bloat ---
        let caches = candidates.filter { $0.kind == .cache }
        if let biggest = caches.max(by: { $0.sizeBytes < $1.sizeBytes }) {
            let totalCaches = caches.reduce(0) { $0 + $1.sizeBytes }
            if biggest.sizeBytes > 3_000_000_000 || (totalCaches > 4_000_000_000 && Double(biggest.sizeBytes) > Double(totalCaches) * 0.4) {
                add(.cacheBloat, 3,
                    "\(biggest.name) cache is \(Format.bytes(biggest.sizeBytes))",
                    "Unusually large single-app cache" + (totalCaches > 0 ? " (\(Format.percent(Double(biggest.sizeBytes) / Double(totalCaches))) of all caches)." : "."),
                    recoverable: biggest.sizeBytes,
                    recommendation: "Safe to clean — the app rebuilds it only as needed.")
            }
        }

        // --- Duplicate mass ---
        let wasted = duplicates.reduce(0) { $0 + $1.wastedBytes }
        if wasted > 1_000_000_000 {
            add(.duplicateMass, 3,
                "\(Format.bytes(wasted)) locked in \(duplicates.count) duplicate groups",
                "Byte-verified identical files — every extra copy is pure waste.",
                recoverable: wasted,
                confidence: .veryHigh,
                recommendation: "Review Duplicates; keep-one is enforced automatically.")
        }

        // --- Repeat offenders (recurrence signal) ---
        for offender in offenders.prefix(3) where offender.currentBytes > 500_000_000 {
            let rate = offender.weeklyGrowthBytes.map { String(format: " (~%.1f GB/week)", $0 / 1_000_000_000) } ?? ""
            add(.repeatOffender, 4,
                "\(offender.displayName) came back — \(Format.bytes(offender.currentBytes)) again",
                "Cleaned \(Format.bytes(offender.cleanedBytes)) on \(offender.lastCleaned.formatted(date: .abbreviated, time: .omitted)) and it has regrown\(rate). This is a repeat offender.",
                recoverable: offender.currentBytes,
                confidence: .high,
                recommendation: "Clean it again — or accept it as a recurring cost of using this app.")
        }

        // --- Leftovers from removed apps ---
        let leftoverBytes = leftovers.reduce(0) { $0 + $1.totalBytes }
        if leftoverBytes > 1_000_000_000 {
            add(.leftovers, 2,
                "\(Format.bytes(leftoverBytes)) of data from removed apps",
                "\(leftovers.count) library folders whose owning app is no longer installed.",
                recoverable: leftoverBytes,
                confidence: .medium,
                recommendation: "Review in Uninstaller → Leftovers. Names can be ambiguous, so each item needs your glance.")
        }

        // --- Trash buildup (advisory only: measured from scan categories —
        // Disk Robo never empties the Trash, so this is never a cleanup candidate) ---
        if trashBytes > 3_000_000_000 {
            add(.trashBuildup, 2,
                "The Trash holds \(Format.bytes(trashBytes))",
                "Deleted items still occupy disk until the Trash is emptied.",
                recoverable: trashBytes,
                recommendation: "Empty the Trash in Finder when you're sure — Disk Robo never empties it for you.")
        }

        // --- Old installers ---
        let installerBytes = candidates.filter { $0.kind == .oldInstaller }.reduce(0) { $0 + $1.sizeBytes }
        if installerBytes > 500_000_000 {
            add(.installerBuildup, 2,
                "\(Format.bytes(installerBytes)) of old installers in Downloads",
                "DMGs and packages you have likely already used.",
                recoverable: installerBytes,
                confidence: .high,
                recommendation: "Review them in Cleanup Center — they're re-downloadable any time.")
        }

        return findings.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return ($0.recoverableBytes ?? 0) > ($1.recoverableBytes ?? 0)
        }
    }
}

// MARK: - Repeat Offenders

/// A location that was cleaned before and has grown back (spec §8).
public struct RepeatOffender: Identifiable, Sendable, Equatable {
    public let path: String
    public let displayName: String
    public let cleanedBytes: Int64
    public let cleanedCount: Int
    public let lastCleaned: Date
    public let currentBytes: Int64
    /// Estimated growth since the last cleanup, per week.
    public let weeklyGrowthBytes: Double?

    public var id: String { path }
    public var regrownBytes: Int64 { currentBytes }

    public init(path: String, displayName: String, cleanedBytes: Int64, cleanedCount: Int,
                lastCleaned: Date, currentBytes: Int64, weeklyGrowthBytes: Double?) {
        self.path = path
        self.displayName = displayName
        self.cleanedBytes = cleanedBytes
        self.cleanedCount = cleanedCount
        self.lastCleaned = lastCleaned
        self.currentBytes = currentBytes
        self.weeklyGrowthBytes = weeklyGrowthBytes
    }
}

/// Cross-references the cleanup audit log against the current scan to find
/// locations that repeatedly consume space after being cleaned.
public enum RepeatOffenderEngine {
    public static func compute(records: [CleanupActionRecord],
                               currentCandidates: [CleanupCandidate],
                               now: Date = Date()) -> [RepeatOffender] {
        let trashed = records.filter { $0.result == CleanupActionRecord.Result.trashed && $0.sizeBytes > 0 }

        // Aggregate cleaned bytes per normalized path.
        struct Agg { var bytes: Int64 = 0; var count: Int = 0; var last: Date = .distantPast }
        var byPath: [String: Agg] = [:]
        for record in trashed {
            let key = PathKit.normalize(record.path)
            var agg = byPath[key] ?? Agg()
            agg.bytes += record.sizeBytes
            agg.count += 1
            agg.last = max(agg.last, record.date)
            byPath[key] = agg
        }

        var offenders: [RepeatOffender] = []
        for (path, agg) in byPath {
            guard let current = currentCandidates.first(where: { PathKit.normalize($0.url.path) == path }) else { continue }
            guard current.sizeBytes > 100_000_000 else { continue }  // ignore trivial regrowth
            let days = max(0.5, now.timeIntervalSince(agg.last) / 86_400)
            // Weekly-rate estimates need a real observation window; right after
            // a clean the extrapolation is noise (e.g. "256 GB/week" hours later).
            let weekly = days >= 2 ? Double(current.sizeBytes) / days * 7 : nil
            offenders.append(RepeatOffender(
                path: current.url.path,
                displayName: current.name,
                cleanedBytes: agg.bytes,
                cleanedCount: agg.count,
                lastCleaned: agg.last,
                currentBytes: current.sizeBytes,
                weeklyGrowthBytes: weekly
            ))
        }
        return offenders.sorted { $0.currentBytes > $1.currentBytes }
    }
}

// MARK: - Storage Forecast

public struct StorageForecast: Sendable, Equatable {
    /// Positive = free space shrinking (bytes/week).
    public let weeklyGrowthBytes: Double
    public let daysUntilLowFree: Int?
    public let projectedFreeBytesIn30Days: Int64?
    public let rSquared: Double
    public let confidence: Confidence
    public let narrative: String
}

/// Predictive storage (spec §6/§47): ordinary least squares on snapshot free
/// space, with honest confidence derived from sample count and fit quality.
/// Returns nil when there isn't enough history to say anything (never guesses).
public enum ForecastEngine {
    public static func forecast(snapshots: [Snapshot],
                                volume: VolumeInfo?,
                                lowFreeBytes: Int64 = 20_000_000_000) -> StorageForecast? {
        let full = snapshots.filter { !$0.isQuickScan }.sorted { $0.date < $1.date }
        guard full.count >= 3 else { return nil }

        // Prefer measured free space; fall back to volume total − scanned used.
        var points: [(t: Double, y: Double)] = []
        for snapshot in full {
            let y: Double
            if let free = snapshot.volumeFreeBytes {
                y = Double(free)
            } else if let total = snapshot.volumeTotalBytes {
                y = Double(total - snapshot.usedBytes)
            } else {
                continue
            }
            points.append((t: snapshot.date.timeIntervalSince(full[0].date) / 86_400, y: y))
        }
        guard points.count >= 3 else { return nil }

        let n = Double(points.count)
        let sumT = points.reduce(0) { $0 + $1.t }
        let sumY = points.reduce(0) { $0 + $1.y }
        let sumTT = points.reduce(0) { $0 + $1.t * $1.t }
        let sumTY = points.reduce(0) { $0 + $1.t * $1.y }
        let denominator = n * sumTT - sumT * sumT
        guard abs(denominator) > 1e-9 else { return nil }

        let slope = (n * sumTY - sumT * sumY) / denominator
        let intercept = (sumY - slope * sumT) / n

        // R²
        let meanY = sumY / n
        var ssTot = 0.0, ssRes = 0.0
        for p in points {
            let predicted = intercept + slope * p.t
            ssTot += (p.y - meanY) * (p.y - meanY)
            ssRes += (p.y - predicted) * (p.y - predicted)
        }
        let r2 = ssTot > 1e-9 ? max(0, 1 - ssRes / ssTot) : 0

        let currentFree = points.last!.y
        let weekly = -slope * 7  // positive = losing free space

        var daysUntilLow: Int?
        if slope < 0, currentFree > Double(lowFreeBytes) {
            // Free space declining and still above threshold: days until it
            // crosses = (current − threshold) / daily loss rate.
            let days = (currentFree - Double(lowFreeBytes)) / (-slope)
            if days < 3650 { daysUntilLow = Int(days.rounded()) }
        }
        let projected30 = Int64((intercept + slope * (points.last!.t + 30)).rounded())

        let confidence: Confidence
        if points.count >= 8 && r2 > 0.75 { confidence = .veryHigh }
        else if points.count >= 4 && r2 > 0.5 { confidence = .high }
        else if r2 > 0.3 { confidence = .medium }
        else { confidence = .low }

        let narrative: String
        if slope < -1_000_000 {
            let rate = String(format: "%.1f GB", weekly / 1_000_000_000)
            let until = daysUntilLow.map { " It could fall below \(Format.bytes(lowFreeBytes)) in about \($0) days." } ?? ""
            narrative = "Free space is shrinking by ~\(rate) per week.\(until)"
        } else if slope > 1_000_000 {
            narrative = String(format: "Free space is growing (~%.1f GB/week). No pressure predicted.", slope * 7 / 1_000_000_000)
        } else {
            narrative = "Free space has been roughly stable across recent scans."
        }

        return StorageForecast(
            weeklyGrowthBytes: weekly,
            daysUntilLowFree: daysUntilLow,
            projectedFreeBytesIn30Days: projected30,
            rSquared: r2,
            confidence: confidence,
            narrative: narrative
        )
    }
}
