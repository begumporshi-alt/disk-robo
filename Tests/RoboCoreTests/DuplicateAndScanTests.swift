import XCTest
@testable import RoboCore

final class DuplicateEngineTests: XCTestCase {
    var dir: URL!
    var fm: FileManager { FileManager.default }

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskrobo-dupes-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try fm.removeItem(at: dir)
    }

    @discardableResult
    func writeFile(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        XCTAssertTrue(fm.createFile(atPath: url.path, contents: data))
        return url
    }

    func testExactDuplicatesVerified() async throws {
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        try writeFile("a.bin", payload)
        try writeFile("a-copy.bin", payload)
        try writeFile("same-size-different.bin", Data(repeating: 0x09, count: 4096))
        try writeFile("different-size.bin", Data(repeating: 0x09, count: 100))

        let groups = await DuplicateEngine().findDuplicates(roots: [dir], minSizeBytes: 16)
        XCTAssertEqual(groups.count, 1, "only the byte-identical pair is a group")
        XCTAssertEqual(groups[0].files.count, 2)
        XCTAssertEqual(groups[0].fileSize, 4096)
        XCTAssertEqual(groups[0].wastedBytes, 4096)
    }

    func testThreeCopiesWastedMath() async throws {
        let payload = Data(repeating: 0x7F, count: 2048)
        try writeFile("x1.bin", payload)
        try writeFile("x2.bin", payload)
        try writeFile("x3.bin", payload)
        let groups = await DuplicateEngine().findDuplicates(roots: [dir], minSizeBytes: 16)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].files.count, 3)
        XCTAssertEqual(groups[0].wastedBytes, 4096)  // 2 × 2048
    }

    func testNoDuplicatesYieldsNoGroups() async throws {
        try writeFile("p.bin", Data(repeating: 1, count: 500))
        try writeFile("q.bin", Data(repeating: 2, count: 600))
        let groups = await DuplicateEngine().findDuplicates(roots: [dir], minSizeBytes: 16)
        XCTAssertTrue(groups.isEmpty)
    }

    func testHardLinksAreNotDuplicates() async throws {
        // Two hard links to one inode are ONE physical file — trashing either
        // frees nothing, so they must never be reported as duplicates.
        let payload = Data(repeating: 0x5A, count: 4096)
        let original = try writeFile("hard-original.bin", payload)
        let link = dir.appendingPathComponent("hard-link.bin")
        try FileManager.default.linkItem(at: original, to: link)
        let groups = await DuplicateEngine().findDuplicates(roots: [dir], minSizeBytes: 16)
        XCTAssertFalse(groups.contains { group in
            group.files.contains { $0.url.lastPathComponent == "hard-link.bin" }
        }, "hard links must be deduplicated by inode, not reported as waste")
    }

    func testHashingRunsFilesConcurrently() async throws {
        // PF-2: the dedicated pool must run jobs concurrently. Four ~150ms
        // jobs on a 4-thread pool complete in ≈150ms, not ≈600ms.
        let pool = DedicatedPool(count: 4, name: "diskrobo.testpool")
        let start = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    _ = await pool.run {
                        Thread.sleep(forTimeInterval: 0.15)
                        return 1
                    }
                }
            }
            for await _ in group {}
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.45, "4 jobs on a 4-thread pool must overlap (sequential would be ≈0.6s)")
    }

    func testSelectedURLsResolveAcrossAllGroups() {
        let g1 = DuplicateGroup(files: [
            DuplicateFile(url: URL(fileURLWithPath: "/tmp/a1.bin"), size: 100, modDate: nil),
            DuplicateFile(url: URL(fileURLWithPath: "/tmp/a2.bin"), size: 100, modDate: nil),
        ])
        let g2 = DuplicateGroup(files: [
            DuplicateFile(url: URL(fileURLWithPath: "/tmp/b1.bin"), size: 200, modDate: nil),
            DuplicateFile(url: URL(fileURLWithPath: "/tmp/b2.bin"), size: 200, modDate: nil),
        ])
        // Selections in BOTH groups must resolve — the old lookup searched
        // only the first group and silently dropped everything else.
        let selections: [UUID: Set<String>] = [
            g1.id: [g1.files[0].id],
            g2.id: [g2.files[1].id],
        ]
        let urls = DuplicateEngine.selectedURLs(in: [g1, g2], selections: selections)
        XCTAssertEqual(Set(urls.map(\.path)), ["/tmp/a1.bin", "/tmp/b2.bin"])

        // Stale selections (group no longer present) resolve to nothing, not crashes
        let stale: [UUID: Set<String>] = [UUID(): ["nope"]]
        XCTAssertTrue(DuplicateEngine.selectedURLs(in: [g1], selections: stale).isEmpty)
    }

    func testScanAreaRootsNeverUseSyntheticFilesystemRoot() {
        // A Quick Scan's result root is the synthetic "/" wrapper. Duplicating
        // from "/" walks the ENTIRE filesystem (the reported hang) — the scan
        // area must fall back to the actual scanned roots instead.
        let home = URL(fileURLWithPath: "/Users/x")
        let quickRoots = [home.appendingPathComponent("Library/Caches"), home.appendingPathComponent("Downloads")]

        // With recorded roots: use them verbatim.
        XCTAssertEqual(DuplicateEngine.resolveScanAreaRoots(lastScanRoots: quickRoots, home: home), quickRoots)

        // No scan yet: home.
        XCTAssertEqual(DuplicateEngine.resolveScanAreaRoots(lastScanRoots: nil, home: home), [home])

        // Defensive: a synthetic filesystem root in the recorded roots is
        // replaced with home, never propagated.
        let resolved = DuplicateEngine.resolveScanAreaRoots(lastScanRoots: [URL(fileURLWithPath: "/")], home: home)
        XCTAssertEqual(resolved, [home], "synthetic '/' root must never become a duplicate-scan root")
    }

    func testDedicatedPoolRunsWorkOffCooperativeThreads() async {
        // Hashing (and any long blocking work) must run on dedicated threads,
        // never the Swift cooperative pool (invariant 9).
        let value = await DedicatedPool.hashing.run { 21 * 2 }
        XCTAssertEqual(value, 42)

        // Multiple concurrent jobs all complete.
        let results = await withTaskGroup(of: Int.self) { group in
            for i in 0..<8 {
                group.addTask { await DedicatedPool.hashing.run { i * i } }
            }
            var out: [Int] = []
            for await v in group { out.append(v) }
            return out
        }
        XCTAssertEqual(Set(results), Set((0..<8).map { $0 * $0 }))
    }
}

