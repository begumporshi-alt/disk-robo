import Foundation

// MARK: - Navigation surface (RoboCore-side; the app maps it to its sections)

public enum AppArea: String, Sendable, Equatable, CaseIterable {
    case overview, map, cleanup, apps, duplicates, files, developer, browser, radar, growth, history, settings
}

/// What the assistant asks the app to do. Actions are navigation/planning only —
/// the assistant never executes destructive operations; cleanup still goes
/// through preview → approval token → safety validation.
public enum AssistantAction: Sendable, Equatable {
    case navigate(AppArea)
    case buildPlan(CleanMode)
    case startScan(quick: Bool)
    case analyzeApps
    case findDuplicates
}

// MARK: - Intents

public enum AssistantIntent: Equatable, Sendable {
    case whyDiskFull
    case freeSpaceStatus
    case safeToClean(gb: Double?)
    case targetCleanup(gb: Double)
    case cleanNow(mode: CleanMode)
    case appUsage(query: String)
    case whatGrew
    case whereDidSpaceGo
    case showDuplicates
    case showLargestFiles
    case showDevStorage
    case explainSystemData
    case showHealth
    case help
    case unknown(String)
}

/// Rule-based, on-device intent parsing. No network, no LLM — queries are
/// matched by keyword patterns (privacy-first per spec §17).
public enum AssistantIntentParser {
    public static func parse(_ raw: String) -> AssistantIntent {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unknown(raw) }

        // Explicit numbers first
        let gbNumber = firstNumber(in: text)

        if containsAny(text, ["why is my disk full", "why is my mac", "why.*full", "disk full", "storage full", "out of space", "running out"]) {
            return .whyDiskFull
        }
        if containsAny(text, ["where did my", "where did the", "space go"]) {
            return .whereDidSpaceGo
        }
        if containsAny(text, ["what grew", "what grew since", "grew since", "what changed", "since yesterday"]) {
            return .whatGrew
        }
        if containsAny(text, ["clean safe", "clean junk", "clean now", "quick clean", "clean my mac", "clean up safe"]) {
            return .cleanNow(mode: .quick)
        }
        if containsAny(text, ["smart clean"]) {
            return .cleanNow(mode: .smart)
        }
        if containsAny(text, ["safely free", "can i free", "how much can i free", "free up"]) {
            return .safeToClean(gb: gbNumber)
        }
        if containsAny(text, ["find me", "target", "need", "give me"]) && gbNumber != nil {
            return .targetCleanup(gb: gbNumber!)
        }
        if containsAny(text, ["duplicate"]) {
            return .showDuplicates
        }
        if containsAny(text, ["largest file", "biggest file", "big files", "large files"]) {
            return .showLargestFiles
        }
        if containsAny(text, ["system data", "system storage", "what is system"]) {
            return .explainSystemData
        }
        if containsAny(text, ["health", "score"]) {
            return .showHealth
        }
        // App-specific queries must beat the generic free-space question
        // ("how much space is Xcode using?" is about Xcode, not free space).
        if containsAny(text, ["using", "footprint", "storage is"]) || text.contains("how much") {
            if let app = appQuery(in: text) {
                return .appUsage(query: app)
            }
        }
        if containsAny(text, ["how much free", "free space", "how full", "how much space", "space left", "disk status"]) {
            return .freeSpaceStatus
        }
        if containsAny(text, ["xcode", "derived", "developer"]) {
            return .showDevStorage
        }
        if containsAny(text, ["help", "what can you do", "examples"]) {
            return .help
        }
        if gbNumber != nil {
            return .safeToClean(gb: gbNumber)
        }
        return .unknown(raw)
    }

    private static func containsAny(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { text.contains($0) }
    }

    private static func firstNumber(in text: String) -> Double? {
        // Matches "20 gb", "20gb", " 5 gb"
        let range = NSRange(text.startIndex..., in: text)
        guard let match = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*gb?\b"#).firstMatch(in: text, range: range),
              let nr = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[nr])
    }

    private static func appQuery(in text: String) -> String? {
        let known = ["xcode", "docker", "chrome", "safari", "firefox", "telegram", "whatsapp",
                     "slack", "figma", "notion", "spotify", "final cut", "photoshop", "lightroom",
                     "android studio", "pycharm", "webstorm", "vscode", "visual studio", "claude", "opsboard"]
        return known.first { text.contains($0) }
    }
}

// MARK: - Replies

public struct AssistantReply: Sendable, Equatable {
    public let text: String
    public let actions: [AssistantAction]
    public let suggestions: [String]

