import Foundation

// MARK: - Path utilities

/// Path comparison helpers. All comparisons are case-insensitive and use
/// standardized paths (APFS system volumes are case-insensitive by default;
/// for safety checks, matching more is safer than matching less).
public enum PathKit {
    public static func normalize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        if p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        p = stripPrivatePrefix(p)
        return p.lowercased()
    }

    /// Canonicalizes APFS firmlink aliases so `/var/x` and `/private/var/x`
    /// compare equal (symlink resolution can produce either spelling).
    static func stripPrivatePrefix(_ p: String) -> String {
        for base in ["/private/var", "/private/etc", "/private/tmp"] {
            if p == base { return String(base.dropFirst("/private".count)) }
            if p.hasPrefix(base + "/") { return String(p.dropFirst("/private".count)) }
        }
        return p
    }

    /// True when `path` is equal to or inside `ancestor`.
    public static func isDescendant(path: String, of ancestor: String) -> Bool {
        let a = normalize(ancestor)
        let p = normalize(path)
        if a == "/" { return p.hasPrefix("/") }  // "/" + "/" would build "//"
        return p == a || p.hasPrefix(a + "/")
    }
}

// MARK: - Categories & risk

public enum StorageCategory: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case applications, developer, caches, downloads, trash, installers, archives, logs, browser, media, documents, system, other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .applications: return "Applications"
        case .developer: return "Developer"
        case .caches: return "Caches"
        case .downloads: return "Downloads"
        case .trash: return "Trash"
        case .installers: return "Installers"
        case .archives: return "Archives"
        case .logs: return "Logs"
        case .browser: return "Browser Data"
        case .media: return "Media"
        case .documents: return "Documents"
        case .system: return "System & Protected"
        case .other: return "Other"
        }
    }
}

public enum RiskLevel: Int, Codable, CaseIterable, Sendable, Comparable, Identifiable {
    case green = 0
    case yellow = 1
    case orange = 2
    case red = 3

    public var id: Int { rawValue }
    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .green: return "Safe"
        case .yellow: return "Review"
        case .orange: return "Important"
        case .red: return "Protected"
        }
    }

    public var symbolName: String {
        switch self {
        case .green: return "checkmark.seal"
        case .yellow: return "eye"
        case .orange: return "exclamationmark.triangle"
        case .red: return "lock.shield"
        }
    }
}

public enum Confidence: Int, Codable, Sendable, Comparable {
    case veryHigh = 0
    case high = 1
    case medium = 2
    case low = 3

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .veryHigh: return "Very High"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

// MARK: - Storage node

public enum NodeKind: String, Codable, Sendable {
    case file
    case package
    case directory
}

public struct NodeFlags: OptionSet, Codable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let inaccessible = NodeFlags(rawValue: 1 << 0)
    public static let excluded = NodeFlags(rawValue: 1 << 1)
}

