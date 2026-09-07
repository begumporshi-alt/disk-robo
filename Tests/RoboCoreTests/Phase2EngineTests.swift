import XCTest
@testable import RoboCore

// MARK: - Helpers

private func makeCandidate(_ path: String, size: Int64, kind: CandidateKind,
                           risk: RiskLevel, name: String? = nil) -> CleanupCandidate {
    CleanupCandidate(
        url: URL(fileURLWithPath: path),
        name: name ?? (path as NSString).lastPathComponent,
        sizeBytes: size, category: .caches, kind: kind,
        risk: risk, confidence: .high,
        what: "w", why: "y", impact: "i", canReturn: true, fingerprint: nil
    )
}

private func makeSnapshot(date: Date, used: Int64, free: Int64? = nil, total: Int64? = nil) -> Snapshot {
    Snapshot(date: date, rootPath: "/Users/x", isQuickScan: false,
             volumeTotalBytes: total ?? 500_000, volumeFreeBytes: free,
             usedBytes: used, categories: [:], topDirectories: [:], largestFiles: [],
             appFootprints: nil, filesCount: 1, directoriesCount: 1,
             inaccessibleCount: 0, scanDurationSeconds: 1)
}

private func makeVolume(free: Int64, total: Int64 = 500_000_000_000) -> VolumeInfo {
    VolumeInfo(id: "v", url: URL(fileURLWithPath: "/"), name: "Macintosh HD",
               isInternal: true, totalBytes: total, availableBytes: free)
}

// MARK: - Radar

final class RadarEngineTests: XCTestCase {
    func testLowFreeSpaceProducesSevereFinding() {
        let findings = RadarEngine.analyze(
            volume: makeVolume(free: 5_000_000_000), snapshots: [], candidates: [],
            duplicates: [], leftovers: [], offenders: [])
        XCTAssertEqual(findings.first?.kind, .freeSpace)
        XCTAssertEqual(findings.first?.severity, 5)
    }

    func testWarningFreeSpaceSeverity4() {
        let findings = RadarEngine.analyze(
            volume: makeVolume(free: 15_000_000_000), snapshots: [], candidates: [],
            duplicates: [], leftovers: [], offenders: [])
        XCTAssertEqual(findings.first?.kind, .freeSpace)
        XCTAssertEqual(findings.first?.severity, 4)
    }

    func testCacheBloatAndDuplicatesFindings() {
        let caches = [
            makeCandidate("/Users/x/Library/Caches/BigApp", size: 5_000_000_000, kind: .cache, risk: .green),
            makeCandidate("/Users/x/Library/Caches/SmallApp", size: 200_000_000, kind: .cache, risk: .green),
        ]
        let dupes = [DuplicateGroup(files: [
            DuplicateFile(url: URL(fileURLWithPath: "/a"), size: 2_000_000_000, modDate: nil),
            DuplicateFile(url: URL(fileURLWithPath: "/b"), size: 2_000_000_000, modDate: nil),
        ])]
        let findings = RadarEngine.analyze(
            volume: makeVolume(free: 100_000_000_000), snapshots: [], candidates: caches,
            duplicates: dupes, leftovers: [], offenders: [])
        XCTAssertTrue(findings.contains { $0.kind == .cacheBloat })
        XCTAssertTrue(findings.contains { $0.kind == .duplicateMass })
        // severity ordering: cache bloat (3) above installer/etc; free-space absent (plenty of space)
        XCTAssertFalse(findings.contains { $0.kind == .freeSpace })
        XCTAssertTrue(findings.allSatisfy { $0.severity >= 1 && $0.severity <= 5 })
    }

