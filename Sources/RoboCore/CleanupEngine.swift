import Foundation

public enum CandidateKind: String, Codable, CaseIterable, Sendable {
    case cache, log, derivedData, deviceSupport, simulatorCache, packageCache
    case oldInstaller, oldArchive, oldDownload, archive
}

/// A single explained cleanup opportunity. Everything the UI needs to let the
/// user decide: what it is, why it exists, what happens if removed, whether it
/// regenerates, plus risk, confidence, and a fingerprint for TOCTOU re-verification.
public struct CleanupCandidate: Identifiable, Sendable, Hashable {
    public let id: String
    public let url: URL
    public let name: String
    public let sizeBytes: Int64
    public let category: StorageCategory
    public let kind: CandidateKind
    public let risk: RiskLevel
    public let confidence: Confidence
    public let what: String
    public let why: String
    public let impact: String
    public let canReturn: Bool
    public let fingerprint: ItemFingerprint?

    public init(id: String = UUID().uuidString, url: URL, name: String, sizeBytes: Int64, category: StorageCategory,
                kind: CandidateKind, risk: RiskLevel, confidence: Confidence, what: String, why: String,
                impact: String, canReturn: Bool, fingerprint: ItemFingerprint?) {
        self.id = url.path
        self.url = url
        self.name = name
        self.sizeBytes = sizeBytes
        self.category = category
        self.kind = kind
        self.risk = risk
        self.confidence = confidence
        self.what = what
        self.why = why
        self.impact = impact
        self.canReturn = canReturn
        self.fingerprint = fingerprint
    }
}

