import XCTest
@testable import RoboCore

final class TrashPruningTests: XCTestCase {
    func buildTree() -> StorageNode {
        // root/
        //   a.bin        1000   (leaf, large)
        //   sub/                (dir)
        //     b.bin      2500   (leaf, large)
        //     c.bin       300   (leaf, small → aggregated)
        let root = StorageNode(url: URL(fileURLWithPath: "/tmp/scanroot"))
        let fileA = StorageNode(url: URL(fileURLWithPath: "/tmp/scanroot/a.bin"), kind: .file, size: 1000)
        let sub = StorageNode(url: URL(fileURLWithPath: "/tmp/scanroot/sub"))
        let fileB = StorageNode(url: URL(fileURLWithPath: "/tmp/scanroot/sub/b.bin"), kind: .file, size: 2500)
        let fileC = StorageNode(url: URL(fileURLWithPath: "/tmp/scanroot/sub/c.bin"), kind: .file, size: 300)
        sub.adopt(fileB)
        sub.smallFileCount = 1
        sub.smallFileBytes = 300
        sub.size += 300
        sub.fileCount += 1
        root.adopt(fileA)
        root.adopt(sub)
        return root
    }

    func testRemoveLeafPrunesSizesAndCounts() {
        let root = buildTree()
        XCTAssertEqual(root.size, 1000 + 2500 + 300)
        XCTAssertEqual(root.fileCount, 3)

        let removed = root.removeDescendants(matching: ["/tmp/scanroot/sub/b.bin"])

        XCTAssertEqual(removed, 2500)
        XCTAssertEqual(root.size, 1300)
        XCTAssertEqual(root.fileCount, 2)
        XCTAssertFalse(root.children[1].children.contains { $0.url.lastPathComponent == "b.bin" })
    }

    func testRemoveDirectorySubtractsSubtree() {
        let root = buildTree()
        let removed = root.removeDescendants(matching: ["/tmp/scanroot/sub"])

        XCTAssertEqual(removed, 2800)
        XCTAssertEqual(root.size, 1000)
        XCTAssertEqual(root.fileCount, 1)
        XCTAssertEqual(root.directoryCount, 0)
        XCTAssertTrue(root.children.allSatisfy { $0.kind != .directory })
    }

    func testRemoveMultipleAndUnknownPaths() {
        let root = buildTree()
        let removed = root.removeDescendants(matching: [
            "/tmp/scanroot/a.bin",
            "/tmp/scanroot/sub/b.bin",
            "/does/not/exist",
        ])
        XCTAssertEqual(removed, 3500)
        XCTAssertEqual(root.size, 300)  // only the aggregated small file remains
    }

    func testCategoryTotalsRecomputeAfterPrune() {
        let root = buildTree()
        root.children[0].category = .downloads
        root.children[1].category = .caches
        root.children[1].children[0].category = .media
        root.children[1].category = .caches

        _ = root.removeDescendants(matching: ["/tmp/scanroot/sub/b.bin"])
        let totals = root.categoryTotals()

        XCTAssertEqual(totals[.downloads], 1000)
        XCTAssertEqual(totals[.caches], 300)  // smallFileBytes only; b.bin gone
        XCTAssertNil(totals[.media])
    }
}