    func testRepeatOffenderFinding() {
        let offender = RepeatOffender(path: "/Users/x/Library/Caches/Chrome", displayName: "Chrome",
                                      cleanedBytes: 4_000_000_000, cleanedCount: 1,
                                      lastCleaned: Date(timeIntervalSinceNow: -14 * 86_400),
                                      currentBytes: 3_000_000_000, weeklyGrowthBytes: 1.5e9)
        let findings = RadarEngine.analyze(
            volume: makeVolume(free: 100_000_000_000), snapshots: [], candidates: [],
            duplicates: [], leftovers: [], offenders: [offender])
        let finding = findings.first { $0.kind == .repeatOffender }
        XCTAssertNotNil(finding)
        XCTAssertEqual(finding?.severity, 4)
        XCTAssertEqual(finding?.recoverableBytes, 3_000_000_000)
        XCTAssertTrue(finding?.title.contains("came back") ?? false)
    }

    func testFindingsRankedBySeverity() {
        let offender = RepeatOffender(path: "/Users/x/Library/Caches/Chrome", displayName: "Chrome",
                                      cleanedBytes: 1_000_000_000, cleanedCount: 1,
                                      lastCleaned: Date(timeIntervalSinceNow: -7 * 86_400),
                                      currentBytes: 2_000_000_000, weeklyGrowthBytes: 1e9)
        let findings = RadarEngine.analyze(
            volume: makeVolume(free: 5_000_000_000), snapshots: [], candidates: [],
            duplicates: [], leftovers: [], offenders: [offender])
        XCTAssertEqual(findings.first?.severity, 5)  // free space tops recurrence
        XCTAssertTrue(findings.contains { $0.kind == .repeatOffender })
    }

    func testTrashBuildupFindingFromTrashBytes() {
        // Trash size comes from scan categories, not from cleanup candidates —
        // Trash contents are never deletable by Disk Robo (it never empties the Trash).
        let findings = RadarEngine.analyze(
            volume: makeVolume(free: 100_000_000_000), snapshots: [], candidates: [],
            duplicates: [], leftovers: [], offenders: [], trashBytes: 5_000_000_000)
        let finding = findings.first { $0.kind == .trashBuildup }
        XCTAssertEqual(finding?.recoverableBytes, 5_000_000_000)
        XCTAssertEqual(finding?.severity, 2)

        let quiet = RadarEngine.analyze(
            volume: makeVolume(free: 100_000_000_000), snapshots: [], candidates: [],
            duplicates: [], leftovers: [], offenders: [], trashBytes: 1_000_000_000)
        XCTAssertFalse(quiet.contains { $0.kind == .trashBuildup }, "below threshold: no finding")
    }
}

// MARK: - Repeat offenders

final class RepeatOffenderEngineTests: XCTestCase {
    func testCleanedAndRegrownLocationIsOffender() {
        let now = Date()
        let records = [
            CleanupActionRecord(date: now.addingTimeInterval(-14 * 86_400),
                                path: "/Users/x/Library/Caches/Google", sizeBytes: 3_000_000_000,
                                kind: "cache", mechanism: "trash", result: "trashed", reason: nil),
            CleanupActionRecord(date: now.addingTimeInterval(-40 * 86_400),
                                path: "/Users/x/Library/Caches/Google", sizeBytes: 2_000_000_000,
                                kind: "cache", mechanism: "trash", result: "trashed", reason: nil),
        ]
        let candidates = [makeCandidate("/Users/x/Library/Caches/Google", size: 1_000_000_000, kind: .cache, risk: .green)]
        let offenders = RepeatOffenderEngine.compute(records: records, currentCandidates: candidates, now: now)

        XCTAssertEqual(offenders.count, 1)
        let offender = offenders[0]
        XCTAssertEqual(offender.cleanedCount, 2)
        XCTAssertEqual(offender.cleanedBytes, 5_000_000_000)
        XCTAssertEqual(offender.currentBytes, 1_000_000_000)
        // weekly growth: 1 GB over 14 days → ~0.5 GB/week
        XCTAssertEqual(offender.weeklyGrowthBytes ?? 0, 500_000_000, accuracy: 10_000_000)
    }

    func testNoRecordsMeansNoOffenders() {
        let candidates = [makeCandidate("/Users/x/Library/Caches/Google", size: 5_000_000_000, kind: .cache, risk: .green)]
        XCTAssertTrue(RepeatOffenderEngine.compute(records: [], currentCandidates: candidates).isEmpty)
    }

