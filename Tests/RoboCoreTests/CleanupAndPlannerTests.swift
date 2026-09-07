import XCTest
@testable import RoboCore

final class CleanupEngineTests: XCTestCase {
    var tempHome: URL!
    var engine: CleanupEngine!

    override func setUp() {
        tempHome = URL(fileURLWithPath: "/Users/fake-home-\(UUID().uuidString.prefix(6))")
        engine = CleanupEngine(home: tempHome)
    }

    func node(_ relativePath: String, kind: NodeKind = .directory, size: Int64 = 0, modDate: Date? = nil) -> StorageNode {
        StorageNode(url: tempHome.appendingPathComponent(relativePath), kind: kind, size: size, modDate: modDate)
    }

    func testCacheAndDownloadRules() async {
        let oldInstaller = node("Downloads/Xcode.dmg", kind: .file, size: 2_000_000_000,
                                modDate: Date(timeIntervalSinceNow: -45 * 86_400))
        let newInstaller = node("Downloads/Fresh.dmg", kind: .file, size: 1_000_000_000, modDate: Date())
        let oldZip = node("Downloads/backup.zip", kind: .file, size: 100_000_000,
                          modDate: Date(timeIntervalSinceNow: -100 * 86_400))
        let oldFile = node("Downloads/notes.pdf", kind: .file, size: 5_000_000,
                           modDate: Date(timeIntervalSinceNow: -120 * 86_400))
        let recentFile = node("Downloads/recent.txt", kind: .file, size: 5_000_000,
                              modDate: Date(timeIntervalSinceNow: -2 * 86_400))
        let downloads = StorageNode(url: tempHome.appendingPathComponent("Downloads"))
        [oldInstaller, newInstaller, oldZip, oldFile, recentFile].forEach { downloads.adopt($0) }

        let bigCache = node("Library/Caches/BigApp", size: 50_000_000)
        let tinyCache = node("Library/Caches/TinyApp", size: 500)  // below 1 MB floor
        let caches = StorageNode(url: tempHome.appendingPathComponent("Library/Caches"))
        caches.adopt(bigCache)
        caches.adopt(tinyCache)
        let library = StorageNode(url: tempHome.appendingPathComponent("Library"))
        library.adopt(caches)

        let trashItem = node(".Trash/junk", size: 3_000_000)
        let trash = StorageNode(url: tempHome.appendingPathComponent(".Trash"))
        trash.adopt(trashItem)

        let root = StorageNode(url: tempHome)
        root.adopt(library)
        root.adopt(downloads)
        root.adopt(trash)

        let candidates = await engine.findCandidates(root: root)

        let kinds = Set(candidates.map(\.kind))
        XCTAssertTrue(kinds.contains(.cache), "cache candidate expected")
        XCTAssertTrue(kinds.contains(.oldInstaller))
        XCTAssertTrue(kinds.contains(.oldArchive))
        XCTAssertTrue(kinds.contains(.oldDownload))
        // Trash contents must NOT become cleanup candidates: Disk Robo never empties
        // the Trash, so trashing an already-trashed item frees nothing while the
        // executor would report it as recovered. (Enforced structurally: no
        // .trash kind exists anymore — this guards against any rule re-adding it.)
        XCTAssertFalse(candidates.contains { $0.url.path.contains("/.Trash") },
                       "Trash contents are advisory only (Radar), never cleanup candidates")

        XCTAssertFalse(candidates.contains { $0.url.lastPathComponent == "Fresh.dmg" }, "new installer must be skipped")
        XCTAssertFalse(candidates.contains { $0.url.lastPathComponent == "TinyApp" }, "sub-1MB candidate must be skipped")
        XCTAssertFalse(candidates.contains { $0.url.lastPathComponent == "recent.txt" })

        let cacheCandidate = candidates.first { $0.kind == .cache }!
        XCTAssertEqual(cacheCandidate.risk, .green)
        XCTAssertEqual(cacheCandidate.confidence, .veryHigh)
        XCTAssertTrue(cacheCandidate.canReturn)
        XCTAssertFalse(cacheCandidate.what.isEmpty)
        XCTAssertFalse(cacheCandidate.impact.isEmpty)

        let installer = candidates.first { $0.kind == .oldInstaller }!
        XCTAssertEqual(installer.risk, .yellow)
        XCTAssertEqual(installer.category, .installers)
    }

