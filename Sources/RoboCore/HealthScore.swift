import Foundation

public struct HealthFactor: Identifiable, Sendable {
    public let name: String
    public let weight: Double
    public let score: Double
    public let detail: String
    public var id: String { name }
}

/// Disk Health Score, 0–100. Deterministic, weighted, and fully explained —
/// never presented as scientific precision (spec §9). Factors with missing
/// data are excluded and weights renormalized.
public struct HealthScore: Sendable {
    public let value: Int
    public let factors: [HealthFactor]

    public var headline: String {
        factors.min { $0.score * $0.weight < $1.score * $1.weight }
            .map { $0.detail } ?? "Disk health looks good."
    }
}

enum HealthMath {
    /// Piecewise-linear interpolation over sorted control points (x ascending).
    static func interpolate(_ x: Double, points: [(Double, Double)]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        for i in 1..<points.count {
            let (x1, y1) = points[i - 1]
            let (x2, y2) = points[i]
            if x <= x2 {
                let t = (x - x1) / max(x2 - x1, 1e-9)
                return y1 + t * (y2 - y1)
            }
        }
        return last.1
    }
}

public enum HealthScoreEngine {
    public static func compute(freeRatio: Double?,
                        totalBytes: Int64?,
                        greenRecoverableBytes: Int64?,
                        duplicateBytes: Int64?,
                        growth7dRatio: Double?,
                        trashLogBytes: Int64?) -> HealthScore {
        var factors: [HealthFactor] = []

        if let free = freeRatio {
            let score = HealthMath.interpolate(free, points: [(0.02, 0), (0.05, 25), (0.10, 55), (0.15, 80), (0.30, 100)])
            factors.append(HealthFactor(
                name: "Free space", weight: 0.40, score: score,
                detail: String(format: "Free space is %.0f%% of the disk.", free * 100)
            ))
        }
        if let total = totalBytes, total > 0, let green = greenRecoverableBytes, green >= 0 {
            let ratio = Double(green) / Double(total)
            let score = max(0, 100 - ratio * 600)
            factors.append(HealthFactor(
                name: "Safe-to-clean storage", weight: 0.20, score: score,
                detail: "\(Format.bytes(green)) of caches and regenerable data could be cleaned."
            ))
        }
        if let total = totalBytes, total > 0, let dupes = duplicateBytes, dupes >= 0 {
            let ratio = Double(dupes) / Double(total)
            let score = max(0, 100 - ratio * 500)
            factors.append(HealthFactor(
                name: "Duplicates", weight: 0.15, score: score,
                detail: dupes > 0 ? "\(Format.bytes(dupes)) is duplicated data." : "No significant duplicates detected."
            ))
        }
        if let growth = growth7dRatio {
            let score = HealthMath.interpolate(growth, points: [(-1.0, 100), (0.0, 90), (0.01, 75), (0.03, 40), (0.05, 0)])
            factors.append(HealthFactor(
                name: "Growth trend", weight: 0.15, score: score,
                detail: growth >= 0
                    ? String(format: "Storage grew %.1f%% over the last week.", growth * 100)
                    : String(format: "Storage shrank %.1f%% over the last week.", -growth * 100)
            ))
        }
        if let total = totalBytes, total > 0, let trashLog = trashLogBytes, trashLog >= 0 {
            let ratio = Double(trashLog) / Double(total)
            let score = max(0, 100 - ratio * 800)
            factors.append(HealthFactor(
                name: "Trash & logs", weight: 0.10, score: score,
                detail: "\(Format.bytes(trashLog)) sits in the Trash and old logs."
            ))
        }

        let totalWeight = factors.reduce(0) { $0 + $1.weight }
        let weighted = factors.reduce(0) { $0 + $1.score * $1.weight }
        let value = totalWeight > 0 ? Int((weighted / totalWeight).rounded()) : 50
        return HealthScore(value: max(0, min(100, value)), factors: factors)
    }
}