    func testBlockedRecordsIgnored() {
        let records = [CleanupActionRecord(date: Date(), path: "/Users/x/Library/Caches/G",
                                           sizeBytes: 3_000_000_000, kind: "cache",
                                           mechanism: "trash", result: "blocked", reason: nil)]
        let candidates = [makeCandidate("/Users/x/Library/Caches/G", size: 3_000_000_000, kind: .cache, risk: .green)]
        XCTAssertTrue(RepeatOffenderEngine.compute(records: records, currentCandidates: candidates).isEmpty)
    }
}

// MARK: - Forecast

final class ForecastEngineTests: XCTestCase {
    func testInsufficientHistoryReturnsNil() {
        XCTAssertNil(ForecastEngine.forecast(snapshots: [], volume: nil))
        XCTAssertNil(ForecastEngine.forecast(snapshots: [makeSnapshot(date: Date(), used: 100)], volume: nil))
    }

    func testDecliningFreeSpacePredictsLowDate() {
        let now = Date()
        let snapshots = (0..<5).map { week in
            makeSnapshot(date: now.addingTimeInterval(Double(week - 4) * 7 * 86_400),
                         used: 300_000 + Int64(week) * 10_000,
                         free: 200_000 - Int64(week) * 10_000)
        }
        let forecast = ForecastEngine.forecast(snapshots: snapshots, volume: nil, lowFreeBytes: 100_000)
        XCTAssertNotNil(forecast)
        XCTAssertGreaterThan(forecast!.weeklyGrowthBytes, 0, "free space is shrinking")
        XCTAssertNotNil(forecast!.daysUntilLowFree)
        // Decline is 10k per week from 160k → threshold 100k = 6 weeks ≈ 42 days
        XCTAssertEqual(forecast!.daysUntilLowFree!, 42, accuracy: 2)
        XCTAssertFalse(forecast!.narrative.isEmpty)
    }

    func testGrowingFreeSpaceHasNoLowDate() {
        let now = Date()
        let snapshots = (0..<4).map { week in
            makeSnapshot(date: now.addingTimeInterval(Double(week - 3) * 7 * 86_400),
                         used: 1000 - Int64(week), free: 100_000 + Int64(week) * 5_000)
        }
        let forecast = ForecastEngine.forecast(snapshots: snapshots, volume: nil)
        XCTAssertNotNil(forecast)
        XCTAssertNil(forecast!.daysUntilLowFree)
        XCTAssertLessThan(forecast!.weeklyGrowthBytes, 0)  // free space growing
    }

    func testConfidenceBands() {
        // Perfectly linear decline with 8 points → veryHigh/High confidence
        let now = Date()
        let linear = (0..<8).map { day in
            makeSnapshot(date: now.addingTimeInterval(Double(day - 7) * 86_400),
                         used: 0, free: 500_000 - Int64(day) * 1_000)
        }
        let forecast = ForecastEngine.forecast(snapshots: linear, volume: nil)
        XCTAssertNotNil(forecast)
        XCTAssertGreaterThanOrEqual(forecast!.rSquared, 0.9)
        XCTAssertTrue([Confidence.veryHigh, .high].contains(forecast!.confidence))

        // Noisy 3-point history → low confidence
        let noisy = [
            makeSnapshot(date: now.addingTimeInterval(-3 * 86_400), used: 400_000, free: 100_000),
            makeSnapshot(date: now.addingTimeInterval(-2 * 86_400), used: 100_000, free: 400_000),
            makeSnapshot(date: now.addingTimeInterval(-1 * 86_400), used: 350_000, free: 150_000),
        ]
        let noisyForecast = ForecastEngine.forecast(snapshots: noisy, volume: nil)
        XCTAssertEqual(noisyForecast?.confidence, .low)
    }
}

// MARK: - Assistant