/// A node in the scanned storage tree. Directories aggregate every descendant;
/// files below the scan's `largeFileThresholdBytes` are counted (not materialized)
/// in `smallFileCount` / `smallFileBytes` to keep memory bounded on million-file volumes.
public final class StorageNode: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let url: URL
    public var name: String
    public var kind: NodeKind
    /// Logical size in bytes (matches Finder). For directories: self + descendants.
    public var size: Int64
    public var fileCount: Int
    public var directoryCount: Int
    public var smallFileCount: Int
    public var smallFileBytes: Int64
    public var symlinkCount: Int
    public var excludedCount: Int
    public var modDate: Date?
    public var flags: NodeFlags
    public var errorDescription: String?
    public var category: StorageCategory
    public var children: [StorageNode]

    public init(url: URL,
                name: String? = nil,
                kind: NodeKind = .directory,
                size: Int64 = 0,
                modDate: Date? = nil,
                category: StorageCategory = .other,
                flags: NodeFlags = []) {
        self.id = UUID()
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.kind = kind
        self.size = size
        self.modDate = modDate
        self.category = category
        self.flags = flags
        self.fileCount = 0
        self.directoryCount = 0
        self.smallFileCount = 0
        self.smallFileBytes = 0
        self.symlinkCount = 0
        self.excludedCount = 0
        self.children = []
    }

    public var isLeaf: Bool { kind != .directory }
    public var path: String { url.path }

    /// Merge a completed child subtree into this directory node.
    public func adopt(_ child: StorageNode) {
        children.append(child)
        size += child.size
        symlinkCount += child.symlinkCount
        excludedCount += child.excludedCount
        if child.kind == .directory {
            directoryCount += 1 + child.directoryCount
            fileCount += child.fileCount
        } else {
            fileCount += 1
        }
    }

    /// Removes descendants whose normalized path is in `paths`, adjusting this
    /// node's aggregates so the tree reflects the live filesystem. Returns the
    /// bytes removed. (Class semantics: all holders of this node see the change.)
    @discardableResult
    public func removeDescendants(matching paths: Set<String>) -> Int64 {
        prune(matching: Set(paths.map { PathKit.normalize($0) })).bytes
    }

    private struct RemovalDelta {
        var bytes: Int64 = 0
        var files = 0
        var directories = 0
    }

    private func prune(matching targets: Set<String>) -> RemovalDelta {
        var delta = RemovalDelta()
        var kept: [StorageNode] = []
        for child in children {
            if targets.contains(PathKit.normalize(child.url.path)) {
                delta.bytes += child.size
                if child.kind == .directory {
                    delta.directories += 1 + child.directoryCount
                    delta.files += child.fileCount
                } else {
                    delta.files += 1
                }
            } else {
                let childDelta = child.prune(matching: targets)
                delta.bytes += childDelta.bytes
                delta.files += childDelta.files
                delta.directories += childDelta.directories
                kept.append(child)
            }
        }
        children = kept
        size = max(0, size - delta.bytes)
        fileCount = max(0, fileCount - delta.files)
        directoryCount = max(0, directoryCount - delta.directories)
        return delta
    }

    /// Per-category byte totals. Every byte is counted exactly once:
    /// materialized leaves carry their own category; unmaterialized small files
    /// inherit their parent directory's category (documented approximation).
    public func categoryTotals() -> [StorageCategory: Int64] {
        var totals: [StorageCategory: Int64] = [:]
        func visit(_ n: StorageNode) {
            if n.isLeaf {
                totals[n.category, default: 0] += n.size
            } else {
                totals[n.category, default: 0] += n.smallFileBytes
                for c in n.children { visit(c) }
            }
        }
        visit(self)
        return totals
    }

    /// Largest materialized leaves, sorted descending. Collects lightweight
    /// (size, node) pairs first and materializes FileRecords only for the
    /// top `limit` — the old version allocated a FileRecord (URL + strings)
    /// for every leaf in the tree before sorting (PF-7).
    public func largestFiles(limit: Int) -> [FileRecord] {
        var leaves: [(size: Int64, node: StorageNode)] = []
        func visit(_ n: StorageNode) {
            if n.isLeaf {
                leaves.append((n.size, n))
            } else {
                for c in n.children { visit(c) }
            }
        }
        visit(self)
        leaves.sort { $0.size > $1.size }
        return leaves.prefix(limit).map {
            FileRecord(url: $0.node.url, name: $0.node.name, size: $0.node.size, modDate: $0.node.modDate,
                       category: $0.node.category, isPackage: $0.node.kind == .package)
        }
    }

    public var inaccessibleCount: Int {
        var count = (errorDescription != nil) ? 1 : 0
        for c in children { count += c.inaccessibleCount }
        return count
    }
}

// MARK: - Scan domain

public struct FileRecord: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let size: Int64
    public let modDate: Date?
    public let category: StorageCategory
    public let isPackage: Bool

    public init(id: String? = nil, url: URL, name: String, size: Int64, modDate: Date?, category: StorageCategory, isPackage: Bool) {
        self.id = id ?? url.path
        self.url = url
        self.name = name
        self.size = size
        self.modDate = modDate
        self.category = category
        self.isPackage = isPackage
    }
}

public struct ScanProgress: Sendable, Equatable {
    public var filesSeen: Int
    public var bytesSeen: Int64
    public var directoriesSeen: Int
    public var currentPath: String
    public var elapsed: TimeInterval

