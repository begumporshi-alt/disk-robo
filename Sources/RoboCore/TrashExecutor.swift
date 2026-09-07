import Foundation

/// An item queued for trashing. Engine-proposed items require an approval token;
/// user-selected items (Files/Duplicates screens) are `userInitiated`.
public struct TrashedItem: Sendable {
    public let url: URL
    public let expected: ItemFingerprint?
    public let kind: String
    public let userInitiated: Bool
    public let approval: ApprovalToken?

    public init(url: URL, expected: ItemFingerprint? = nil, kind: String = "user", userInitiated: Bool = true, approval: ApprovalToken? = nil) {
        self.url = url
        self.expected = expected
        self.kind = kind
        self.userInitiated = userInitiated
        self.approval = approval
    }
}

public enum TrashOutcome: Sendable, Equatable {
    case trashed(bytes: Int64)
    case blocked(reason: String)
    case failed(reason: String)
}

public struct ItemTrashResult: Sendable, Identifiable {
    public let id: String
    public let path: String
    public let outcome: TrashOutcome

    public init(path: String, outcome: TrashOutcome) {
        self.id = path
        self.path = path
        self.outcome = outcome
    }
}

public struct CleanupExecutionOutcome: Sendable {
    public let results: [ItemTrashResult]
    public let startedAt: Date
    public let finishedAt: Date

    public init(results: [ItemTrashResult], startedAt: Date, finishedAt: Date) {
        self.results = results
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var freedBytes: Int64 {
        results.reduce(0) { acc, r in
            if case .trashed(let bytes) = r.outcome { return acc + bytes }
            return acc
        }
    }
    public var trashedCount: Int { results.filter { if case .trashed = $0.outcome { return true }; return false }.count }
    public var blockedCount: Int { results.filter { if case .blocked = $0.outcome { return true }; return false }.count }
    public var failedCount: Int { results.filter { if case .failed = $0.outcome { return true }; return false }.count }
    public var blockedItems: [ItemTrashResult] { results.filter { if case .blocked = $0.outcome { return true }; return false } }
    public var failedItems: [ItemTrashResult] { results.filter { if case .failed = $0.outcome { return true }; return false } }
}

/// The only component permitted to delete anything — always via move-to-Trash.
/// Pipeline per item: token gate (engine items) → re-stat + SafetyEngine
/// validation (veto possible) → trash → audit record → done. Failures are
/// isolated per item; a batch never aborts silently.
public final class TrashExecutor: Sendable {
    public let safety: SafetyEngine
    public let history: HistoryStore?
    /// SQLite audit sink (Tier 4) — the JSONL store remains as the
    /// compatibility/rollback path; both receive every record.
    public let index: StorageIndex?

    public init(safety: SafetyEngine, history: HistoryStore? = nil, index: StorageIndex? = nil) {
        self.safety = safety
        self.history = history
        self.index = index
    }

    public func trashItems(_ items: [TrashedItem]) async -> CleanupExecutionOutcome {
        let started = Date()
        var results: [ItemTrashResult] = []
        for item in items {
            if Task.isCancelled {
                results.append(ItemTrashResult(path: item.url.path, outcome: .blocked(reason: "Cancelled before this item was processed.")))
                continue
            }
            results.append(await trash(item))
        }
        return CleanupExecutionOutcome(results: results, startedAt: started, finishedAt: Date())
    }

    public func trash(_ item: TrashedItem) async -> ItemTrashResult {
        let path = item.url.path

        if !item.userInitiated {
            guard let token = item.approval else {
                return ItemTrashResult(path: path, outcome: .blocked(reason: "No approval token was provided."))
            }
            guard token.covers(path) else {
                return ItemTrashResult(path: path, outcome: .blocked(reason: "The approval does not cover this item or has expired."))
            }
        }

        // Record the real recoverable size: for directories the stat size is
        // just the entry (~bytes), so measure logical content size instead.
        let sizeBefore: Int64
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            sizeBefore = await DirectorySizer.logicalSize(of: item.url)
        } else if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber {
            sizeBefore = size.int64Value
        } else {
            sizeBefore = 0
        }

        switch safety.validateTrash(path: path, userInitiated: item.userInitiated, expectedFingerprint: item.expected) {
        case .vetoed(let reason):
            record(item, outcome: "blocked", bytes: 0, reason: reason, trashPath: nil)
            return ItemTrashResult(path: path, outcome: .blocked(reason: reason))
        case .allowed:
            break
        }

        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: item.url, resultingItemURL: &resultingURL)
            let freed = sizeBefore > 0 ? sizeBefore : (item.expected?.size ?? 0)
            record(item, outcome: "trashed", bytes: freed, reason: nil, trashPath: resultingURL?.path)
            return ItemTrashResult(path: path, outcome: .trashed(bytes: freed))
        } catch {
            let reason = error.localizedDescription
            record(item, outcome: "failed", bytes: 0, reason: reason, trashPath: nil)
            return ItemTrashResult(path: path, outcome: .failed(reason: reason))
        }
    }

    private func record(_ item: TrashedItem, outcome: String, bytes: Int64, reason: String?, trashPath: String?) {
        let record = CleanupActionRecord(
            date: Date(),
            path: item.url.path,
            sizeBytes: bytes,
            kind: item.kind,
            mechanism: CleanupActionRecord.Mechanism.trash,
            result: outcome,
            reason: reason,
            trashPath: trashPath
        )
        history?.recordCleanup(record)
        index?.recordCleanup(record)
    }
}