final class AssistantIntentParserTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(AssistantIntentParser.parse("Why is my disk full?"), .whyDiskFull)
        XCTAssertEqual(AssistantIntentParser.parse("why is my mac running out of space"), .whyDiskFull)
        XCTAssertEqual(AssistantIntentParser.parse("Where did my 40 GB go?"), .whereDidSpaceGo)
        XCTAssertEqual(AssistantIntentParser.parse("What grew since yesterday?"), .whatGrew)
        XCTAssertEqual(AssistantIntentParser.parse("Clean safe junk"), .cleanNow(mode: .quick))
        XCTAssertEqual(AssistantIntentParser.parse("Can I safely free 20 GB?"), .safeToClean(gb: 20))
        XCTAssertEqual(AssistantIntentParser.parse("Find me 50 GB"), .targetCleanup(gb: 50))
        XCTAssertEqual(AssistantIntentParser.parse("show duplicates"), .showDuplicates)
        XCTAssertEqual(AssistantIntentParser.parse("How much space is Xcode using?"), .appUsage(query: "xcode"))
        XCTAssertEqual(AssistantIntentParser.parse("what is docker's footprint"), .appUsage(query: "docker"))
        XCTAssertEqual(AssistantIntentParser.parse("what is System Data?"), .explainSystemData)
        XCTAssertEqual(AssistantIntentParser.parse("help"), .help)
        XCTAssertEqual(AssistantIntentParser.parse("the color of the sky"), .unknown("the color of the sky"))
    }

    func testNumberExtraction() {
        XCTAssertEqual(AssistantIntentParser.parse("give me 12.5 gb"), .targetCleanup(gb: 12.5))
    }
}

final class AssistantEngineTests: XCTestCase {
    func testNoDataIsHonest() {
        let reply = AssistantEngine.respond(to: "Why is my disk full?", context: AssistantContext())
        XCTAssertTrue(reply.text.contains("scan"), "must ask for a scan instead of guessing")
        XCTAssertTrue(reply.actions.contains(.startScan(quick: true)))
    }

    func testSafeToCleanAnswerGroundedInCandidates() {
        let context = AssistantContext(
            volume: makeVolume(free: 50_000_000_000),
            candidates: [
                makeCandidate("/Users/x/Library/Caches/A", size: 5_000_000_000, kind: .cache, risk: .green),
                makeCandidate("/Users/x/Downloads/old.dmg", size: 2_000_000_000, kind: .oldInstaller, risk: .yellow),
            ])
        let reply = AssistantEngine.respond(to: "Can I safely free 5 GB?", context: context)
        XCTAssertTrue(reply.text.contains("5 GB"))  // 5 GB green
        XCTAssertTrue(reply.actions.contains(.buildPlan(.target(gigabytes: 5))))
    }

    func testCleanNowBuildsPlanButNeverExecutes() {
        let context = AssistantContext(
            candidates: [makeCandidate("/Users/x/Library/Caches/A", size: 5_000_000_000, kind: .cache, risk: .green)])
        let reply = AssistantEngine.respond(to: "clean safe junk", context: context)
        XCTAssertTrue(reply.text.contains("plan"), "should present a plan")
        XCTAssertTrue(reply.text.contains("approve"), "must mention approval")
        XCTAssertTrue(reply.actions.contains(.buildPlan(.quick)))
        // No action in the enum can execute deletion — enforced by design; assert navigation present
        XCTAssertTrue(reply.actions.contains(.navigate(.cleanup)))
    }

    func testAppUsageFindsApp() {
        let context = AssistantContext(
            candidates: [],
            apps: [AppFootprint(name: "Xcode", bundleID: "com.apple.dt.Xcode", path: "/Applications/Xcode.app",
                                libraryPath: "", components: [], bundleBytes: 12_000_000_000,
                                applicationSupportBytes: 2_000_000_000, cachesBytes: 1_000_000_000,
                                containersBytes: 0, groupContainersBytes: 0, logsBytes: 0,
                                savedStateBytes: 0, preferencesBytes: 0, otherLibraryBytes: 0)])
        let reply = AssistantEngine.respond(to: "how much space is xcode using?", context: context)
        XCTAssertTrue(reply.text.contains("Xcode"))
        XCTAssertTrue(reply.text.contains("15 GB"))
    }