    public init(text: String, actions: [AssistantAction] = [], suggestions: [String] = []) {
        self.text = text
        self.actions = actions
        self.suggestions = suggestions
    }
}

/// Everything the assistant needs to answer, already computed by the app.
public struct AssistantContext: Sendable {
    public var volume: VolumeInfo?
    public var scanResult: ScanResult?
    public var candidates: [CleanupCandidate]
    public var duplicates: [DuplicateGroup]
    public var snapshots: [Snapshot]
    public var apps: [AppFootprint]
    public var leftovers: [AppFootprint]
    public var forecast: StorageForecast?
    public var offenders: [RepeatOffender]
    public var radarFindings: [RadarFinding]
    public var fdaGranted: Bool?

    public init(volume: VolumeInfo? = nil, scanResult: ScanResult? = nil,
                candidates: [CleanupCandidate] = [], duplicates: [DuplicateGroup] = [],
                snapshots: [Snapshot] = [], apps: [AppFootprint] = [], leftovers: [AppFootprint] = [],
                forecast: StorageForecast? = nil, offenders: [RepeatOffender] = [],
                radarFindings: [RadarFinding] = [], fdaGranted: Bool? = nil) {
        self.volume = volume
        self.scanResult = scanResult
        self.candidates = candidates
        self.duplicates = duplicates
        self.snapshots = snapshots
        self.apps = apps
        self.leftovers = leftovers
        self.forecast = forecast
        self.offenders = offenders
        self.radarFindings = radarFindings
        self.fdaGranted = fdaGranted
    }

    public var hasData: Bool { scanResult != nil || !candidates.isEmpty || !snapshots.isEmpty }

    var greenBytes: Int64 { candidates.filter { $0.risk == .green }.reduce(0) { $0 + $1.sizeBytes } }
    var yellowBytes: Int64 { candidates.filter { $0.risk == .yellow }.reduce(0) { $0 + $1.sizeBytes } }
}

