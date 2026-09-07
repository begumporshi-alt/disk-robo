import Foundation

public struct CategoryDelta: Identifiable, Sendable, Equatable {
    public let category: StorageCategory
    public let delta: Int64
    public var id: String { category.rawValue }
}

public struct DirDelta: Identifiable, Sendable, Equatable {
    public let path: String
    public let delta: Int64
    public var id: String { path }
}

public struct StorageDelta: Sendable {
    public let fromDate: Date
    public let toDate: Date
    public let totalDelta: Int64
    public let freeDelta: Int64?
    public let categoryDeltas: [CategoryDelta]
    public let directoryDeltas: [DirDelta]
}

/// The Growth Detective: diffs two snapshots and explains what changed.
public enum GrowthAnalyzer {
    public static func diff(_ older: Snapshot, _ newer: Snapshot, topDirectoryCount: Int = 20) -> StorageDelta {
        let allCategories = Set(older.categories.keys).union(newer.categories.keys)
        let categoryDeltas = allCategories
            .map { key -> CategoryDelta in
                let old = older.categories[key] ?? 0
                let new = newer.categories[key] ?? 0
                let category = StorageCategory(rawValue: key) ?? .other
                return CategoryDelta(category: category, delta: new - old)
            }
            .sorted { abs($0.delta) > abs($1.delta) }

        var dirDeltas: [DirDelta] = []
        let allDirs = Set(older.topDirectories.keys).union(newer.topDirectories.keys)
        for path in allDirs {
            let old = older.topDirectories[path] ?? 0
            let new = newer.topDirectories[path] ?? 0
            if new - old != 0 { dirDeltas.append(DirDelta(path: path, delta: new - old)) }
        }
        dirDeltas.sort { abs($0.delta) > abs($1.delta) }

        let freeDelta: Int64?
        if let o = older.volumeFreeBytes, let n = newer.volumeFreeBytes {
            freeDelta = n - o
        } else {
            freeDelta = nil
        }

        return StorageDelta(
            fromDate: older.date,
            toDate: newer.date,
            totalDelta: newer.usedBytes - older.usedBytes,
            freeDelta: freeDelta,
            categoryDeltas: categoryDeltas,
            directoryDeltas: Array(dirDeltas.prefix(topDirectoryCount))
        )
    }

    /// Plain-language narrative lines ("Where did my space go?").
    public static func narratives(for delta: StorageDelta) -> [String] {
        var lines: [String] = []
        let days = max(1, delta.toDate.timeIntervalSince(delta.fromDate) / 86_400)

        if delta.totalDelta > 1_000_000_000 {
            lines.append("Scanned storage grew by \(Format.bytes(delta.totalDelta)) over \(Int(days)) days.")
        } else if delta.totalDelta < -1_000_000_000 {
            lines.append("Scanned storage shrank by \(Format.bytes(-delta.totalDelta)) over \(Int(days)) days.")
        } else {
            lines.append("Scanned storage was roughly stable (\(Format.bytes(abs(delta.totalDelta))) change).")
        }

        if let grower = delta.directoryDeltas.first(where: { $0.delta > 0 }) {
            lines.append("Biggest growth: \(grower.path) (+\(Format.bytes(grower.delta))).")
        }
        if let shrinker = delta.directoryDeltas.first(where: { $0.delta < 0 }) {
            lines.append("Biggest reduction: \(shrinker.path) (−\(Format.bytes(-shrinker.delta))).")
        }
        if let cat = delta.categoryDeltas.first, abs(cat.delta) > 500_000_000 {
            let direction = cat.delta > 0 ? "grew" : "shrank"
            lines.append("\(cat.category.displayName) \(direction) by \(Format.bytes(abs(cat.delta))).")
        }
        if let free = delta.freeDelta, abs(free) > 500_000_000 {
            let direction = free > 0 ? "gained" : "lost"
            lines.append("Free space \(direction) \(Format.bytes(abs(free))).")
        }
        return lines
    }
}
