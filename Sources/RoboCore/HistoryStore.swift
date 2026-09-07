import Foundation

/// Lightweight storage snapshot — metadata only, never file contents.
public struct LargestFileEntry: Codable, Sendable, Hashable {
    public let path: String
    public let size: Int64
}

public struct AppFootprintEntry: Codable, Sendable, Hashable {
    public let name: String
    public let bundleID: String?
    public let totalBytes: Int64
}

public struct Snapshot: Codable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var rootPath: String
    public var isQuickScan: Bool
    public var volumeTotalBytes: Int64?
    public var volumeFreeBytes: Int64?
    public var usedBytes: Int64
    public var categories: [String: Int64]
    public var topDirectories: [String: Int64]
    public var largestFiles: [LargestFileEntry]
    public var appFootprints: [AppFootprintEntry]?
    public var filesCount: Int
    public var directoriesCount: Int
    public var inaccessibleCount: Int
    public var scanDurationSeconds: TimeInterval

    public init(id: UUID = UUID(), date: Date, rootPath: String, isQuickScan: Bool,
                volumeTotalBytes: Int64?, volumeFreeBytes: Int64?, usedBytes: Int64,
                categories: [String: Int64], topDirectories: [String: Int64],
                largestFiles: [LargestFileEntry], appFootprints: [AppFootprintEntry]?,
                filesCount: Int, directoriesCount: Int, inaccessibleCount: Int,
                scanDurationSeconds: TimeInterval) {
        self.id = id
        self.date = date
        self.rootPath = rootPath
        self.isQuickScan = isQuickScan
        self.volumeTotalBytes = volumeTotalBytes
        self.volumeFreeBytes = volumeFreeBytes
        self.usedBytes = usedBytes
        self.categories = categories
        self.topDirectories = topDirectories
        self.largestFiles = largestFiles
        self.appFootprints = appFootprints
        self.filesCount = filesCount
        self.directoriesCount = directoriesCount
        self.inaccessibleCount = inaccessibleCount
        self.scanDurationSeconds = scanDurationSeconds
    }

    public static func from(result: ScanResult, apps: [AppFootprint]? = nil,
                            volume: VolumeInfo?) -> Snapshot {
        var topDirs: [String: Int64] = [:]
        func visit(_ n: StorageNode, depth: Int) {
            if depth >= 1 && depth <= 4 && n.size > 100_000_000 {
                topDirs[n.url.path] = n.size
            }
            for c in n.children where !c.isLeaf { visit(c, depth: depth + 1) }
        }
        visit(result.root, depth: 0)

        return Snapshot(
            date: result.startedAt,
            rootPath: result.root.url.path,
            isQuickScan: result.isQuickScan,
            volumeTotalBytes: volume?.totalBytes,
            volumeFreeBytes: volume?.availableBytes,
            usedBytes: result.totalBytes,
            categories: result.categories.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value },
            topDirectories: topDirs,
            largestFiles: result.largestFiles.prefix(100).map { LargestFileEntry(path: $0.url.path, size: $0.size) },
            appFootprints: apps?.prefix(50).map { AppFootprintEntry(name: $0.name, bundleID: $0.bundleID, totalBytes: $0.totalBytes) },
            filesCount: result.filesCount,
            directoriesCount: result.directoriesCount,
            inaccessibleCount: result.inaccessibleCount,
            scanDurationSeconds: result.duration
        )
    }
}

/// One record per trashed item — the audit log and crash-reconciliation source of truth.
public struct CleanupActionRecord: Codable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var path: String
    public var sizeBytes: Int64
    public var kind: String
    public var mechanism: String
    public var result: String
    public var reason: String?
    /// Where the item landed in the Trash (`trashItem`'s resulting URL), when known.
    /// Optional so audit lines written before this field existed keep decoding.
    public var trashPath: String?

    public enum Mechanism { public static let trash = "trash" }
    public enum Result {
        public static let trashed = "trashed"
        public static let blocked = "blocked"
        public static let failed = "failed"
    }

    public init(id: UUID = UUID(), date: Date, path: String, sizeBytes: Int64, kind: String,
                mechanism: String, result: String, reason: String?, trashPath: String? = nil) {
        self.id = id
        self.date = date
        self.path = path
        self.sizeBytes = sizeBytes
        self.kind = kind
        self.mechanism = mechanism
        self.result = result
        self.reason = reason
        self.trashPath = trashPath
    }
}

/// Storage Memory: snapshots + cleanup audit log, persisted as JSON in the
/// app's Application Support directory. Serialized through a private queue.
public final class HistoryStore: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "diskrobo.historystore")

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DiskRobo/history", isDirectory: true)
            self.directory = base
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public var storageDirectory: URL { directory }

    // MARK: Snapshots

    public func saveSnapshot(_ snapshot: Snapshot, retention: Int = 120) {
        queue.sync {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            let name = "\(snapshot.date.timeIntervalSince1970)-\(snapshot.id.uuidString).json"
            try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
            pruneSnapshots(retention: retention)
        }
    }

    public func loadSnapshots() -> [Snapshot] {
        queue.sync {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            return urls.filter { $0.pathExtension == "json" }
                .compactMap { try? Data(contentsOf: $0) }
                .compactMap { try? decoder.decode(Snapshot.self, from: $0) }
                .sorted { $0.date < $1.date }
        }
    }

    private func pruneSnapshots(retention: Int) {
        let fm = FileManager.default
        let urls = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard urls.count > retention else { return }
        for url in urls.prefix(urls.count - retention) {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: Cleanup audit log

    public func recordCleanup(_ record: CleanupActionRecord) {
        queue.sync {
            let url = directory.appendingPathComponent("cleanup-log.jsonl")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(record) else { return }
            var line = data
            line.append(0x0A)
            if let handle = FileHandle(forWritingAtPath: url.path) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url, options: .atomic)
            }
        }
    }

    public func loadCleanupRecords() -> [CleanupActionRecord] {
        queue.sync {
            let url = directory.appendingPathComponent("cleanup-log.jsonl")
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return content.split(separator: "\n")
                .compactMap { try? decoder.decode(CleanupActionRecord.self, from: Data($0.utf8)) }
                .sorted { $0.date > $1.date }
        }
    }

    public func clearAll() {
        queue.sync {
            let fm = FileManager.default
            for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: url)
            }
        }
    }
}
