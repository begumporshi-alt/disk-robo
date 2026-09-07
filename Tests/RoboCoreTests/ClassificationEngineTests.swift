import XCTest
@testable import RoboCore

final class ClassificationEngineTests: XCTestCase {
    let engine = ClassificationEngine(home: URL(fileURLWithPath: "/Users/test"))

    func testBrowserCacheDetection() {
        XCTAssertEqual(engine.classify(path: "/Users/test/Library/Caches/com.google.Chrome/Default/Cache", kind: .directory), .browser)
        XCTAssertEqual(engine.classify(path: "/Users/test/Library/Caches/Firefox/Profiles", kind: .directory), .browser)
    }

    func testGenericCacheDetection() {
        XCTAssertEqual(engine.classify(path: "/Users/test/Library/Caches/com.foo.Bar", kind: .directory), .caches)
        XCTAssertEqual(engine.classify(path: "/Library/Caches/some.app", kind: .directory), .caches)
    }

    func testDownloadsFileOverrides() {
        XCTAssertEqual(engine.classify(path: "/Users/test/Downloads/Xcode.dmg", kind: .file), .installers)
        XCTAssertEqual(engine.classify(path: "/Users/test/Downloads/backup.zip", kind: .file), .archives)
        XCTAssertEqual(engine.classify(path: "/Users/test/Downloads/photo.jpg", kind: .file), .downloads)
        XCTAssertEqual(engine.classify(path: "/Users/test/Downloads", kind: .directory), .downloads)
    }

    func testDeveloperDomains() {
        XCTAssertEqual(engine.classify(path: "/Users/test/Library/Developer/Xcode/DerivedData/Proj-abc", kind: .directory), .developer)
        XCTAssertEqual(engine.classify(path: "/Users/test/Projects/app/node_modules", kind: .directory), .developer)
        XCTAssertEqual(engine.classify(path: "/Users/test/.npm/_cacache", kind: .directory), .developer)
    }

    func testApplicationsAndProtected() {
        XCTAssertEqual(engine.classify(path: "/Applications/Safari.app", kind: .package), .applications)
        XCTAssertEqual(engine.classify(path: "/Users/test/Applications/Tool.app", kind: .package), .applications)
        XCTAssertEqual(engine.classify(path: "/Users/test/Library/Mail/V6", kind: .directory), .system)
        XCTAssertEqual(engine.classify(path: "/Users/test/Library/Mobile Documents/com~apple~CloudDocs", kind: .directory), .system)
        XCTAssertEqual(engine.classify(path: "/System/Library/CoreServices", kind: .directory), .system)
        XCTAssertEqual(engine.classify(path: "/Users/test/Library/Containers/com.apple.Safari/Data", kind: .directory), .system)
        XCTAssertEqual(engine.classify(path: "/Users/test/Library/Containers/com.foo.app/Data", kind: .directory), .applications)
    }

    func testTrashAndMediaAndDocuments() {
        XCTAssertEqual(engine.classify(path: "/Users/test/.Trash/oldfile", kind: .file), .trash)
        XCTAssertEqual(engine.classify(path: "/Users/test/Movies/clip.mp4", kind: .file), .media)
        XCTAssertEqual(engine.classify(path: "/Users/test/Documents/report.pdf", kind: .file), .documents)
        XCTAssertEqual(engine.classify(path: "/Random/place/archive.rar", kind: .file), .archives)
        XCTAssertEqual(engine.classify(path: "/Users/test/Library/Logs/app", kind: .directory), .logs)
    }
}