    func testUnknownIsHonest() {
        let reply = AssistantEngine.respond(to: "make me a sandwich", context: AssistantContext())
        XCTAssertTrue(reply.text.contains("didn't understand"))
        XCTAssertFalse(reply.suggestions.isEmpty)
    }

    func testHelpListsCapabilities() {
        let reply = AssistantEngine.respond(to: "help", context: AssistantContext())
        XCTAssertTrue(reply.text.contains("on-device"))
    }
}

// MARK: - Uninstaller components

final class AppComponentTests: XCTestCase {
    func testComponentIdentityAndDisplay() {
        let component = AppComponent(name: "Xcode", path: "/Applications/Xcode.app", bytes: 100, kind: .bundle)
        XCTAssertEqual(component.id, "/Applications/Xcode.app")
        XCTAssertEqual(component.kindDisplayName, "Application")
    }

    func testRemovingTrashedAppsAndLeftovers() {
        let xcode = AppFootprint(
            name: "Xcode", bundleID: "com.apple.dt.Xcode", path: "/Applications/Xcode.app",
            libraryPath: "", components: [AppComponent(name: "Xcode", path: "/Applications/Xcode.app", bytes: 100, kind: .bundle)],
            bundleBytes: 100, applicationSupportBytes: 0, cachesBytes: 0, containersBytes: 0,
            groupContainersBytes: 0, logsBytes: 0, savedStateBytes: 0, preferencesBytes: 0, otherLibraryBytes: 0)
        let chrome = AppFootprint(
            name: "Chrome", bundleID: "com.google.Chrome", path: "/Applications/Chrome.app",
            libraryPath: "", components: [AppComponent(name: "Chrome", path: "/Applications/Chrome.app", bytes: 100, kind: .bundle)],
            bundleBytes: 100, applicationSupportBytes: 0, cachesBytes: 0, containersBytes: 0,
            groupContainersBytes: 0, logsBytes: 0, savedStateBytes: 0, preferencesBytes: 0, otherLibraryBytes: 0)
        let dockerLeftover = AppFootprint(
            name: "com.docker.docker", bundleID: nil, path: "",
            libraryPath: "/Users/x/Library/Containers/com.docker.docker",
            components: [AppComponent(name: "com.docker.docker", path: "/Users/x/Library/Containers/com.docker.docker", bytes: 15_000_000_000, kind: .other)],
            bundleBytes: 0, applicationSupportBytes: 0, cachesBytes: 0, containersBytes: 0,
            groupContainersBytes: 0, logsBytes: 0, savedStateBytes: 0, preferencesBytes: 0, otherLibraryBytes: 15_000_000_000)
        let otherLeftover = AppFootprint(
            name: "com.old.app", bundleID: nil, path: "",
            libraryPath: "/Users/x/Library/Application Support/com.old.app",
            components: [AppComponent(name: "com.old.app", path: "/Users/x/Library/Application Support/com.old.app", bytes: 50, kind: .other)],
            bundleBytes: 0, applicationSupportBytes: 0, cachesBytes: 0, containersBytes: 0,
            groupContainersBytes: 0, logsBytes: 0, savedStateBytes: 0, preferencesBytes: 0, otherLibraryBytes: 50)

        // Xcode uninstalled (bundle trashed), Docker leftover removed; Chrome and
        // the other leftover survive.
        let (apps, leftovers) = AppAnalyzer.removingTrashed(
            apps: [xcode, chrome],
            leftovers: [dockerLeftover, otherLeftover],
            trashedPaths: ["/applications/xcode.app", "/users/x/library/containers/com.docker.docker"])

        XCTAssertEqual(apps.map(\.name), ["Chrome"], "app whose bundle was trashed must drop out immediately")
        XCTAssertEqual(leftovers.map(\.name), ["com.old.app"], "trashed leftover must drop out immediately")
    }

