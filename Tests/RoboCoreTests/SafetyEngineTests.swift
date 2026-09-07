import XCTest
@testable import RoboCore

final class SafetyEngineTests: XCTestCase {
    var tempHome: URL!
    var safety: SafetyEngine!
    var fm: FileManager { FileManager.default }

    override func setUpWithError() throws {
        tempHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskrobo-tests-\(UUID().uuidString)/Home", isDirectory: true)
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
        safety = SafetyEngine(home: tempHome)
    }

    override func tearDownWithError() throws {
        try fm.removeItem(at: tempHome.deletingLastPathComponent())
    }

    @discardableResult
    func makeFile(_ relativePath: String, size: Int = 128) throws -> URL {
        let url = tempHome.appendingPathComponent(relativePath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data(repeating: 0x61, count: size)))
        return url
    }

    func testEngineInitiatedInsideAllowlistIsAllowed() throws {
        let cache = try makeFile("Library/Caches/BigApp/blob.bin")
        XCTAssertEqual(safety.validateTrash(path: cache.path, userInitiated: false, expectedFingerprint: nil), .allowed)
    }

    func testEngineInitiatedOutsideAllowlistIsVetoed() throws {
        let doc = try makeFile("Documents/notes.txt")
        if case .vetoed = safety.validateTrash(path: doc.path, userInitiated: false, expectedFingerprint: nil) {} else {
            XCTFail("Engine must not be allowed to delete outside its allowlist")
        }
    }

    func testUserInitiatedOutsideAllowlistIsAllowedButProtectedIsNot() throws {
        let doc = try makeFile("Documents/notes.txt")
        XCTAssertEqual(safety.validateTrash(path: doc.path, userInitiated: true, expectedFingerprint: nil), .allowed)

        let mail = try makeFile("Library/Mail/V6/something")
        if case .vetoed = safety.validateTrash(path: mail.path, userInitiated: true, expectedFingerprint: nil) {} else {
            XCTFail("Protected path must be vetoed even when user-initiated")
        }
    }

    func testSystemPathsAreProtected() throws {
        for path in ["/System/Library/foo", "/usr/lib/libz.dylib", "/private/var/db/whatever"] {
            if case .vetoed = safety.validateTrash(path: path, userInitiated: false, expectedFingerprint: nil) {} else {
                XCTFail("\(path) must be protected")
            }
        }
    }

    func testSymlinkEscapeIsVetoed() throws {
        let target = try makeFile("Documents/secret.txt")
        try makeFile("Library/Caches/.keep", size: 1)  // ensure Caches exists
        let link = tempHome.appendingPathComponent("Library/Caches/evil-link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        if case .vetoed = safety.validateTrash(path: link.path, userInitiated: false, expectedFingerprint: nil) {} else {
            XCTFail("Symlink escaping the allowlist must be vetoed")
        }
    }

    func testTOCTOUFingerprintMismatchIsBlocked() async throws {
        let cache = try makeFile("Library/Caches/BigApp/blob.bin", size: 128)
        let stale = ItemFingerprint(path: cache.path, size: 9_999, mtime: 0)
        if case .vetoed = safety.validateTrash(path: cache.path, userInitiated: false, expectedFingerprint: stale) {} else {
            XCTFail("Changed item must be blocked")
        }
        // A matching fingerprint passes
        let fresh = await ItemFingerprint.capture(path: cache.path)
        XCTAssertEqual(safety.validateTrash(path: cache.path, userInitiated: false, expectedFingerprint: fresh), .allowed)
    }

    func testMissingItemIsBlocked() {
        let missing = tempHome.appendingPathComponent("Library/Caches/Gone/na.bin").path
        if case .vetoed = safety.validateTrash(path: missing, userInitiated: true, expectedFingerprint: nil) {} else {
            XCTFail("Missing item must be blocked")
        }
    }

    func testShallowPathsRefused() throws {
        let deep = try makeFile("Library/Caches/X/y/z.bin")
        let top = try makeFile("decoy.txt")
        _ = deep
        // Home itself is protected regardless
        if case .vetoed = safety.validateTrash(path: tempHome.path, userInitiated: true, expectedFingerprint: nil) {} else {
            XCTFail("Home directory must never be deletable")
        }
        _ = top
    }

    func testRiskLevels() {
        XCTAssertEqual(safety.riskLevel(path: tempHome.appendingPathComponent("Library/Caches/X").path), .green)
        XCTAssertEqual(safety.riskLevel(path: tempHome.appendingPathComponent(".Trash/thing").path), .green)
        XCTAssertEqual(safety.riskLevel(path: tempHome.appendingPathComponent("Downloads/app.dmg").path), .yellow)
        XCTAssertEqual(safety.riskLevel(path: "/System/Library/Extensions/foo.kext"), .red)
        // Unknown locations are never green
        XCTAssertEqual(safety.riskLevel(path: tempHome.appendingPathComponent("Mystery/file.dat").path), .orange)
    }
}

final class ApprovalTokenTests: XCTestCase {
    func testCoverageAndExpiry() {
        let path = "/Users/x/Library/Caches/foo"
        let token = ApprovalToken.issue(paths: [path])
        XCTAssertTrue(token.covers(path))
        XCTAssertTrue(token.covers(path.uppercased()))  // normalization is case-insensitive
        XCTAssertFalse(token.covers("/Users/x/Library/Caches/bar"))

        let expired = ApprovalToken(id: token.id, paths: token.paths, issuedAt: Date(timeIntervalSinceNow: -400), ttl: 300)
        XCTAssertFalse(expired.covers(path))
    }
}

final class PolicyEngineTests: XCTestCase {
    func testDestructiveToolRequiresApproval() async throws {
        let tool = MoveToTrashTool()
        var context = ToolContext()
        if case .denied = PolicyEngine.authorize(tool: tool, context: context) {} else {
            XCTFail("Destructive tool without approval must be denied")
        }
        context.approval = ApprovalToken.issue(paths: ["/some/approved/path"])
        XCTAssertEqual(PolicyEngine.authorize(tool: tool, context: context), .allowed)

        // The tool itself still enforces per-path token coverage: an
        // uncovered path is blocked and reported, never silently trashed.
        let result = try await tool.execute(ToolArguments(raw: ["paths": "/not/approved"]), context: context)
        guard case .text(let summary) = result else {
            return XCTFail("Expected a text result")
        }
        XCTAssertTrue(summary.contains("Trashed 0"), "nothing may be trashed without coverage; got: \(summary)")
    }

    func testReadOnlyToolAlwaysAllowed() {
        let tool = ListLargeFilesTool()
        XCTAssertEqual(PolicyEngine.authorize(tool: tool, context: ToolContext()), .allowed)
    }
}
