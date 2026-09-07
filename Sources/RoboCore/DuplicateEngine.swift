import Foundation
import CryptoKit

/// Cancellation signal that survives the hop onto dedicated hash threads —
/// `Task.isCancelled` is always false there (no task context), so cancelling
/// the duplicate scan must flip this flag instead.
final class HashCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

/// Hard-link identity: two directory entries sharing one inode are ONE
/// physical file — trashing either frees nothing.
struct InodeKey: Hashable {
    let dev: Int32
    let ino: UInt64
}

public struct DuplicateFile: Identifiable, Hashable, Sendable {
    public let url: URL
    public let size: Int64
    public let modDate: Date?

    public init(url: URL, size: Int64, modDate: Date?) {
        self.url = url
        self.size = size
        self.modDate = modDate
    }

    public var id: String { url.path }
}

public struct DuplicateGroup: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let files: [DuplicateFile]

    public init(files: [DuplicateFile]) {
        self.id = UUID()
        self.files = files.sorted { $0.url.path < $1.url.path }
    }

    public var fileSize: Int64 { files.first?.size ?? 0 }
    public var wastedBytes: Int64 { fileSize * Int64(max(0, files.count - 1)) }
}

public enum DuplicateStage: String, Sendable {
    case collecting, grouping, hashing, verifying, done
}

public struct DuplicateProgress: Sendable {
    public var stage: DuplicateStage
    public var filesSeen: Int
    public var groupsFound: Int
}/// Duplicate detection pipeline: group by exact size → 64 KB partial SHA-256 →
/// full-content SHA-256. Only byte-verified groups are reported. No expensive
/// hashing happens without a size match first.
public struct DuplicateEngine: Sendable {
    public init() {}

    /// Roots for a "Scan Area" duplicate scan: the actual roots of the last
    /// scan — never a synthetic wrapper root like the Quick Scan's "/", which
    /// would walk the ENTIRE filesystem (the reported duplicate-scan hang).
    public static func resolveScanAreaRoots(lastScanRoots: [URL]?, home: URL) -> [URL] {
        let roots = (lastScanRoots?.isEmpty == false) ? lastScanRoots! : [home]
        if roots.contains(where: { $0.path == "/" }) { return [home] }
        return roots
    }