    func testExplanationsPresent() async {
        let derived = node("Library/Developer/Xcode/DerivedData/Proj-xyz", size: 4_000_000_000)
        let dd = StorageNode(url: tempHome.appendingPathComponent("Library/Developer/Xcode/DerivedData"))
        dd.adopt(derived)
        let xcode = StorageNode(url: tempHome.appendingPathComponent("Library/Developer/Xcode"))
        xcode.adopt(dd)
        let dev = StorageNode(url: tempHome.appendingPathComponent("Library/Developer"))
        dev.adopt(xcode)
        let library = StorageNode(url: tempHome.appendingPathComponent("Library"))
        library.adopt(dev)
        let root = StorageNode(url: tempHome)
        root.adopt(library)

        let candidates = await engine.findCandidates(root: root)
        XCTAssertEqual(candidates.count, 1)
        let candidate = candidates[0]
        XCTAssertEqual(candidate.kind, .derivedData)
        XCTAssertEqual(candidate.risk, .green)
        XCTAssertTrue(candidate.impact.contains("slower"), "DerivedData impact must warn about slower rebuilds")
        XCTAssertTrue(candidate.what.contains("Xcode"))
    }
}

final class PlannerTests: XCTestCase {
    func candidate(_ name: String, _ size: Int64, _ risk: RiskLevel) -> CleanupCandidate {
        CleanupCandidate(
            url: URL(fileURLWithPath: "/Users/x/tmp/\(name)"),
            name: name, sizeBytes: size, category: .caches, kind: .cache,
            risk: risk, confidence: .high,
            what: "w", why: "y", impact: "i", canReturn: true, fingerprint: nil
        )
    }

    func testQuickCleanContainsOnlyGreen() {
        let candidates = [candidate("a", 1_000, .green), candidate("b", 2_000, .yellow), candidate("c", 3_000, .orange)]
        let plan = RoboPlanner.buildPlan(from: candidates, mode: .quick)
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items[0].name, "a")
        XCTAssertEqual(plan.expectedRecoveryBytes, 1_000)
    }

    func testSmartExcludesOrange() {
        let candidates = [candidate("a", 1_000, .green), candidate("b", 2_000, .yellow), candidate("c", 3_000, .orange)]
        let plan = RoboPlanner.buildPlan(from: candidates, mode: .smart)
        XCTAssertEqual(plan.items.count, 2)
    }

    func testTargetFillPrefersSafestFirst() {
        // 1 GB target; a 2 GB green exists but a 1 GB green is more precise; ordering must be risk-then-size
        let candidates = [
            candidate("yellow-big", 900_000_000, .yellow),
            candidate("green-small", 150_000_000, .green),
            candidate("green-mid", 400_000_000, .green),
            candidate("green-big", 1_200_000_000, .green),
        ]
        let plan = RoboPlanner.buildPlan(from: candidates, mode: .target(gigabytes: 1.0))
        // All greens are considered before any yellow
        XCTAssertTrue(plan.items.allSatisfy { $0.risk == .green })
        XCTAssertGreaterThanOrEqual(plan.expectedRecoveryBytes, 1_000_000_000)
        // Sorted by size desc within green: big(1.2G) alone reaches target
        XCTAssertEqual(plan.items.first?.name, "green-big")
    }

    func testExplanationMentionsTrash() {
        let plan = RoboPlanner.buildPlan(from: [candidate("a", 1_000, .green)], mode: .quick)
        XCTAssertTrue(plan.explanation.contains("Trash"))
    }

    func testBuildPlanExcludesUserDeselectedCandidates() {
        let candidates = [candidate("a", 1_000, .green), candidate("b", 2_000, .green), candidate("c", 3_000, .green)]
        let excluded = Set([candidates[0].id])
        let plan = RoboPlanner.buildPlan(from: candidates, mode: .quick, excluding: excluded)
        XCTAssertFalse(plan.items.contains { $0.id == candidates[0].id },
                       "deselected candidates must never reach the plan (token, preview, and executor all derive from plan.items)")
        XCTAssertEqual(plan.items.count, 2)
        XCTAssertEqual(plan.expectedRecoveryBytes, 5_000)
    }

    func testBuildPlanExcludingEmptyBehavesIdentically() {
        let candidates = [candidate("a", 1_000, .green), candidate("b", 2_000, .yellow)]
        let plain = RoboPlanner.buildPlan(from: candidates, mode: .smart)
        let withEmpty = RoboPlanner.buildPlan(from: candidates, mode: .smart, excluding: [])
        XCTAssertEqual(plain.items.map(\.id), withEmpty.items.map(\.id))
    }
}
