import XCTest
@testable import RoboCore

final class HistoryAndGrowthTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskrobo-hist-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeSnapshot(date: Date, used: Int64, categories: [String: Int64], dirs: [String: Int64],
                      free: Int64? = nil) -> Snapshot {
        Snapshot(date: date, rootPath: "/Users/x", isQuickScan: false,
                 volumeTotalBytes: free != nil ? 500_000 : nil, volumeFreeBytes: free,
                 usedBytes: used, categories: categories, topDirectories: dirs,
                 largestFiles: [], appFootprints: nil,
                 filesCount: 10, directoriesCount: 2, inaccessibleCount: 0, scanDurationSeconds: 1)
    }

    func testSnapshotRoundTripAndAuditLog() {
        let store = HistoryStore(directory: dir)
        let snapshot = makeSnapshot(date: Date(timeIntervalSinceNow: -86_400), used: 400_000,
                                    categories: ["caches": 100_000], dirs: ["/Users/x/Library/Caches": 100_000])
        store.saveSnapshot(snapshot, retention: 10)
        let loaded = store.loadSnapshots()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].usedBytes, 400_000)
        XCTAssertEqual(loaded[0].categories["caches"], 100_000)

        store.recordCleanup(CleanupActionRecord(date: Date(), path: "/Users/x/Library/Caches/foo",
                                                sizeBytes: 123, kind: "cache",
                                                mechanism: CleanupActionRecord.Mechanism.trash,
                                                result: CleanupActionRecord.Result.trashed, reason: nil))
        XCTAssertEqual(store.loadCleanupRecords().count, 1)
        XCTAssertEqual(store.loadCleanupRecords()[0].sizeBytes, 123)

        store.clearAll()
        XCTAssertTrue(store.loadSnapshots().isEmpty)
    }

    func testRetentionPrunesOldSnapshots() {
        let store = HistoryStore(directory: dir)
        for i in 0..<5 {
            store.saveSnapshot(makeSnapshot(date: Date(timeIntervalSinceNow: -Double(i) * 60),
                                            used: Int64(i), categories: [:], dirs: [:]), retention: 3)
        }
        XCTAssertEqual(store.loadSnapshots().count, 3)
    }

    func testCleanupRecordTrashPathBackwardCompatibility() throws {
        // Lines written before trashPath existed must keep decoding (nil), so the
        // audit log never becomes unreadable after an app update.
        let legacyLine = """
        {"id":"5D4C1A3B-7E9F-4A6B-8C2D-1E0F2A3B4C5D","date":"2026-09-06T10:00:00Z","path":"/Users/x/a.txt","sizeBytes":10,"kind":"cache","mechanism":"trash","result":"trashed"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(CleanupActionRecord.self, from: Data(legacyLine.utf8))
        XCTAssertNil(legacy.trashPath)
        XCTAssertEqual(legacy.sizeBytes, 10)

        // Round-trip a record WITH the trash location.
        var record = legacy
        record.trashPath = "/Users/x/.Trash/a.txt"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let restored = try decoder.decode(CleanupActionRecord.self, from: encoder.encode(record))
        XCTAssertEqual(restored.trashPath, "/Users/x/.Trash/a.txt")
    }

    func testGrowthDiff() {
        let older = makeSnapshot(date: Date(timeIntervalSinceNow: -7 * 86_400), used: 300_000,
                                 categories: ["developer": 100_000, "media": 200_000],
                                 dirs: ["/Users/x/Library/Developer": 100_000, "/Users/x/Movies": 200_000],
                                 free: 200_000)
        let newer = makeSnapshot(date: Date(), used: 350_000,
                                 categories: ["developer": 180_000, "media": 170_000],
                                 dirs: ["/Users/x/Library/Developer": 180_000, "/Users/x/Movies": 170_000],
                                 free: 150_000)

        let delta = GrowthAnalyzer.diff(older, newer)
        XCTAssertEqual(delta.totalDelta, 50_000)
        XCTAssertEqual(delta.freeDelta, -50_000)

        let developerDelta = delta.categoryDeltas.first { $0.category == .developer }
        XCTAssertEqual(developerDelta?.delta, 80_000)

        let topGrower = delta.directoryDeltas.first { $0.delta > 0 }
        XCTAssertEqual(topGrower?.path, "/Users/x/Library/Developer")
        XCTAssertEqual(topGrower?.delta, 80_000)

        let narratives = GrowthAnalyzer.narratives(for: delta)
        XCTAssertFalse(narratives.isEmpty)
        XCTAssertTrue(narratives.contains { $0.contains("Library/Developer") })
    }
}

final class HealthScoreTests: XCTestCase {
    func testHealthyDiskScoresHigh() {
        let score = HealthScoreEngine.compute(freeRatio: 0.4, totalBytes: 1_000_000,
                                              greenRecoverableBytes: 5_000, duplicateBytes: 1_000,
                                              growth7dRatio: -0.001, trashLogBytes: 500)
        XCTAssertGreaterThanOrEqual(score.value, 90)
        XCTAssertFalse(score.factors.isEmpty)
        XCTAssertFalse(score.headline.isEmpty)
    }

    func testFullDiskScoresLow() {
        let score = HealthScoreEngine.compute(freeRatio: 0.02, totalBytes: 1_000_000,
                                              greenRecoverableBytes: 200_000, duplicateBytes: 100_000,
                                              growth7dRatio: 0.06, trashLogBytes: 80_000)
        XCTAssertLessThanOrEqual(score.value, 15)
    }

    func testMissingDataRenormalizesWeights() {
        let score = HealthScoreEngine.compute(freeRatio: 0.3, totalBytes: nil, greenRecoverableBytes: nil,
                                              duplicateBytes: nil, growth7dRatio: nil, trashLogBytes: nil)
        XCTAssertEqual(score.factors.count, 1)
        XCTAssertEqual(score.value, 100)
    }

    func testBoundsAlwaysWithin0to100() {
        let extreme = HealthScoreEngine.compute(freeRatio: -5, totalBytes: 1, greenRecoverableBytes: .max,
                                                duplicateBytes: .max, growth7dRatio: 100, trashLogBytes: .max)
        XCTAssertGreaterThanOrEqual(extreme.value, 0)
        XCTAssertLessThanOrEqual(extreme.value, 100)
    }
}