/// Deterministic response generation. Every answer is grounded in measured
/// data; when there's no data, the assistant says so instead of guessing.
public enum AssistantEngine {
    public static func respond(to raw: String, context: AssistantContext) -> AssistantReply {
        let intent = AssistantIntentParser.parse(raw)
        let noData = "I don't have a scan to work from yet. Say “scan my disk” or open Overview — I only answer from measured data, never estimates."

        switch intent {
        case .whyDiskFull:
            guard context.hasData else { return AssistantReply(text: noData, actions: [.startScan(quick: true)], suggestions: ["Scan my disk"]) }
            var lines: [String] = []
            if let v = context.volume {
                lines.append("\(v.name): \(Format.bytes(v.usedBytes)) used of \(Format.bytes(v.totalBytes)) — \(Format.bytes(v.availableBytes)) free.")
            }
            let categories = (context.scanResult?.categories ?? [:]).sorted { $0.value > $1.value }
            if let top = categories.prefix(3).first, top.value > 0 {
                lines.append("Your biggest scanned categories: " + categories.prefix(3)
                    .map { "\($0.key.displayName) \(Format.bytes($0.value))" }
                    .joined(separator: ", ") + ".")
            }
            if let finding = context.radarFindings.first {
                lines.append("Top anomaly on Robo Radar: \(finding.title).")
            }
            if let grower = topGrower(context) {
                lines.append("Fastest recent growth: \(grower.path) (+\(Format.bytes(grower.delta))).")
            }
            lines.append(context.greenBytes > 0
                ? "\(Format.bytes(context.greenBytes)) is safely recoverable right now."
                : "No significant safe-cleanup data found.")
            return AssistantReply(
                text: lines.joined(separator: "\n\n"),
                actions: [.navigate(.radar), .buildPlan(.quick)],
                suggestions: ["What can I safely clean?", "What grew since yesterday?", "Where did my space go?"])

        case .freeSpaceStatus:
            guard let v = context.volume else {
                return AssistantReply(text: "I couldn't read volume information.", suggestions: ["Scan my disk"])
            }
            var text = "\(Format.bytes(v.availableBytes)) free on \(v.name) (\(Format.percent(v.freeRatio)))."
            if let forecast = context.forecast {
                text += "\n\nForecast: \(forecast.narrative) (confidence: \(forecast.confidence.displayName).)"
            }
            return AssistantReply(text: text, actions: [.navigate(.overview)],
                                  suggestions: ["Why is my disk full?", "Can I safely free 20 GB?"])

        case .safeToClean(let gb):
            guard context.hasData else { return AssistantReply(text: noData, actions: [.startScan(quick: true)]) }
            let green = context.greenBytes
            let yellow = context.yellowBytes
            var text = "Right now, \(Format.bytes(green)) is high-confidence safe (caches, build artifacts, logs — all regenerable, all Trash-only). Another \(Format.bytes(yellow)) needs your review (old downloads, installers, archives)."
            if let requested = gb {
                let enough = green >= Int64(requested * 1_000_000_000)
                text += enough
                    ? "\n\nThat covers your \(Int(requested)) GB goal — I can build the plan."
                    : "\n\nSafe items alone don't reach \(Int(requested)) GB; the plan would include review items too."
                return AssistantReply(text: text,
                                      actions: [.buildPlan(.target(gigabytes: requested)), .navigate(.cleanup)],
                                      suggestions: ["Clean safe junk", "Show duplicates"])
            }
            return AssistantReply(text: text, actions: [.navigate(.cleanup)],
                                  suggestions: ["Clean safe junk", "Build me a 20 GB plan"])

        case .targetCleanup(let gb):
            guard context.hasData else { return AssistantReply(text: noData, actions: [.startScan(quick: true)]) }
            let mode = CleanMode.target(gigabytes: gb)
            return AssistantReply(
                text: "Building the safest plan to recover \(Int(gb)) GB — greens first, then yellows, each explained. Nothing is deleted until you approve the preview.",
                actions: [.buildPlan(mode), .navigate(.cleanup)],
                suggestions: ["What can I safely clean?"])

        case .cleanNow(let mode):
            guard context.hasData else { return AssistantReply(text: noData, actions: [.startScan(quick: true)]) }
            let plan = RoboPlanner.buildPlan(from: context.candidates, mode: mode)
            return AssistantReply(
                text: plan.items.isEmpty
                    ? "No \(mode.displayName) candidates right now — your disk is tidy."
                    : "I've prepared a \(mode.displayName) plan: \(plan.items.count) items, ≈\(Format.bytes(plan.expectedRecoveryBytes)) recoverable. Review it in the Cleanup Center — you approve every item before anything moves to the Trash.",
                actions: [.buildPlan(mode), .navigate(.cleanup)],
                suggestions: ["Why is my disk full?", "Show duplicates"])

        case .appUsage(let query):
            let matches = context.apps.filter { $0.name.lowercased().contains(query) || ($0.bundleID?.lowercased().contains(query) ?? false) }
            guard !matches.isEmpty else {
                return AssistantReply(
                    text: context.apps.isEmpty
                        ? "I haven't analyzed app footprints yet. Say “analyze apps” or open Apps & Data — I'll measure every app's total footprint including hidden library data."
                        : "I couldn't find an app matching “\(query)”. Try opening Apps & Data for the full list.",
                    actions: [.analyzeApps, .navigate(.apps)],
                    suggestions: ["How much space is Xcode using?"])
            }
            let app = matches.max { $0.totalBytes < $1.totalBytes }!
            let parts: [String] = [
                app.bundleBytes > 0 ? "app \(Format.bytes(app.bundleBytes))" : nil,
                app.applicationSupportBytes > 0 ? "support data \(Format.bytes(app.applicationSupportBytes))" : nil,
                app.cachesBytes > 0 ? "caches \(Format.bytes(app.cachesBytes))" : nil,
                app.containersBytes > 0 ? "containers \(Format.bytes(app.containersBytes))" : nil,
                app.otherLibraryBytes > 0 ? "other \(Format.bytes(app.otherLibraryBytes))" : nil,
            ].compactMap { $0 }
            return AssistantReply(
                text: "\(app.name) uses \(Format.bytes(app.totalBytes)) in total: \(parts.joined(separator: " · "))."
                    + (app.cachesBytes > 0 ? " Caches are safe to clean and regenerate." : ""),
                actions: [.navigate(.apps)],
                suggestions: ["Clean safe junk", "Why is my disk full?"])

        case .whatGrew, .whereDidSpaceGo:
            let full = context.snapshots.filter { !$0.isQuickScan }.sorted { $0.date < $1.date }
            guard full.count >= 2 else {
                return AssistantReply(
                    text: "I need at least two full scans to compare (I have \(full.count)). Run another scan in a few days and I'll tell you exactly what changed.",
                    actions: [.startScan(quick: false)],
                    suggestions: ["Why is my disk full?"])
            }
            let delta = GrowthAnalyzer.diff(full[full.count - 2], full[full.count - 1])
            let lines = GrowthAnalyzer.narratives(for: delta)
            return AssistantReply(text: lines.joined(separator: "\n"),
                                  actions: [.navigate(.growth)],
                                  suggestions: ["Can I safely free 20 GB?", "What is Xcode using?"])

        case .showDuplicates:
            guard !context.duplicates.isEmpty else {
                return AssistantReply(
                    text: context.scanResult == nil
                        ? "Run a scan first, then I'll look for duplicates."
                        : "I haven't found duplicates yet — I can run the byte-verified duplicate scan (size → partial hash → full hash).",
                    actions: [.findDuplicates, .navigate(.duplicates)],
                    suggestions: ["Scan my disk"])
            }
            let wasted = context.duplicates.reduce(0) { $0 + $1.wastedBytes }
            return AssistantReply(
                text: "\(context.duplicates.count) verified duplicate groups, \(Format.bytes(wasted)) wasted. Every group keeps at least one copy when you clean.",
                actions: [.navigate(.duplicates)],
                suggestions: ["Clean safe junk"])

        case .showLargestFiles:
            guard let result = context.scanResult, !result.largestFiles.isEmpty else {
                return AssistantReply(text: "No scan data yet.", actions: [.startScan(quick: true)])
            }
            let top = result.largestFiles.prefix(3)
            let lines = top.map { "· \($0.name) — \(Format.bytes($0.size)) (\($0.url.deletingLastPathComponent().path))" }
            return AssistantReply(text: "Your largest files:\n" + lines.joined(separator: "\n"),
                                  actions: [.navigate(.files)],
                                  suggestions: ["Why is my disk full?"])

        case .showDevStorage:
            let devBytes = context.scanResult?.categories[.developer] ?? 0
            let devCandidates = context.candidates.filter { [.derivedData, .deviceSupport, .simulatorCache, .packageCache, .archive].contains($0.kind) }
            guard context.hasData else { return AssistantReply(text: "Run a scan first.", actions: [.startScan(quick: true)]) }
            let cleanable = devCandidates.reduce(0) { $0 + $1.sizeBytes }
            return AssistantReply(
                text: "Developer storage: \(Format.bytes(devBytes)) scanned. \(Format.bytes(cleanable)) is build artifacts and package caches — safe to clean; the next build just takes longer.",
                actions: [.navigate(.developer)],
                suggestions: ["Clean safe junk"])

        case .explainSystemData:
            guard let result = context.scanResult else { return AssistantReply(text: "Run a scan first.", actions: [.startScan(quick: true)]) }
            let known = result.categories.filter { [.caches, .logs, .applications, .browser, .developer].contains($0.key) }
                .reduce(0) { $0 + $1.value }
            return AssistantReply(
                text: "macOS “System Data” mixes caches, logs, local app data, and system-managed files. In your scan, \(Format.bytes(known)) is inspectable app/library data I can attribute. The rest is system-managed or SIP-protected — macOS doesn't let any app (mine included) see it, and I won't estimate what I can't measure."
                    + (context.fdaGranted == false ? "\n\nGranting Full Disk Access in Settings improves coverage." : ""),
                actions: [.navigate(.settings)],
                suggestions: ["Why is my disk full?"])

        case .showHealth:
            return AssistantReply(text: "The Disk Health score lives on the Overview dashboard — it weighs free space, safe-cleanable data, duplicates, growth trend, and Trash/logs. Each factor is explained there; it's a heuristic, not science.",
                                  actions: [.navigate(.overview)],
                                  suggestions: ["Why is my disk full?"])

        case .help:
            return AssistantReply(
                text: "I'm Disk Robo's on-device assistant — every answer comes from your local scan data, and nothing leaves this Mac. Try:\n· Why is my disk full?\n· Can I safely free 20 GB?\n· What is Xcode using?\n· What grew since yesterday?\n· Where did my space go?\n· Clean safe junk\n· Show duplicates",
                suggestions: ["Why is my disk full?", "Can I safely free 20 GB?", "Where did my space go?"])

        case .unknown(let original):
            return AssistantReply(
                text: "I didn't understand “\(original)”. I'm rule-based and on-device — try one of the suggestions, or ask about free space, cleanup, apps, duplicates, or growth. (A cloud-connected LLM mode may come later, but only if you opt in.)",
                suggestions: ["Why is my disk full?", "What can I safely clean?", "Help"])
        }
    }

    private static func topGrower(_ context: AssistantContext) -> DirDelta? {
        let full = context.snapshots.filter { !$0.isQuickScan }.sorted { $0.date < $1.date }
        guard full.count >= 2 else { return nil }
        return GrowthAnalyzer.diff(full[full.count - 2], full[full.count - 1]).directoryDeltas.first { $0.delta > 0 }
    }
}
