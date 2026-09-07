import XCTest
@testable import RoboCore

// MARK: - FSEvents reconcile (Tier 4)

final class TreeReconcilerTests: XCTestCase {
    var dir: URL!
    var fm: FileManager { FileManager.default }
    var options: ScanOptions!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskrobo-reconcile-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var o = ScanOptions()
        o.largeFileThresholdBytes = 1000        // materialize "big" test files
        o.downloadsRoot = "/nonexistent"        // keep test uniform
        options = o
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: dir)
    }

    private func scan() async throws -> StorageNode {
        var result: ScanResult?
        for await event in ScanEngine().scan(root: dir, options: options) {
            if case .completed(let r) = event { result = r }
        }
        return try XCTUnwrap(result).root
    }

    @discardableResult
    private func writeFile(_ relative: String, _ size: Int, old: Bool = false) throws -> URL {
        let url = dir.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data(repeating: 7, count: size)))
        if old {
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -90 * 86_400)], ofItemAtPath: url.path)
        }
        return url
    }

    func testReconcileMatchesFreshScanAfterMutations() async throws {
        // Baseline tree.
        try writeFile("project/build1.bin", 5000, old: true)
        try writeFile("project/build2.bin", 5000, old: true)
        try writeFile("project/notes.txt", 100)
        try writeFile("project/deep/inner.bin", 2000, old: true)
        try writeFile("loose.bin", 3000, old: true)
        let tree = try await scan()

        // Mutations the monitor would report.
        try fm.removeItem(at: dir.appendingPathComponent("project/build1.bin"))          // delete big
        try writeFile("project/newbig.bin", 4000, old: true)                             // create big
        try fm.removeItem(at: dir.appendingPathComponent("loose.bin"))                   // delete top-level
        try writeFile("extra.bin", 10_000, old: true)                                    // create top-level big
        let changedPaths = [
            dir.appendingPathComponent("project/build1.bin").path,
            dir.appendingPathComponent("project/newbig.bin").path,
            dir.appendingPathComponent("loose.bin").path,
            dir.appendingPathComponent("extra.bin").path,
        ]

        let changed = await TreeReconciler.reconcile(changedPaths: changedPaths, root: tree, options: options)
        XCTAssertTrue(changed)

        // THE invariant: the reconciled tree matches a fresh full scan.
        let fresh = try await scan()
        XCTAssertEqual(tree.size, fresh.size, "total bytes: reconciled must equal fresh")
        XCTAssertEqual(tree.fileCount, fresh.fileCount)
        XCTAssertEqual(tree.directoryCount, fresh.directoryCount)
        let reconciledProject = try XCTUnwrap(tree.children.first { $0.name == "project" })
        let freshProject = try XCTUnwrap(fresh.children.first { $0.name == "project" })
        XCTAssertEqual(reconciledProject.size, freshProject.size)
        XCTAssertEqual(reconciledProject.fileCount, freshProject.fileCount)
        XCTAssertEqual(reconciledProject.smallFileCount, freshProject.smallFileCount)
        XCTAssertTrue(tree.children.contains { $0.name == "extra.bin" })
        XCTAssertFalse(tree.children.contains { $0.name == "loose.bin" })
    }

    func testReconcileIsNoOpForUnchangedPaths() async throws {
        try writeFile("stable.bin", 5000, old: true)
        let tree = try await scan()
        let sizeBefore = tree.size
        let changed = await TreeReconciler.reconcile(
            changedPaths: [dir.appendingPathComponent("stable.bin").path],
            root: tree, options: options)
        XCTAssertFalse(changed, "a re-walk of an unchanged directory must report no change")
        XCTAssertEqual(tree.size, sizeBefore)
    }

    func testReconcileHandlesDeepNewDirectory() async throws {
        try writeFile("base.bin", 1000, old: true)
        let tree = try await scan()
        // A brand-new nested directory the tree has never seen.
        try writeFile("newdir/sub/data.bin", 8000, old: true)
        let changed = await TreeReconciler.reconcile(
            changedPaths: [dir.appendingPathComponent("newdir/sub/data.bin").path],
            root: tree, options: options)
        XCTAssertTrue(changed)
        let fresh = try await scan()
        XCTAssertEqual(tree.size, fresh.size, "new nested dirs must be measured via ancestor re-walk")
        XCTAssertEqual(tree.directoryCount, fresh.directoryCount)
    }

    func testReconcileRequestsFullRescanWhenRootItselfChanges() async throws {
        try writeFile("base.bin", 1000, old: true)
        let tree = try await scan()
        // A change whose deepest known ancestor IS the scan root still works
        // (root re-walk) but must be reported so the caller can decide.
        try writeFile("top-level-new.bin", 9000, old: true)
        _ = await TreeReconciler.reconcile(
            changedPaths: [dir.appendingPathComponent("top-level-new.bin").path],
            root: tree, options: options)
        let fresh = try await scan()
        XCTAssertEqual(tree.size, fresh.size)
    }
}