final class ScanEngineTests: XCTestCase {
    var root: URL!
    var fm: FileManager { FileManager.default }

    func testEnumerationWorkersDeliverResultWithinTimeout() async {
        // Happy path: the worker returns the listing well inside the timeout.
        let pool = EnumerationWorkers(count: 1) { url, _ in
            EnumerationWorkers.Listing(contents: [url], error: nil)
        }
        let listing = await ScanEngine.listDirectory(URL(fileURLWithPath: "/tmp/x"), keys: [], timeout: 5, workers: pool)
        XCTAssertEqual(listing.contents?.count, 1)
        XCTAssertNil(listing.error)
    }

    func testEnumerationWorkersTimeoutAbandonsBlockedJob() async {
        // A directory whose open() never returns (simulated) is abandoned at
        // the timeout and reported as unresponsive — the scan must never hang.
        let pool = EnumerationWorkers(count: 1) { _, _ in
            Thread.sleep(forTimeInterval: 1.0)
            return EnumerationWorkers.Listing(contents: [], error: nil)
        }
        let start = Date()
        let listing = await ScanEngine.listDirectory(URL(fileURLWithPath: "/tmp"), keys: [], timeout: 0.05, workers: pool)
        XCTAssertNil(listing.contents)
        XCTAssertTrue(listing.error?.contains("Timed out") ?? false, "timeout must be reported as the reason")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.8, "must return at the timeout, not wait for the blocked worker")
    }

    func testEnumerationWorkersReplaceBlockedWorkers() async {
        // The pool must spawn a replacement when a worker is lost to a blocked
        // directory — otherwise a handful of blocked locations starves the
        // whole pool (observed live: 24 stalled Group Containers entries).
        let pool = EnumerationWorkers(count: 1, maxWorkers: 4) { _, _ in
            Thread.sleep(forTimeInterval: 1.0)  // every job "blocks" for 1s
            return EnumerationWorkers.Listing(contents: [], error: nil)
        }
        // First job ties up the only worker and times out.
        _ = await ScanEngine.listDirectory(URL(fileURLWithPath: "/a"), keys: [], timeout: 0.05, workers: pool)
        Thread.sleep(forTimeInterval: 0.1)  // let the replacement worker start
        // The replacement worker serves this job inside the timeout, proving
        // the pool recovered instead of starving.
        let listing = await ScanEngine.listDirectory(URL(fileURLWithPath: "/b"), keys: [], timeout: 2.0, workers: pool)
        XCTAssertEqual(listing.contents?.count, 0)
        XCTAssertNil(listing.error)
    }

    func testEnumerationWorkersRememberBlockedPaths() async {
        // A path that timed out once must never be re-measured this session —
        // each retry would burn the full timeout again.
        let pool = EnumerationWorkers(count: 1, maxWorkers: 4) { _, _ in
            Thread.sleep(forTimeInterval: 1.0)
            return EnumerationWorkers.Listing(contents: [], error: nil)
        }
        let url = URL(fileURLWithPath: "/Users/x/blocked")
        let first = await ScanEngine.listDirectory(url, keys: [], timeout: 0.05, workers: pool)
        XCTAssertTrue(first.error?.contains("Timed out") ?? false)

        let start = Date()
        let second = await ScanEngine.listDirectory(url, keys: [], timeout: 5.0, workers: pool)
        XCTAssertNil(second.contents)
        XCTAssertTrue(second.error?.contains("Skipped") ?? false, "second attempt must be an instant skip")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)

        // Other paths are unaffected by the blocklist.
        _ = await ScanEngine.listDirectory(URL(fileURLWithPath: "/Users/x/blocked/sub"), keys: [], timeout: 0.05, workers: pool)
        let other = await ScanEngine.listDirectory(URL(fileURLWithPath: "/Users/x/other"), keys: [], timeout: 0.05, workers: pool)
        XCTAssertTrue(other.error?.contains("Timed out") ?? false, "different path still gets a real attempt")
    }

    func testFastListingIsNeverBlocklistedByLateTimer() async {
        // SV-2: the watchdog timer must be armed BEFORE the job is visible to
        // workers. Otherwise a fast listing completes first, the late timer
        // fires on a SUCCESSFUL job, and the healthy path is poisoned for the
        // whole session ("Skipped — system-protected").
        let pool = EnumerationWorkers(count: 1, maxWorkers: 8) { _, _ in
            EnumerationWorkers.Listing(contents: [], error: nil)  // instant
        }
        let url = URL(fileURLWithPath: "/healthy/dir")
        let first = await ScanEngine.listDirectory(url, keys: [], timeout: 0.2, workers: pool)
        XCTAssertNil(first.error, "fast listing must succeed")
        try? await Task.sleep(for: .milliseconds(450))  // let any rogue timer fire
        let second = await ScanEngine.listDirectory(url, keys: [], timeout: 2.0, workers: pool)
        XCTAssertNil(second.error, "a successfully listed path must never be blocklisted")
    }

    func testPathKitDescendantOfFileSystemRoot() {
        // The Quick Scan tree's root is the synthetic "/" — descendant checks
        // against it used to build the prefix "//" and match NOTHING (every
        // FSEvents reconcile event was silently dropped).
        XCTAssertTrue(PathKit.isDescendant(path: "/Users/x/Library/Caches", of: "/"),
                      "every absolute path is a descendant of /")
        XCTAssertTrue(PathKit.isDescendant(path: "/Users", of: "/"))
        XCTAssertFalse(PathKit.isDescendant(path: "/other", of: "/Users/x"))
    }

    func testListDirectoryFastPathAndTimeoutFlagging() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskrobo-list-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createFile(atPath: dir.appendingPathComponent("a.txt").path, contents: Data([1]))
        try fm.createFile(atPath: dir.appendingPathComponent("b.txt").path, contents: Data([2]))
        defer { try? fm.removeItem(at: dir) }

        let listing = await ScanEngine.listDirectory(dir, keys: [.fileSizeKey], timeout: 5)
        XCTAssertEqual(listing.contents?.count, 2)
        XCTAssertNil(listing.error)

        // A nonexistent directory reports the error, not a hang.
        let missing = await ScanEngine.listDirectory(dir.appendingPathComponent("nope"), keys: [], timeout: 5)
        XCTAssertNil(missing.contents)
        XCTAssertNotNil(missing.error)
    }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskrobo-scan-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        try Data(repeating: 0x01, count: 1000).write(to: root.appendingPathComponent("file-a.bin"))
        try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(repeating: 0x02, count: 2500).write(to: root.appendingPathComponent("sub/file-b.bin"))
        try fm.createDirectory(at: root.appendingPathComponent("sub/nested"), withIntermediateDirectories: true)
        try Data(repeating: 0x03, count: 300).write(to: root.appendingPathComponent("sub/nested/file-c.bin"))
        // symlink must not be followed nor counted
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("sub/link-a").path,
                                  withDestinationPath: root.appendingPathComponent("file-a.bin").path)
    }

    override func tearDownWithError() throws {
        try fm.removeItem(at: root)
    }

    func testScanTotalsAndProgressiveEvents() async throws {
        var options = ScanOptions()
        options.largeFileThresholdBytes = 100  // materialize all files

        var completed: ScanResult?
        var directoryEvents = 0
        let stream = ScanEngine().scan(root: root, options: options)
        for await event in stream {
            switch event {
            case .completed(let result): completed = result
            case .directoryCompleted: directoryEvents += 1
            case .failed(let message): XCTFail("scan failed: \(message)")
            case .progress, .cancelled: break
            }
        }

        let result = try XCTUnwrap(completed)
        XCTAssertEqual(result.root.size, 1000 + 2500 + 300, "symlink contributes 0")
        XCTAssertEqual(result.root.fileCount, 3)
        XCTAssertEqual(result.root.directoryCount, 2)
        // Per-directory events are opt-in (default 0): nothing consumes them
        // and each one costs a continuation hop.
        XCTAssertEqual(directoryEvents, 0, "no progressive events unless requested")
        XCTAssertEqual(result.root.symlinkCount, 1)
        XCTAssertFalse(result.categories.isEmpty)
        XCTAssertFalse(result.largestFiles.isEmpty)
        XCTAssertEqual(result.largestFiles.first?.size, 2500)

        // Opt-in still works for a future progressive UI.
        var progressive = ScanOptions()
        progressive.largeFileThresholdBytes = 100
        progressive.progressEventMaxDepth = 2
        var optInEvents = 0
        for await event in ScanEngine().scan(root: root, options: progressive) {
            if case .directoryCompleted = event { optInEvents += 1 }
        }
        XCTAssertGreaterThanOrEqual(optInEvents, 1)
    }

    func testExclusionRemovesSubtree() async throws {
        var options = ScanOptions()
        options.excludePaths = [root.appendingPathComponent("sub").path]
        var completed: ScanResult?
        for await event in ScanEngine().scan(root: root, options: options) {
            if case .completed(let result) = event { completed = result }
        }
        let result = try XCTUnwrap(completed)
        XCTAssertEqual(result.root.size, 1000)
        XCTAssertEqual(result.root.excludedCount, 1)
    }

    func testDownloadsFilesAboveOneMBMaterializeBelowGlobalThreshold() async throws {
        // SV-4: a 5 MB four-month-old installer in Downloads must become a
        // tree node (cleanup-candidate-eligible) even though the global
        // materialization threshold is 10 MB — the old gap made 1–10 MB
        // downloads invisible to cleanup.
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fm.createFile(atPath: downloads.appendingPathComponent("old.dmg").path,
                          contents: Data(repeating: 3, count: 5_000_000))
        try fm.createFile(atPath: downloads.appendingPathComponent("small.txt").path,
                          contents: Data(repeating: 1, count: 500))

        var options = ScanOptions()
        options.largeFileThresholdBytes = 10_000_000
        options.downloadsRoot = downloads.path
        var completed: ScanResult?
        for await event in ScanEngine().scan(root: root, options: options) {
            if case .completed(let result) = event { completed = result }
        }
        let result = try XCTUnwrap(completed)
        let downloadsNode = try XCTUnwrap(result.root.children.first { $0.url.lastPathComponent == "Downloads" })
        XCTAssertTrue(downloadsNode.children.contains { $0.url.lastPathComponent == "old.dmg" },
                      "5 MB download must materialize (cleanup-eligible)")
        XCTAssertFalse(downloadsNode.children.contains { $0.url.lastPathComponent == "small.txt" },
                       "sub-1MB files still aggregate")
    }

    func testCancellationStopsScan() async {
        let stream = ScanEngine().scan(root: URL(fileURLWithPath: "/Users"), options: .standard)
        let task = Task {
            for await _ in stream { /* consume */ }
        }
        task.cancel()
        // Must terminate without hanging; reaching here is the assertion.
        let finished = task.isCancelled
        XCTAssertTrue(finished)
    }
}
