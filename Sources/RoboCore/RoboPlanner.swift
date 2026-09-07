import Foundation

public enum CleanMode: Hashable, Sendable {
    /// Only green, high-confidence candidates.
    case quick
    /// Green + yellow, reviewed by the user.
    case smart
    /// Everything, including orange (each requiring manual selection).
    case deep
    /// "Find me N GB" — safest-first greedy fill.
    case target(gigabytes: Double)

    public var displayName: String {
        switch self {
        case .quick: return "Quick Clean"
        case .smart: return "Smart Clean"
        case .deep: return "Deep Clean"
        case .target: return "Target Cleanup"
        }
    }
}

public struct CleanupPlan: Sendable {
    public let mode: CleanMode
    public let items: [CleanupCandidate]
    public let expectedRecoveryBytes: Int64
    public let explanation: String

    public init(mode: CleanMode, items: [CleanupCandidate]) {
        self.mode = mode
        self.items = items
        self.expectedRecoveryBytes = items.reduce(0) { $0 + $1.sizeBytes }
        let greens = items.filter { $0.risk == .green }
        let yellows = items.filter { $0.risk == .yellow }
        let oranges = items.filter { $0.risk == .orange }
        var parts: [String] = []
        if !greens.isEmpty { parts.append("\(greens.count) safe items (\(Format.bytes(greens.reduce(0) { $0 + $1.sizeBytes })))") }
        if !yellows.isEmpty { parts.append("\(yellows.count) review-recommended items (\(Format.bytes(yellows.reduce(0) { $0 + $1.sizeBytes })))") }
        if !oranges.isEmpty { parts.append("\(oranges.count) important items requiring manual review") }
        self.explanation = "Safest-first plan: " + parts.joined(separator: ", ")
            + ". Expected recovery ≈ \(Format.bytes(expectedRecoveryBytes)). Items move to the Trash — nothing is permanently deleted."
    }
}

/// The Robo Planner: deterministic plan construction. Never invents candidates,
/// never upgrades risk, never executes anything (execution requires an approval
/// token plus per-item safety validation).
public enum RoboPlanner {
    /// - Parameter excluding: candidate IDs the user deselected. Excluded items
    ///   never enter the plan, so the approval token, the preview, and the
    ///   executor all agree on what will move.
    public static func buildPlan(from candidates: [CleanupCandidate], mode: CleanMode,
                                 excluding excludedIDs: Set<String> = []) -> CleanupPlan {
        func riskWeight(_ r: RiskLevel) -> Int { r.rawValue }

        let pool = excludedIDs.isEmpty ? candidates : candidates.filter { !excludedIDs.contains($0.id) }
        let sorted = pool.sorted { a, b in
            let wa = riskWeight(a.risk), wb = riskWeight(b.risk)
            if wa != wb { return wa < wb }
            return a.sizeBytes > b.sizeBytes
        }

        switch mode {
        case .quick:
            let items = sorted.filter { $0.risk == .green }
            return CleanupPlan(mode: mode, items: items)
        case .smart:
            let items = sorted.filter { $0.risk == .green || $0.risk == .yellow }
            return CleanupPlan(mode: mode, items: items)
        case .deep:
            return CleanupPlan(mode: mode, items: sorted)
        case .target(let gb):
            let target = Int64((gb * 1_000_000_000).rounded())
            var chosen: [CleanupCandidate] = []
            var total: Int64 = 0
            for candidate in sorted {
                if total >= target { break }
                chosen.append(candidate)
                total += candidate.sizeBytes
            }
            return CleanupPlan(mode: mode, items: chosen)
        }
    }
}
