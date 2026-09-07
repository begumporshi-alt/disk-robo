import XCTest
@testable import RoboCore

// MARK: - Child-process scanner (Tier 4)

final class ChildProcessScannerTests: XCTestCase {
    var dir: URL!
    var fm: FileManager { FileManager.default }

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskrobo-child-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // The scanner executable lives in the SPM build dir when running tests
        // from the package root; ChildProcessScanner looks there.
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: dir)
    }

    func testChildProcessScanMatchesInProcessScan() async throws {
        guard ChildProcessScanner.scannerExecutableURL() != nil else {
            throw XCTSkip("DiskRoboScanner executable not built — run swift build first")
        }

        // Fixture: nested tree with big files, small files, a symlink, a package.
        try fm.createFile(atPath: dir.appendingPathComponent("big.bin").path,
                          contents: Data(repeating: 1, count: 50_000))
        try fm.createFile(atPath: dir.appendingPathComponent("small.txt").path,
                          contents: Data(repeating: 2, count: 50))
        let sub = dir.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try fm.createFile(atPath: sub.appendingPathComponent("inner.bin").path,
                          contents: Data(repeating: 3, count: 30_000))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link.bin"),
                                  withDestinationURL: sub.appendingPathComponent("inner.bin"))

        var options = ScanOptions()
        options.largeFileThresholdBytes = 1000

        // In-process reference scan.
        var reference: ScanResult?
        for await event in ScanEngine().scan(root: dir, options: options) {
            if case .completed(let r) = event { reference = r }
        }
        let expected = try XCTUnwrap(reference)

        // Child-process scan.
        let request = ChildProcessScanner.Request(
            roots: [dir.path], label: "child-test",
            excludePaths: options.excludePaths,
            largeFileThresholdBytes: options.largeFileThresholdBytes)
        var child: ScanResult?
        for await event in ChildProcessScanner.scan(request: request, timeout: 60) {
            if case .completed(let r) = event { child = r }
        }
        let actual = try XCTUnwrap(child, "child process must complete the scan")

        // THE invariant: the child-built tree matches the in-process tree.
        XCTAssertEqual(actual.root.size, expected.root.size, "total bytes must match")
        XCTAssertEqual(actual.root.fileCount, expected.root.fileCount)
        XCTAssertEqual(actual.root.directoryCount, expected.root.directoryCount)
        XCTAssertEqual(actual.root.symlinkCount, expected.root.symlinkCount)
        XCTAssertEqual(actual.root.smallFileBytes, expected.root.smallFileBytes)
        XCTAssertEqual(actual.categories[.other] ?? 0, expected.categories[.other] ?? 0)
        XCTAssertFalse(actual.largestFiles.isEmpty)
        XCTAssertEqual(actual.isQuickScan, false)
    }
}