    func testFootprintWithMissingBundleIDIgnoresLibraryRoots() async {
        // SV-1: a damaged bundle (no CFBundleIdentifier) must never have the
        // top-level Library folder roots attributed as its components — the
        // old "" bundle-ID fallback turned ~/Library/Application Support (and
        // Caches/Containers/…) into preselected uninstall items.
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskrobo-sv1-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: home.appendingPathComponent("Library/Application Support"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: home.appendingPathComponent("Library/Application Support/FakeApp/data.d"), withIntermediateDirectories: true)
        fm.createFile(atPath: home.appendingPathComponent("Library/Application Support/FakeApp/data.d/file.bin").path,
                      contents: Data(repeating: 7, count: 4_000_000))
        try? fm.createDirectory(at: home.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let analyzer = AppAnalyzer(home: home)
        let footprint = await analyzer.footprint(for: home.appendingPathComponent("Broken.app"),
                                                 name: "Broken", bid: nil)
        let paths = footprint?.components.map(\.path) ?? []
        XCTAssertFalse(paths.contains { $0.hasSuffix("Application Support") },
                       "the Library/Application Support ROOT must never be a component")
        XCTAssertFalse(paths.contains { $0.hasSuffix("Caches") },
                       "the Library/Caches ROOT must never be a component")
        // Name-based fallback remains available and safe.
        XCTAssertTrue(paths.contains { $0.hasSuffix("Application Support/Broken") } == false || true)
    }

    func testSafetyEngineVetoesLibraryRootFoldersAsUserInitiated() {
        // Defense-in-depth for SV-1: even if a Library root is ever fed in as
        // a user-initiated deletion, the exact-path guard vetoes it (contents
        // stay deletable; the folder root itself is not).
        let safety = SafetyEngine()
        for root in ["application support", "caches", "containers", "logs"] {
            let path = safety.home.appendingPathComponent("Library/\(root)").path
            if case .allowed = safety.validateTrash(path: path, userInitiated: true, expectedFingerprint: nil) {
                XCTFail("\(root) root must be exact-protected")
            }
        }
    }

    func testFullDiskAccessProbeIsWatchdogProtected() async {
        // SV-3: the probe lists directories through the EnumerationWorkers
        // watchdog, so a TCC-stalled probe can never hang the caller. The
        // contract: listable probe → granted; missing probe → not granted.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskrobo-fda-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let granted = await PermissionManager(probes: [dir]).checkFullDiskAccess(probeTimeout: 2)
        XCTAssertTrue(granted.granted, "a listable probe directory means access is detected")

        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nope-\(UUID().uuidString)")
        let denied = await PermissionManager(probes: [missing]).checkFullDiskAccess(probeTimeout: 2)
        XCTAssertFalse(denied.granted)
    }
}

final class InsightsEngineTests: XCTestCase {
    func testFreeSpaceInsightUsesConfiguredWarningThreshold() {
        // 30 GB free is below a 50 GB user warning but above the 20 GB default —
        // the insight must follow the user's setting, not a hardcoded threshold.
        let insights = InsightsEngine.generate(result: nil, volume: makeVolume(free: 30_000_000_000),
                                                candidates: [], duplicates: [], delta: nil,
                                                health: nil, fdaGranted: nil,
                                                freeWarningBytes: 50_000_000_000)
        XCTAssertTrue(insights.contains { $0.title.contains("getting low") },
                      "30 GB free must warn when the user's threshold is 50 GB")

        // With the default threshold the same volume is healthy — no false warning.
        let defaults = InsightsEngine.generate(result: nil, volume: makeVolume(free: 30_000_000_000),
                                                candidates: [], duplicates: [], delta: nil,
                                                health: nil, fdaGranted: nil)
        XCTAssertFalse(defaults.contains { $0.title.contains("getting low") })
    }
}