    public init(filesSeen: Int, bytesSeen: Int64, directoriesSeen: Int, currentPath: String, elapsed: TimeInterval) {
        self.filesSeen = filesSeen
        self.bytesSeen = bytesSeen
        self.directoriesSeen = directoriesSeen
        self.currentPath = currentPath
        self.elapsed = elapsed
    }
}

public enum ScanEvent: Sendable {
    case progress(ScanProgress)
    case directoryCompleted(StorageNode)
    case completed(ScanResult)
    case failed(String)
    case cancelled
}

public struct ScanOptions: Sendable {
    /// Files at or above this size become tree nodes; smaller files are aggregated.
    public var largeFileThresholdBytes: Int64 = 10_000_000
    /// Maximum concurrent directory walks.
    public var maxConcurrentDirectoryWalks: Int = 8
    /// Below this depth, subtree walks run sequentially (wide+deep task explosion guard).
    public var parallelDepthLimit: Int = 8
    /// Emit `directoryCompleted` events for depths 1...this value (progressive
    /// UI). 0 = no per-directory events (nothing consumes them; they only
    /// cost continuation hops).
    public var progressEventMaxDepth: Int = 0
    /// Normalized paths excluded from scanning entirely.
    public var excludePaths: [String] = []
    /// Hard timeout for a single directory enumeration. Some system
    /// directories block open() forever (no error); the watchdog abandons
    /// them so the scan completes and flags them inaccessible.
    public var enumerationTimeoutSeconds: Double = 10
    /// Downloads root — its DIRECT files materialize above
    /// `downloadsMaterializationBytes` instead of the (much larger) global
    /// threshold, so 1–10 MB installers/archives stay visible to cleanup
    /// (SV-4). Only the Downloads root itself gets the lower bar; deeper
    /// folders keep the global threshold to bound memory.
    public var downloadsRoot: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads").path
    public var downloadsMaterializationBytes: Int64 = 1_000_000

    /// Tier 4 gentle scan: fewer walkers so the Mac stays quiet on battery.
    public static func gentle() -> ScanOptions {
        var options = ScanOptions()
        options.maxConcurrentDirectoryWalks = 2
        options.parallelDepthLimit = 4
        return options
    }

    public init() {}
    public static var standard: ScanOptions { ScanOptions() }
}

public struct ScanResult: @unchecked Sendable {
    public let root: StorageNode
    public let label: String
    public let startedAt: Date
    public let duration: TimeInterval
    public let filesCount: Int
    public let directoriesCount: Int
    public let inaccessibleCount: Int
    /// Mutable so the app can prune trashed items without a rescan.
    public var categories: [StorageCategory: Int64]
    public var largestFiles: [FileRecord]
    public let isQuickScan: Bool

    public var totalBytes: Int64 { root.size }

    public init(root: StorageNode, label: String, startedAt: Date, duration: TimeInterval,
                filesCount: Int, directoriesCount: Int, inaccessibleCount: Int,
                categories: [StorageCategory: Int64], largestFiles: [FileRecord], isQuickScan: Bool) {
        self.root = root
        self.label = label
        self.startedAt = startedAt
        self.duration = duration
        self.filesCount = filesCount
        self.directoriesCount = directoriesCount
        self.inaccessibleCount = inaccessibleCount
        self.categories = categories
        self.largestFiles = largestFiles
        self.isQuickScan = isQuickScan
    }
}

// MARK: - Volumes

public struct VolumeInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let isInternal: Bool
    public let totalBytes: Int64
    public let availableBytes: Int64

    public init(id: String, url: URL, name: String, isInternal: Bool, totalBytes: Int64, availableBytes: Int64) {
        self.id = id
        self.url = url
        self.name = name
        self.isInternal = isInternal
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    public var freeRatio: Double { totalBytes > 0 ? Double(availableBytes) / Double(totalBytes) : 0 }
}

// MARK: - Formatting

public enum Format {
    /// Cached formatters — these run per table row and per progress event;
    /// allocating a fresh formatter per call was measurable churn (PF-7).
    /// (Immutable-after-setup formatters are thread-safe.)
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    private static let relativeFormatter = RelativeDateTimeFormatter()

    public static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: value)
    }

    public static func percent(_ fraction: Double) -> String {
        let clamped = max(0, min(1, fraction))
        return "\(Int((clamped * 100).rounded()))%"
    }

    public static func relativeDate(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
