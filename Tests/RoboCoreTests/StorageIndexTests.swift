import XCTest
@testable import RoboCore

// MARK: - SQLite storage index (Tier 4 foundation)

final class StorageIndexTests: XCTestCase {
    var dir: URL!
    var index: StorageIndex!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskrobo-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        index = try StorageIndex(url: dir.appendingPathComponent("index.sqlite"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeSnapshot(date: Date, used: Int64, free: Int64? = 50_000) -> Snapshot {
        Snapshot(date: date, rootPath: "/Users/x", isQuickScan: false,
                 volumeTotalBytes: 500_000, volumeFreeBytes: free,
                 usedBytes: used, categories: ["caches": used], topDirectories: ["/Users/x/Library/Caches": used],
                 largestFiles: [LargestFileEntry(path: "/Users/x/a.bin", size: used)], appFootprints: nil,
                 filesCount: 10, directoriesCount: 2, inaccessibleCount: 0, scanDurationSeconds: 1)
    }

    private func makeTree() -> StorageNode {
        // root ── Library ── Caches ── com.app (dir, 3 files: 1 big, 2 small)
        //      └─ big.dmg (file)
        let root = StorageNode(url: URL(fileURLWithPath: "/Users/x"))
        let library = StorageNode(url: URL(fileURLWithPath: "/Users/x/Library"))
        let caches = StorageNode(url: URL(fileURLWithPath: "/Users/x/Library/Caches"))
        let appCache = StorageNode(url: URL(fileURLWithPath: "/Users/x/Library/Caches/com.app"))
        appCache.size = 30_000_000
        appCache.smallFileCount = 2
        appCache.smallFileBytes = 5_000
        appCache.fileCount = 1
        appCache.children.append(StorageNode(url: URL(fileURLWithPath: "/Users/x/Library/Caches/com.app/big.bin"),
                                             kind: .file, size: 30_000_000 - 5_000,
                                             modDate: Date(timeIntervalSince1970: 1_700_000_000)))
        let dmg = StorageNode(url: URL(fileURLWithPath: "/Users/x/big.dmg"), kind: .file, size: 40_000_000)
        caches.adopt(appCache)
        library.adopt(caches)
        root.adopt(library)
        root.adopt(dmg)
        ClassificationEngine().classifyTree(root)
        return root
    }

    func testTreeRoundTripPreservesStructureAndAggregates() throws {
        let tree = makeTree()
        try index.saveTree(root: tree, info: StorageIndex.WarmScanInfo(startedAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 1, label: "Test", isQuickScan: false, roots: ["/Users/x"]))

        let restored = try XCTUnwrap(index.loadTree())
        XCTAssertEqual(restored.url.path, "/Users/x")
        XCTAssertEqual(restored.size, tree.size, "total bytes must round-trip")
        XCTAssertEqual(restored.fileCount, tree.fileCount)
        XCTAssertEqual(restored.directoryCount, tree.directoryCount)

        let caches = try XCTUnwrap(restored.children.first { $0.name == "Library" }?
            .children.first { $0.name == "Caches" })
        let appCache = try XCTUnwrap(caches.children.first { $0.name == "com.app" })
        XCTAssertEqual(appCache.smallFileCount, 2, "small-file aggregates must round-trip")
        XCTAssertEqual(appCache.smallFileBytes, 5_000)
        XCTAssertEqual(appCache.children.first?.kind, .file)
        XCTAssertEqual(appCache.children.first?.modDate, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(restored.children.first { $0.name == "big.dmg" }?.kind, .file)
        // Categories survive (warm start must recompute insights correctly).
        XCTAssertEqual(appCache.category, .caches)

        // Warm-start metadata round-trips.
        let info = try XCTUnwrap(index.loadWarmScanInfo())
        XCTAssertEqual(info.roots, ["/Users/x"])
        XCTAssertFalse(info.isQuickScan)
    }

    func testTreeSaveReplacesPreviousTree() throws {
        try index.saveTree(root: makeTree(), info: StorageIndex.WarmScanInfo(startedAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 1, label: "Test", isQuickScan: false, roots: ["/Users/x"]))
        let small = StorageNode(url: URL(fileURLWithPath: "/only/root"))
        try index.saveTree(root: small, info: StorageIndex.WarmScanInfo(startedAt: Date(), duration: 1, label: "Small", isQuickScan: false, roots: ["/only"]))
        let restored = try XCTUnwrap(index.loadTree())
        XCTAssertEqual(restored.url.path, "/only/root")
        XCTAssertTrue(restored.children.isEmpty)
    }

    func testSnapshotRecordLoadAndRetention() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<5 {
            try index.recordScan(makeSnapshot(date: base.addingTimeInterval(Double(i) * 60), used: Int64(i)), retention: 3)
        }
        let snapshots = index.loadSnapshots()
        XCTAssertEqual(snapshots.count, 3, "retention must prune old scans")
        XCTAssertEqual(snapshots.last?.usedBytes, 4, "newest scan survives")
        XCTAssertEqual(snapshots.first?.usedBytes, 2)
        XCTAssertEqual(snapshots.first?.categories["caches"], 2, "payload columns round-trip")
    }

    func testCleanupLogRoundTrip() throws {
        try index.recordCleanup(CleanupActionRecord(date: Date(), path: "/Users/x/a", sizeBytes: 42, kind: "cache",
                                                    mechanism: "trash", result: "trashed", reason: nil, trashPath: "/Users/x/.Trash/a"))
        let records = index.loadCleanupRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.sizeBytes, 42)
        XCTAssertEqual(records.first?.trashPath, "/Users/x/.Trash/a")
        XCTAssertEqual(records.first?.result, "trashed")
    }

    func testLegacyJSONMigration() throws {
        let legacy = HistoryStore(directory: dir.appendingPathComponent("legacy"))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        legacy.saveSnapshot(makeSnapshot(date: base, used: 7), retention: 10)
        legacy.recordCleanup(CleanupActionRecord(date: base, path: "/Users/x/old", sizeBytes: 9, kind: "cache",
                                                 mechanism: "trash", result: "trashed", reason: nil))

        let migrated = try index.importLegacy(from: legacy)
        XCTAssertEqual(migrated, 1)
        XCTAssertEqual(index.loadSnapshots().count, 1)
        XCTAssertEqual(index.loadSnapshots().first?.usedBytes, 7)
        XCTAssertEqual(index.loadCleanupRecords().count, 1)
        // Idempotent: a second import doesn't duplicate.
        XCTAssertEqual(try index.importLegacy(from: legacy), 0)
    }

    func testCorruptDatabaseDegradesInsteadOfCrashing() throws {
        let badPath = dir.appendingPathComponent("bad.sqlite")
        try Data(repeating: 0xFF, count: 512).write(to: badPath)
        // Opening a corrupt DB must not throw fatally — operations fail softly.
        let bad = try? StorageIndex(url: badPath)
        if let bad {
            XCTAssertNil(try? bad.loadTree())
            XCTAssertTrue(bad.loadSnapshots().isEmpty)
        }
    }

    func testDeleteAllHistory() throws {
        try index.recordScan(makeSnapshot(date: Date(), used: 1))
        try index.recordCleanup(CleanupActionRecord(date: Date(), path: "/a", sizeBytes: 1, kind: "k",
                                                    mechanism: "trash", result: "trashed", reason: nil))
        try index.saveTree(root: makeTree(), info: StorageIndex.WarmScanInfo(startedAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 1, label: "Test", isQuickScan: false, roots: ["/Users/x"]))
        try index.deleteAllHistory()
        XCTAssertTrue(index.loadSnapshots().isEmpty)
        XCTAssertTrue(index.loadCleanupRecords().isEmpty)
        XCTAssertNil(index.loadTree(), "tree must be cleared too")
    }

    func testLoadTreeLargeTreePerformance() throws {
        // Regression guard for the launch warm-start critical path: a
        // ~111k-node tree (the real quick-scan size) must rebuild fast.
        // The old 3-pass implementation took multiple seconds.
        let home = URL(fileURLWithPath: "/Users/x")
        let root = StorageNode(url: home)
        for d in 0..<100 {
            let top = StorageNode(url: home.appendingPathComponent("dir\(d)"))
            for s in 0..<100 {
                let sub = StorageNode(url: home.appendingPathComponent("dir\(d)/sub\(s)"),
                                      kind: .directory, size: 1_000)
                for f in 0..<10 {
                    sub.adopt(StorageNode(url: home.appendingPathComponent("dir\(d)/sub\(s)/file\(f)"),
                                          kind: .file, size: 100))
                }
                top.adopt(sub)
            }
            root.adopt(top)
        }
        try index.saveTree(root: root, info: StorageIndex.WarmScanInfo(
            startedAt: Date(), duration: 1, label: "Perf", isQuickScan: false, roots: ["/Users/x"]))

        let start = Date()
        let restored = try XCTUnwrap(index.loadTree())
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(restored.fileCount, root.fileCount, "tree must round-trip exactly")
        XCTAssertEqual(restored.size, root.size)
        print("PERF loadTree rebuild: \(String(format: "%.2f", elapsed))s for \(root.size) bytes of tree")
        XCTAssertLessThan(elapsed, 2.0, "111k-node warm start must stay well under 2s")
    }
}
