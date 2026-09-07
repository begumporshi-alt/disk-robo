import Foundation
import SQLite3

/// SQLite's SQLITE_TRANSIENT isn't exposed to Swift — define the same
/// destructor-unsafe pointer sentinel the C macro expands to.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed storage index — the Tier 4 foundation.
///
/// Holds three kinds of data in one database (`~/Library/Application
/// Support/DiskRobo/index.sqlite`):
/// - **History**: one row per scan (queryable scalar columns + a JSON payload
///   for the rest of today's `Snapshot`), powering Growth/Radar/Forecast.
/// - **Warm-start tree**: the LATEST scan's tree only (transactionally
///   replaced per scan) so the app can render a full dashboard instantly on
///   launch instead of empty placeholders.
/// - **Cleanup audit log**: replaces `cleanup-log.jsonl`.
///
/// Concurrency: one connection on a serial queue (the HistoryStore pattern).
/// All failures degrade softly — a corrupt database never crashes the app.
public final class StorageIndex: @unchecked Sendable {
    private let db: OpaquePointer?
    private let queue = DispatchQueue(label: "diskrobo.storageindex")

    public init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            throw StorageIndexError.openFailed(message)
        }
        db = handle
        try execute("""
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS scans (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            started_at REAL NOT NULL,
            duration REAL NOT NULL,
            label TEXT NOT NULL,
            is_quick INTEGER NOT NULL,
            root_path TEXT NOT NULL,
            files_count INTEGER NOT NULL,
            directories_count INTEGER NOT NULL,
            total_bytes INTEGER NOT NULL,
            volume_total INTEGER,
            volume_free INTEGER,
            payload BLOB NOT NULL
        );
        CREATE TABLE IF NOT EXISTS tree_nodes (
            path TEXT PRIMARY KEY,
            parent_path TEXT,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            size INTEGER NOT NULL,
            category TEXT NOT NULL,
            file_count INTEGER NOT NULL,
            directory_count INTEGER NOT NULL,
            small_file_count INTEGER NOT NULL,
            small_file_bytes INTEGER NOT NULL,
            mtime REAL
        );
        CREATE TABLE IF NOT EXISTS cleanup_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            date REAL NOT NULL,
            path TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            kind TEXT,
            mechanism TEXT,
            result TEXT,
            reason TEXT,
            trash_path TEXT
        );
        """)
    }

    deinit {
        sqlite3_close_v2(db)
    }

    public enum StorageIndexError: Error, CustomStringConvertible {
        case openFailed(String)
        case sqlFailed(String)

        public var description: String {
            switch self {
            case .openFailed(let m): return "StorageIndex: cannot open database: \(m)"
            case .sqlFailed(let m): return "StorageIndex: \(m)"
            }
        }
    }

    // MARK: - Primitives

    private func execute(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errmsg) == SQLITE_OK else {
            let message = errmsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errmsg)
            throw StorageIndexError.sqlFailed(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StorageIndexError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    // MARK: - Scan history

    /// Records a scan and prunes to `retention` newest rows.
    public func recordScan(_ snapshot: Snapshot, retention: Int = 120) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let payload = try? encoder.encode(snapshot) else { return }
        queue.sync {
            do {
                try execute("BEGIN IMMEDIATE")
                let stmt = try prepare("""
                INSERT INTO scans (started_at, duration, label, is_quick, root_path, files_count,
                                   directories_count, total_bytes, volume_total, volume_free, payload)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """)
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_double(stmt, 1, snapshot.date.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 2, snapshot.scanDurationSeconds)
                sqlite3_bind_text(stmt, 3, snapshot.rootPath, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 4, snapshot.isQuickScan ? 1 : 0)
                sqlite3_bind_text(stmt, 5, snapshot.rootPath, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 6, Int64(snapshot.filesCount))
                sqlite3_bind_int64(stmt, 7, Int64(snapshot.directoriesCount))
                sqlite3_bind_int64(stmt, 8, snapshot.usedBytes)
                snapshot.volumeTotalBytes.map { sqlite3_bind_int64(stmt, 9, $0) }
                snapshot.volumeFreeBytes.map { sqlite3_bind_int64(stmt, 10, $0) }
                sqlite3_bind_blob(stmt, 11, (payload as NSData).bytes, Int32(payload.count), SQLITE_TRANSIENT)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw StorageIndexError.sqlFailed(String(cString: sqlite3_errmsg(db)))
                }
                try execute("DELETE FROM scans WHERE id NOT IN (SELECT id FROM scans ORDER BY id DESC LIMIT \(retention))")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
            }
        }
    }

    public func loadSnapshots() -> [Snapshot] {
        queue.sync { loadSnapshotsNoQueue() }
    }

    private func loadSnapshotsNoQueue() -> [Snapshot] {
        guard db != nil else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sql = "SELECT payload FROM scans ORDER BY started_at ASC, id ASC"
        guard let stmt = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Snapshot] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let blob = sqlite3_column_blob(stmt, 0) {
                let count = Int(sqlite3_column_bytes(stmt, 0))
                let data = Data(bytes: blob, count: count)
                if let snapshot = try? decoder.decode(Snapshot.self, from: data) {
                    out.append(snapshot)
                }
            }
        }
        return out
    }

    // MARK: - Warm-start tree

    /// Metadata about the scan whose tree is stored — powers the launch-time
    /// warm start (instant dashboard) and the staleness indicator.
    public struct WarmScanInfo: Sendable {
        public let startedAt: Date
        public let duration: TimeInterval
        public let label: String
        public let isQuickScan: Bool
        public let roots: [String]

        public init(startedAt: Date, duration: TimeInterval, label: String, isQuickScan: Bool, roots: [String]) {
            self.startedAt = startedAt
            self.duration = duration
            self.label = label
            self.isQuickScan = isQuickScan
            self.roots = roots
        }
    }

    /// Replaces the stored tree with `root`'s full subtree (only the latest
    /// scan's tree is ever kept — one ~15 MB copy, not one per scan).
    public func saveTree(root: StorageNode, info: WarmScanInfo) {
        queue.sync {
            do {
                try execute("BEGIN IMMEDIATE")
                try execute("DELETE FROM tree_nodes")
                let stmt = try prepare("""
                INSERT OR REPLACE INTO tree_nodes
                    (path, parent_path, name, kind, size, category, file_count, directory_count,
                     small_file_count, small_file_bytes, mtime)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """)
                defer { sqlite3_finalize(stmt) }

                func bind(_ node: StorageNode, parentPath: String?) {
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, node.path, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, parentPath, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 3, node.name, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 4, node.kind.rawValue, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(stmt, 5, node.size)
                    sqlite3_bind_text(stmt, 6, node.category.rawValue, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(stmt, 7, Int64(node.fileCount))
                    sqlite3_bind_int64(stmt, 8, Int64(node.directoryCount))
                    sqlite3_bind_int64(stmt, 9, Int64(node.smallFileCount))
                    sqlite3_bind_int64(stmt, 10, Int64(node.smallFileBytes))
                    node.modDate.map { sqlite3_bind_double(stmt, 11, $0.timeIntervalSince1970) }
                    _ = sqlite3_step(stmt)
                    for child in node.children {
                        bind(child, parentPath: node.path)
                    }
                }
                bind(root, parentPath: nil)

                func setMeta(_ key: String, _ value: String) throws {
                    let meta = try prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?,?)")
                    defer { sqlite3_finalize(meta) }
                    sqlite3_bind_text(meta, 1, key, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(meta, 2, value, -1, SQLITE_TRANSIENT)
                    _ = sqlite3_step(meta)
                }
                try setMeta("warm.startedAt", String(info.startedAt.timeIntervalSince1970))
                try setMeta("warm.duration", String(info.duration))
                try setMeta("warm.label", info.label)
                try setMeta("warm.isQuick", info.isQuickScan ? "1" : "0")
                try setMeta("warm.roots", info.roots.joined(separator: "\n"))
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
            }
        }
    }

    /// The metadata of the stored tree's scan, or nil when no warm start exists.
    public func loadWarmScanInfo() -> WarmScanInfo? {
        queue.sync { [self] in
            guard db != nil else { return nil }
            func meta(_ key: String) -> String? {
                guard let stmt = try? prepare("SELECT value FROM meta WHERE key = ?") else { return nil }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(stmt) == SQLITE_ROW, let cString = sqlite3_column_text(stmt, 0) else { return nil }
                return String(cString: cString)
            }
            guard let startedAt = meta("warm.startedAt").flatMap(Double.init),
                  let duration = meta("warm.duration").flatMap(Double.init),
                  let label = meta("warm.label") else { return nil }
            return WarmScanInfo(
                startedAt: Date(timeIntervalSince1970: startedAt),
                duration: duration,
                label: label,
                isQuickScan: meta("warm.isQuick") == "1",
                roots: meta("warm.roots")?.split(separator: "\n").map(String.init) ?? []
            )
        }
    }

    /// Reconstructs the stored tree, or nil when none exists (fresh install,
    /// cleared history, or unreadable database).
    ///
    /// Single pass: rows come back in rowid order — the DFS insertion order —
    /// so every row's parent has already been created when the row is read.
    /// The old version made three passes over all rows (collect, index, link)
    /// with a full `rows` array materialized; on a 100k-node tree that was
    /// the visible part of the launch warm-start delay.
    public func loadTree() -> StorageNode? {
        queue.sync { [self] in
            guard db != nil else { return nil }
            let sql = "SELECT path, parent_path, name, kind, size, category, file_count, directory_count, small_file_count, small_file_bytes, mtime FROM tree_nodes"
            guard let stmt = try? prepare(sql) else { return nil }
            defer { sqlite3_finalize(stmt) }

            var byPath: [String: StorageNode] = [:]
            var root: StorageNode?
            while sqlite3_step(stmt) == SQLITE_ROW {
                func text(_ index: Int32) -> String {
                    guard let cString = sqlite3_column_text(stmt, index) else { return "" }
                    return String(cString: cString)
                }
                let path = text(0)
                let kind = NodeKind(rawValue: text(3)) ?? .directory
                let category = StorageCategory(rawValue: text(5)) ?? .other
                let modDate: Date? = {
                    guard sqlite3_column_type(stmt, 10) != SQLITE_NULL else { return nil }
                    return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
                }()
                let node = StorageNode(url: URL(fileURLWithPath: path), name: text(2),
                                       kind: kind, size: sqlite3_column_int64(stmt, 4),
                                       modDate: modDate, category: category)
                node.fileCount = Int(sqlite3_column_int64(stmt, 6))
                node.directoryCount = Int(sqlite3_column_int64(stmt, 7))
                node.smallFileCount = Int(sqlite3_column_int64(stmt, 8))
                node.smallFileBytes = sqlite3_column_int64(stmt, 9)
                byPath[path] = node

                if sqlite3_column_type(stmt, 1) == SQLITE_NULL {
                    root = node
                } else if let parent = byPath[text(1)] {
                    // Direct append, NOT adopt(): the stored aggregates already
                    // include every descendant — adopt would double-count them.
                    parent.children.append(node)
                }
            }
            return root
        }
    }

    // MARK: - Cleanup audit log

    public func recordCleanup(_ record: CleanupActionRecord) {
        queue.sync { recordCleanupNoQueue(record) }
    }

    private func recordCleanupNoQueue(_ record: CleanupActionRecord) {
        do {
            let stmt = try prepare("""
            INSERT INTO cleanup_log (date, path, size_bytes, kind, mechanism, result, reason, trash_path)
            VALUES (?,?,?,?,?,?,?,?)
            """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, record.date.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, record.path, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, record.sizeBytes)
            sqlite3_bind_text(stmt, 4, record.kind, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, record.mechanism, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, record.result, -1, SQLITE_TRANSIENT)
            record.reason.map { sqlite3_bind_text(stmt, 7, $0, -1, SQLITE_TRANSIENT) }
            record.trashPath.map { sqlite3_bind_text(stmt, 8, $0, -1, SQLITE_TRANSIENT) }
            _ = sqlite3_step(stmt)
        } catch {
            // Soft-degrade: audit log loss is acceptable, never a crash.
        }
    }

    public func loadCleanupRecords() -> [CleanupActionRecord] {
        queue.sync { loadCleanupRecordsNoQueue() }
    }

    private func loadCleanupRecordsNoQueue() -> [CleanupActionRecord] {
        guard db != nil else { return [] }
        let sql = "SELECT date, path, size_bytes, kind, mechanism, result, reason, trash_path FROM cleanup_log ORDER BY date DESC"
        guard let stmt = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [CleanupActionRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ index: Int32) -> String? {
                guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
                      let cString = sqlite3_column_text(stmt, index) else { return nil }
                return String(cString: cString)
            }
            out.append(CleanupActionRecord(
                date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                path: text(1) ?? "",
                sizeBytes: sqlite3_column_int64(stmt, 2),
                kind: text(3) ?? "",
                mechanism: text(4) ?? "",
                result: text(5) ?? "",
                reason: text(6),
                trashPath: text(7)
            ))
        }
        return out
    }

    // MARK: - History management & migration

    public func deleteAllHistory() {
        queue.sync {
            try? execute("DELETE FROM scans")
            try? execute("DELETE FROM tree_nodes")
            try? execute("DELETE FROM cleanup_log")
        }
    }

    /// One-time import from the legacy JSON store. Idempotent: returns the
    /// number of NEWLY imported snapshots (0 on a re-run).
    @discardableResult
    public func importLegacy(from legacy: HistoryStore) throws -> Int {
        let legacySnapshots = legacy.loadSnapshots()
        let legacyRecords = legacy.loadCleanupRecords()
        // NOTE: everything below runs in ONE queue.sync — the no-queue cores
        // must be used inside (nested queue.sync on a serial queue deadlocks).
        return queue.sync { [self] () -> Int in
            guard db != nil else { return 0 }
            func snapshotKey(_ s: Snapshot) -> String {
                "\(s.date.timeIntervalSince1970)|\(s.usedBytes)|\(s.filesCount)"
            }
            let existing = Set(loadSnapshotsNoQueue().map(snapshotKey))
            var count = 0
            for snapshot in legacySnapshots where !existing.contains(snapshotKey(snapshot)) {
                recordScanNoQueue(snapshot)
                count += 1
            }
            let existingRecords = Set(loadCleanupRecordsNoQueue().map { "\($0.path)|\($0.date.timeIntervalSince1970)" })
            for record in legacyRecords where
                !existingRecords.contains("\(record.path)|\(record.date.timeIntervalSince1970)") {
                recordCleanupNoQueue(record)
            }
            return count
        }
    }

    private func recordScanNoQueue(_ snapshot: Snapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let payload = try? encoder.encode(snapshot) else { return }
        guard let stmt = try? prepare("""
        INSERT INTO scans (started_at, duration, label, is_quick, root_path, files_count,
                           directories_count, total_bytes, volume_total, volume_free, payload)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
        """) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, snapshot.date.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, snapshot.scanDurationSeconds)
        sqlite3_bind_text(stmt, 3, snapshot.rootPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 4, snapshot.isQuickScan ? 1 : 0)
        sqlite3_bind_text(stmt, 5, snapshot.rootPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 6, Int64(snapshot.filesCount))
        sqlite3_bind_int64(stmt, 7, Int64(snapshot.directoriesCount))
        sqlite3_bind_int64(stmt, 8, snapshot.usedBytes)
        snapshot.volumeTotalBytes.map { sqlite3_bind_int64(stmt, 9, $0) }
        snapshot.volumeFreeBytes.map { sqlite3_bind_int64(stmt, 10, $0) }
        sqlite3_bind_blob(stmt, 11, (payload as NSData).bytes, Int32(payload.count), SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
    }
}