    public func findDuplicates(roots: [URL],
                               minSizeBytes: Int64 = 1_000_000,
                               options scanOptions: ScanOptions = .standard,
                               progress: (@Sendable (DuplicateProgress) -> Void)? = nil) async -> [DuplicateGroup] {
        var options = scanOptions
        options.largeFileThresholdBytes = minSizeBytes
        options.progressEventMaxDepth = 0
        options.excludePaths = options.excludePaths.map { PathKit.normalize($0) }
        let tracker = ScanProgressTracker()
        let startedAt = Date()

        // Cancellation must reach the dedicated hash threads (Task.isCancelled
        // is dead there) — flipped by withTaskCancellationHandler below.
        let cancel = HashCancellation()

        // 1. Collect files ≥ minSize across all roots, streaming live counts so
        // the UI shows movement (a static stage label reads as a hang).
        progress?(DuplicateProgress(stage: .collecting, filesSeen: 0, groupsFound: 0))
        let reporter = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { break }
                let snapshot = tracker.snapshot(startedAt: startedAt)
                progress?(DuplicateProgress(stage: .collecting, filesSeen: snapshot.filesSeen, groupsFound: 0))
            }
        }
        var collected: [DuplicateFile] = []
        for root in roots {
            if Task.isCancelled { break }
            let node = await ScanEngine.walk(root, depth: 0, options: options, tracker: tracker,
                                             continuation: nil, startedAt: startedAt)
            collectLeaves(node, minSize: minSizeBytes, into: &collected)
        }
        reporter.cancel()

        // Hard links: same inode = one physical file, never a duplicate.
        var files: [DuplicateFile] = []
        var seenInodes = Set<InodeKey>()
        for file in collected {
            var st = stat()
            if stat(file.url.path, &st) == 0 {
                if !seenInodes.insert(InodeKey(dev: st.st_dev, ino: st.st_ino)).inserted {
                    continue
                }
            }
            files.append(file)
        }
        progress?(DuplicateProgress(stage: .collecting,
                                    filesSeen: tracker.snapshot(startedAt: startedAt).filesSeen,
                                    groupsFound: 0))

        // 2. Group by exact size; singletons cannot be duplicates.
        progress?(DuplicateProgress(stage: .grouping, filesSeen: files.count, groupsFound: 0))
        let bySize = Dictionary(grouping: files, by: \.size).filter { $0.value.count > 1 }
        let candidates = bySize.flatMap(\.value)

        // 3 + 4. Hashing (partial, then full verification) — every candidate
        // is submitted as its own job so the pool (not the await structure)
        // decides parallelism; awaiting one file at a time serialized this.
        return await withTaskCancellationHandler {
            if Task.isCancelled || candidates.isEmpty { return [] }

            progress?(DuplicateProgress(stage: .hashing, filesSeen: files.count, groupsFound: 0))
            var partialHashes: [DuplicateFile: String?] = [:]
            await withTaskGroup(of: (DuplicateFile, String?).self) { group in
                for file in candidates {
                    group.addTask {
                        let hash = await DedicatedPool.hashing.run {
                            cancel.isCancelled ? nil : Self.partialHash(file.url)
                        }
                        return (file, hash)
                    }
                }
                for await (file, hash) in group {
                    partialHashes[file] = hash
                }
            }
            if Task.isCancelled || cancel.isCancelled { return [] }

            let partialMatches: [[DuplicateFile]] = {
                var keyed: [String: [DuplicateFile]] = [:]
                for (_, group) in bySize {
                    var subgrouped: [String: [DuplicateFile]] = [:]
                    for file in group {
                        let key = partialHashes[file].flatMap { $0 } ?? "unreadable-\(file.id)"
                        subgrouped[key, default: []].append(file)
                    }
                    for subgroup in subgrouped.values where subgroup.count > 1 {
                        keyed["\(subgroup[0].id)", default: []].append(contentsOf: subgroup)
                    }
                }
                return Array(keyed.values)
            }()

            progress?(DuplicateProgress(stage: .verifying, filesSeen: files.count, groupsFound: partialMatches.count))
            var fullHashes: [DuplicateFile: String?] = [:]
            let verifyCandidates = partialMatches.flatMap { $0 }
            await withTaskGroup(of: (DuplicateFile, String?).self) { group in
                for file in verifyCandidates {
                    group.addTask {
                        let hash = await DedicatedPool.hashing.run {
                            Self.fullHash(file.url, isCancelled: { cancel.isCancelled })
                        }
                        return (file, hash)
                    }
                }
                for await (file, hash) in group {
                    fullHashes[file] = hash
                }
            }
            if Task.isCancelled || cancel.isCancelled { return [] }

            var groups: [DuplicateGroup] = []
            for group in partialMatches {
                var keyed: [String: [DuplicateFile]] = [:]
                for file in group {
                    let key = fullHashes[file].flatMap { $0 } ?? "unreadable-\(file.id)"
                    keyed[key, default: []].append(file)
                }
                for verified in keyed.values where verified.count > 1 {
                    groups.append(DuplicateGroup(files: verified))
                }
            }

            progress?(DuplicateProgress(stage: .done, filesSeen: files.count, groupsFound: groups.count))
            return groups.sorted { $0.wastedBytes > $1.wastedBytes }
        } onCancel: {
            cancel.cancel()
        }
    }

    /// Resolves per-group selections to file URLs across ALL groups. Selection
    /// state is keyed by group so a file ID is always looked up inside the
    /// group that owns it (IDs are paths — unique per file, but only findable
    /// within the right group).
    public static func selectedURLs(in groups: [DuplicateGroup], selections: [UUID: Set<String>]) -> [URL] {
        var urls: [URL] = []
        for (groupID, ids) in selections {
            guard let group = groups.first(where: { $0.id == groupID }) else { continue }
            urls += ids.compactMap { id in group.files.first { $0.id == id }?.url }
        }
        return urls
    }

    private func collectLeaves(_ node: StorageNode, minSize: Int64, into files: inout [DuplicateFile]) {
        if node.isLeaf {
            if node.size >= minSize {
                files.append(DuplicateFile(url: node.url, size: node.size, modDate: node.modDate))
            }
        } else {
            for child in node.children { collectLeaves(child, minSize: minSize, into: &files) }
        }
    }

    static func partialHash(_ url: URL, bytes: Int = 65_536) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fullHash(_ url: URL, chunkSize: Int = 1_048_576,
                         isCancelled: (() -> Bool)? = nil) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if isCancelled?() == true { return nil }
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