/// Rule-driven cleanup candidate discovery over a scanned tree.
/// Rules are keyed on exact rule-root paths (see docs/05-data.md §5);
/// every candidate carries its explanation and deterministic risk.
public struct CleanupEngine: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public func findCandidates(root: StorageNode,
                               minCandidateBytes: Int64 = 1_000_000,
                               installerAgeDays: Double = 30,
                               downloadAgeDays: Double = 90,
                               now: Date = Date()) async -> [CleanupCandidate] {
        let h = PathKit.normalize(home.path)
        let ruleRoots: [String: CandidateKind] = [
            h + "/library/caches": .cache,
            "/library/caches": .cache,
            h + "/library/logs": .log,
            "/library/logs": .log,
            h + "/library/developer/xcode/deriveddata": .derivedData,
            h + "/library/developer/xcode/ios devicesupport": .deviceSupport,
            h + "/library/developer/coresimulator/caches": .simulatorCache,
            h + "/.npm": .packageCache,
            h + "/.cache": .packageCache,
        ]

        var out: [CleanupCandidate] = []

        func visit(_ n: StorageNode) async {
            let p = PathKit.normalize(n.url.path)

            if let kind = ruleRoots[p] {
                for child in n.children {
                    if let c = await makeCandidate(child, kind: kind, minBytes: minCandidateBytes) { out.append(c) }
                }
                return
            }
            if p == h + "/library/developer/xcode/archives" {
                for child in n.children {
                    if let c = await makeCandidate(child, kind: .archive, minBytes: minCandidateBytes) { out.append(c) }
                }
                return
            }
            if p == h + "/downloads" || p.hasPrefix(h + "/downloads/") {
                for child in n.children where child.isLeaf {
                    if let c = await downloadFileCandidate(child, now: now, installerAge: installerAgeDays,
                                                           downloadAge: downloadAgeDays, minBytes: minCandidateBytes) {
                        out.append(c)
                    }
                }
                for child in n.children where !child.isLeaf { await visit(child) }
                return
            }
            for child in n.children where !child.isLeaf { await visit(child) }
        }

        await visit(root)
        return out.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: - Candidate builders

    private func makeCandidate(_ node: StorageNode, kind: CandidateKind, minBytes: Int64) async -> CleanupCandidate? {
        guard node.size >= minBytes else { return nil }
        let (risk, confidence, what, why, impact, canReturn, category): (RiskLevel, Confidence, String, String, String, Bool, StorageCategory)
        switch kind {
        case .cache:
            (risk, confidence, what, why, impact, canReturn, category) =
                (.green, .veryHigh,
                 "Cache data used by “\(node.name)”",
                 "Apps store reusable data in caches to speed things up. Caches are rebuilt automatically whenever the app needs them again.",
                 "The app may run a little slower at first while it rebuilds this cache.",
                 true, .caches)
        case .log:
            (risk, confidence, what, why, impact, canReturn, category) =
                (.green, .high,
                 "Log files written by “\(node.name)”",
                 "Diagnostic logs accumulate over time and old ones are rarely needed.",
                 "App behavior is unaffected; new logs are written as needed.",
                 true, .logs)
        case .derivedData:
            (risk, confidence, what, why, impact, canReturn, category) =
                (.green, .high,
                 "Xcode build artifacts for a project",
                 "Xcode generates build products and indexes here to make rebuilds faster.",
                 "The next build of that project will be slower while Xcode regenerates these files. No source code is affected.",
                 true, .developer)
        case .deviceSupport:
            (risk, confidence, what, why, impact, canReturn, category) =
                (.green, .medium,
                 "iOS device support files",
                 "Created when an iOS device is connected to Xcode; kept for symbolication and debugging.",
                 "Files are re-created automatically the next time that device is connected.",
                 true, .developer)
        case .simulatorCache:
            (risk, confidence, what, why, impact, canReturn, category) =
                (.green, .high,
                 "iOS Simulator caches",
                 "Simulator runtime caches from Xcode.",
                 "Simulators rebuild caches on next launch. Simulator device data (apps, settings) is not touched.",
                 true, .developer)
        case .packageCache:
            (risk, confidence, what, why, impact, canReturn, category) =
                (.green, .high,
                 "Package-manager download cache",
                 "Package managers (npm, pip, and similar) keep downloaded archives to speed up future installs.",
                 "Packages are simply re-downloaded on demand when needed again.",
                 true, .developer)
        case .archive:
            (risk, confidence, what, why, impact, canReturn, category) =
                (.orange, .medium,
                 "Xcode archive",
                 "Build archives may be required for App Store submissions or crash symbolication.",
                 "Removing an archive cannot be undone once the Trash is emptied. Already-exported apps are not affected.",
                 false, .developer)
        default:
            return nil
        }

        return CleanupCandidate(
            url: node.url, name: node.name, sizeBytes: node.size, category: category, kind: kind,
            risk: risk, confidence: confidence, what: what, why: why, impact: impact, canReturn: canReturn,
            fingerprint: await ItemFingerprint.capture(path: node.url.path)
        )
    }

    private func downloadFileCandidate(_ node: StorageNode, now: Date, installerAge: Double,
                                       downloadAge: Double, minBytes: Int64) async -> CleanupCandidate? {
        guard node.size >= minBytes, let modDate = node.modDate else { return nil }
        let ageDays = now.timeIntervalSince(modDate) / 86_400
        let ext = (node.url.pathExtension).lowercased()

        if ClassificationEngine.installerExtensions.contains(ext), ageDays >= installerAge {
            return CleanupCandidate(
                url: node.url, name: node.name, sizeBytes: node.size, category: .installers, kind: .oldInstaller,
                risk: .yellow, confidence: .high,
                what: "Installer file in Downloads (\(Int(ageDays)) days old)",
                why: "Disk images and packages are usually needed only once — to install the app.",
                impact: "If you ever need to install again on another Mac, simply re-download it from the vendor.",
                canReturn: true,
                fingerprint: await ItemFingerprint.capture(path: node.url.path)
            )
        }
        if ClassificationEngine.archiveExtensions.contains(ext), ageDays >= downloadAge {
            return CleanupCandidate(
                url: node.url, name: node.name, sizeBytes: node.size, category: .archives, kind: .oldArchive,
                risk: .yellow, confidence: .medium,
                what: "Archive in Downloads (\(Int(ageDays)) days old)",
                why: "This compressed archive has not been modified in over 90 days.",
                impact: "Check its contents before removing — archives may hold the only copy of their files.",
                canReturn: false,
                fingerprint: await ItemFingerprint.capture(path: node.url.path)
            )
        }
        if ageDays >= downloadAge {
            return CleanupCandidate(
                url: node.url, name: node.name, sizeBytes: node.size, category: .downloads, kind: .oldDownload,
                risk: .yellow, confidence: .medium,
                what: "Downloaded file, not modified in \(Int(ageDays)) days",
                why: "Long-unmodified downloads are frequently forgotten after their first use.",
                impact: "Review before removing — Disk Robo cannot know whether you still need this file.",
                canReturn: false,
                fingerprint: await ItemFingerprint.capture(path: node.url.path)
            )
        }
        return nil
    }
}
