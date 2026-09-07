import SwiftUI
import RoboCore

/// Central UI-side orchestrator. Runs on the MainActor; all engine work
/// happens off the main thread via the engines' own async APIs.
@MainActor
@Observable
final class AppModel {
    // MARK: Services
    let scanEngine = ScanEngine()
    let safety = SafetyEngine()
    let cleanupEngine: CleanupEngine
    let duplicateEngine = DuplicateEngine()
    let appAnalyzer: AppAnalyzer
    let history = HistoryStore()
    let settings = SettingsStore()
    let permissions = PermissionManager()
    let trashExecutor: TrashExecutor
    let volumeManager = VolumeManager.self
    /// SQLite storage index (Tier 4): warm-start tree, queryable history,
    /// cleanup audit log. Nil when the database can't be opened — the app
    /// then degrades to the legacy JSON store.
    let storageIndex: StorageIndex?
    /// True while the dashboard shows the restored last-scan tree (launch
    /// warm start) rather than a scan from this session.
    var warmStarted = false
    /// True from launch until the warm-start restore finishes (or determines
    /// there is nothing to restore) — drives the "Restoring…" placeholder.
    var restoring = true
    /// FSEvents monitor — keeps the live tree fresh while the app runs
    /// (Tier 4: monitoring only while active, per the approved design).
    private var fileMonitor: FSEventsMonitor?
    /// Debounced save of the reconciled tree back to the storage index.
    private var reconciledSaveTask: Task<Void, Never>?

    // MARK: Scan state
    enum ScanPhase: Equatable {
        case idle, running, done, failed(String)
    }
    var scanPhase: ScanPhase = .idle
    var scanProgress: ScanProgress?
    var scanResult: ScanResult?
    var scanTask: Task<Void, Never>?
    /// Roots of the most recent scan. The honest "Scan Area" for duplicate
    /// scans — a Quick Scan's result root is a synthetic "/" wrapper and must
    /// never be walked directly (it would enumerate the entire filesystem).
    var lastScanRoots: [URL] = []

    // MARK: Derived state
    var volumes: [VolumeInfo] = []
    var candidates: [CleanupCandidate] = []
    var duplicates: [DuplicateGroup] = []
    var duplicatePhase: ScanPhase = .idle
    var apps: [AppFootprint] = []
    var leftovers: [AppFootprint] = []
    var appPhase: ScanPhase = .idle
    var snapshots: [Snapshot] = []
    var cleanupRecords: [CleanupActionRecord] = []
    var insights: [Insight] = []
    var health: HealthScore?
    var growthDelta: StorageDelta?
    var fdaStatus: FullDiskAccessStatus?

    // MARK: Phase 2 — Radar / Offenders / Forecast / Assistant
    var radarFindings: [RadarFinding] = []
    var offenders: [RepeatOffender] = []
    var forecast: StorageForecast?
    var assistantMessages: [ChatMessage] = []

    struct ChatMessage: Identifiable, Equatable {
        let id = UUID()
        let isUser: Bool
        let text: String
        let suggestions: [String]

        init(isUser: Bool, text: String, suggestions: [String] = []) {
            self.isUser = isUser
            self.text = text
            self.suggestions = suggestions
        }
    }

    var assistantContext: AssistantContext {
        AssistantContext(
            volume: primaryVolume,
            scanResult: scanResult,
            candidates: candidates,
            duplicates: duplicates,
            snapshots: snapshots,
            apps: apps,
            leftovers: leftovers,
            forecast: forecast,
            offenders: offenders,
            radarFindings: radarFindings,
            fdaGranted: fdaStatus?.granted
        )
    }

    // MARK: Cleanup execution
    var pendingPlan: CleanupPlan?
    var pendingApproval: ApprovalToken?
    var executionOutcome: CleanupExecutionOutcome?
    /// Plan preview presentation lives on the model so plans built from ANY
    /// entry point (Overview, Target sheet, Assistant, Cleanup itself) are
    /// actually shown — a built plan the user can't see is a dead end.
    var showPlanPreview = false

    var selectedSection: Section = .overview

    // MARK: Storage map navigation (shared between Overview card and Map screen)

    /// Drill-down path below the scan root. Empty = viewing the root.
    var mapPath: [StorageNode] = []

    var mapRoot: StorageNode? { scanResult?.root }
    var mapCurrent: StorageNode? {
        guard let root = scanResult?.root else { return nil }
        return mapPath.last ?? root
    }

    func drillMap(into node: StorageNode) {
        guard node.kind == .directory, !node.children.isEmpty else { return }
        // Avoid duplicate pushes if already at this node
        if mapPath.last?.id == node.id { return }
        mapPath.append(node)
    }

    func jumpMap(toDepth depth: Int) {
        if depth <= 0 {
            mapPath = []
        } else if depth <= mapPath.count {
            mapPath = Array(mapPath.prefix(depth))
        }
    }

    func mapParent(of node: StorageNode) -> StorageNode? {
        guard let root = scanResult?.root else { return nil }
        let chain = [root] + mapPath
        guard let index = chain.firstIndex(where: { $0.id == node.id }), index > 0 else { return nil }
        return chain[index - 1]
    }

    enum Section: String, CaseIterable, Identifiable {
        case overview, map, cleanup, apps, duplicates, files
        case radar, growth, assistant, developer, browser, uninstaller
        case settings, exclusions, history

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "Overview"
            case .map: return "Storage Map"
            case .cleanup: return "Cleanup Center"
            case .apps: return "Apps & Data"
            case .duplicates: return "Duplicates"
            case .files: return "Large Files"
            case .radar: return "Robo Radar"
            case .growth: return "Growth Tracker"
            case .assistant: return "Robo Assistant"
            case .developer: return "Developer Tools"
            case .browser: return "Browser Data"
            case .uninstaller: return "Uninstaller"
            case .settings: return "Settings"
            case .exclusions: return "Exclusions"
            case .history: return "Scan History"
            }
        }

        var symbol: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .map: return "square.grid.3x3.square"
            case .cleanup: return "sparkles"
            case .apps: return "square.grid.3x3.bottommiddle.filled"
            case .duplicates: return "square.on.square"
            case .files: return "doc.text.magnifyingglass"
            case .radar: return "dot.radiowaves.left.and.right"
            case .growth: return "chart.line.uptrend.xyaxis"
            case .assistant: return "brain.head.profile"
            case .developer: return "hammer"
            case .browser: return "globe"
            case .uninstaller: return "trash.slash"
            case .settings: return "gearshape"
            case .exclusions: return "nosign"
            case .history: return "clock.arrow.circlepath"
            }
        }

        /// Sidebar grouping matching the Disk Robo design.
        static let main: [Section] = [.overview, .map, .cleanup, .apps, .duplicates, .files]
        static let smartTools: [Section] = [.radar, .growth, .assistant, .developer, .browser, .uninstaller]
        static let system: [Section] = [.settings, .exclusions, .history]
    }

    // MARK: - Derived scan stats (status bar)

    var lastScanDate: Date? {
        scanResult?.startedAt ?? snapshots.last?.date
    }

    var scanSpeedFilesPerSec: Int? {
        guard let result = scanResult, result.duration > 0.1 else { return nil }
        return Int(Double(result.filesCount) / result.duration)
    }

    var healthVerdict: (text: String, color: Color) {
        switch health?.value ?? 0 {
        case ..<1: return ("—", .secondary)
        case ..<50: return ("Needs Attention", .red)
        case ..<75: return ("Fair", .yellow)
        default: return ("Good", .green)
        }
    }

    var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    init() {
        cleanupEngine = CleanupEngine()
        appAnalyzer = AppAnalyzer()
        // One shared SQLite connection (WAL) for the whole app.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiskRobo")
        let index = try? StorageIndex(url: support.appendingPathComponent("index.sqlite"))
        storageIndex = index
        trashExecutor = TrashExecutor(safety: safety, history: history, index: index)
        refreshVolumes()
        refreshHistory()
        warmStartFromIndex()
        // SV-3: the FDA probe lists a TCC-protected directory and must run
        // through the watchdog pool — never synchronously on the main thread.
        Task { [weak self] in
            guard let self else { return }
            self.fdaStatus = await self.permissions.checkFullDiskAccess()
        }
    }

    /// Tier 4 warm start: restore the last scan's tree from SQLite so the
    /// dashboard renders instantly on launch. A real scan overrides it.
    private func warmStartFromIndex() {
        guard let storageIndex else {
            restoring = false
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            guard let tree = storageIndex.loadTree(),
                  let info = storageIndex.loadWarmScanInfo() else {
                await MainActor.run { [weak self] in self?.restoring = false }
                return
            }

            let result = ScanResult(
                root: tree,
                label: info.label,
                startedAt: info.startedAt,
                duration: info.duration,
                filesCount: tree.fileCount,
                directoriesCount: tree.directoryCount,
                inaccessibleCount: tree.inaccessibleCount,
                categories: tree.categoryTotals(),
                largestFiles: tree.largestFiles(limit: 300),
                isQuickScan: info.isQuickScan
            )

            // Show the restored tree FIRST — the dashboard (and the storage
            // map) renders immediately. Candidate discovery follows async:
            // it walks the tree again and stats every candidate through the
            // watched pool, which used to gate the whole warm start.
            await MainActor.run { [weak self] in
                guard let self, self.scanPhase == .idle, self.scanResult == nil else { return }
                self.scanResult = result
                self.lastScanRoots = info.roots.map { URL(fileURLWithPath: $0) }
                self.warmStarted = true
                self.restoring = false
                self.scanPhase = .done
                self.recomputeHealth()
                self.recomputeInsights()
                self.recomputeRadar()
                self.startFileMonitoring()
            }

            let engine = self.cleanupEngine
            let candidates = await Task.detached(priority: .utility) {
                await engine.findCandidates(root: tree)
            }.value
            await MainActor.run { [weak self] in
                guard let self, self.scanResult?.root === tree else { return }
                self.candidates = candidates
                self.recomputeHealth()
                self.recomputeInsights()
                self.recomputeRadar()
            }
        }
    }

    // MARK: - Live reconcile (FSEvents)

    /// Watches the scan roots while the app runs; batches of changed paths
    /// reconcile the live tree by re-walking only the affected directories.
    private func startFileMonitoring() {
        guard scanResult != nil else { return }
        fileMonitor?.stop()
        let watchPaths = lastScanRoots.isEmpty ? [home.path] : lastScanRoots.map(\.path)
        fileMonitor = FSEventsMonitor.start(watching: watchPaths) { [weak self] batch in
            Task { @MainActor [weak self] in
                await self?.reconcileChanges(batch)
            }
        }
    }

    private func reconcileChanges(_ paths: [String]) async {
        // A running scan owns the tree; its completion will re-anchor everything.
        guard scanPhase != .running, var result = scanResult else { return }
        let options = scanOptions
        let changed = await TreeReconciler.reconcile(changedPaths: paths, root: result.root, options: options)
        guard changed else { return }

        // Refresh everything derived from the tree.
        result.categories = result.root.categoryTotals()
        result.largestFiles = result.root.largestFiles(limit: 300)
        scanResult = result
        warmStarted = false  // the data is live now, not a stale restore
        recomputeHealth()
        recomputeInsights()
        recomputeRadar()

        // Cleanup candidates may have appeared/vanished in the changed dirs.
        let engine = cleanupEngine
        candidates = await Task.detached(priority: .utility) {
            await engine.findCandidates(root: result.root)
        }.value
        recomputeHealth()
        recomputeRadar()

        scheduleReconciledTreeSave()
    }

    /// Persists the reconciled tree 30 s after the last change burst, so the
    /// next launch warm-starts from live data without paying a save per event.
    private func scheduleReconciledTreeSave() {
        reconciledSaveTask?.cancel()
        guard let index = storageIndex, let result = scanResult else { return }
        let info = StorageIndex.WarmScanInfo(
            startedAt: result.startedAt, duration: result.duration,
            label: result.label, isQuickScan: result.isQuickScan,
            roots: lastScanRoots.map(\.path))
        reconciledSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            index.saveTree(root: result.root, info: info)
        }
    }

    // MARK: - Volumes & history

    func refreshVolumes() {
        volumes = VolumeManager.list()
    }

    /// Loads snapshots + audit records off the main actor (disk I/O) and
    /// assigns on main. Reads from the SQLite index when available (with a
    /// one-time legacy import); falls back to the JSON store otherwise.
    func refreshHistory() {
        let store = history
        let index = storageIndex
        Task.detached(priority: .utility) { [weak self] in
            if let index {
                _ = try? index.importLegacy(from: store)
            }
            let snapshots = index?.loadSnapshots() ?? store.loadSnapshots()
            let records = index?.loadCleanupRecords() ?? store.loadCleanupRecords()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.snapshots = snapshots
                self.cleanupRecords = records
                self.recomputeGrowth()
                self.recomputeRadar()
            }
        }
    }

    func recomputeGrowth() {
        let full = snapshots.filter { !$0.isQuickScan }
        guard full.count >= 2 else { growthDelta = nil; return }
        growthDelta = GrowthAnalyzer.diff(full[full.count - 2], full[full.count - 1])
    }

    var primaryVolume: VolumeInfo? {
        volumes.first { $0.isInternal } ?? volumes.first
    }

    // MARK: - Scanning

    var scanOptions: ScanOptions {
        var o = settings.settings.scanGentleMode ? ScanOptions.gentle() : ScanOptions()
        o.excludePaths = settings.settings.excludedPaths + SettingsStore.builtInExclusions()
        return o
    }

    func startFullScan() {
        startScan(roots: [home], label: "Home — \(NSFullUserName())")
    }

    func startQuickScan() {
        let h = home
        let roots = [
            h.appendingPathComponent("Library/Caches"),
            h.appendingPathComponent(".Trash"),
            h.appendingPathComponent("Library/Logs"),
            h.appendingPathComponent("Downloads"),
            h.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
            h.appendingPathComponent(".npm"),
            h.appendingPathComponent(".cache"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        startScan(roots: roots, label: "Quick Scan")
    }

    func startScan(roots: [URL], label: String) {
        guard scanPhase != .running else { return }
        cancelScan()
        scanPhase = .running
        scanProgress = nil
        warmStarted = false
        lastScanRoots = roots
        let options = scanOptions

        // PF-1: the event loop runs OFF the main actor — every event used to
        // hop to the main thread, and scan completion ran candidate discovery
        // + snapshot building there (a guaranteed end-of-scan beachball).
        // State mutations hop back via MainActor-isolated methods.
        // Gentle mode also drops the scan's task priority to background.
        // Tier 4: scans run in the DiskRoboScanner child process (memory
        // returns to the OS on exit) when enabled and available; in-process
        // scanning remains the automatic fallback.
        let scanPriority: TaskPriority = settings.settings.scanGentleMode ? .background : .utility
        let childRequest: ChildProcessScanner.Request? = settings.settings.scanInChildProcess
            ? ChildProcessScanner.Request(
                roots: roots.map { $0.path },
                label: label,
                excludePaths: options.excludePaths,
                largeFileThresholdBytes: options.largeFileThresholdBytes,
                maxConcurrentDirectoryWalks: options.maxConcurrentDirectoryWalks,
                enumerationTimeoutSeconds: options.enumerationTimeoutSeconds,
                gentle: settings.settings.scanGentleMode)
            : nil
        scanTask = Task.detached(priority: scanPriority) { [weak self] in
            guard let self else { return }
            let stream: AsyncStream<ScanEvent>
            if let childRequest, ChildProcessScanner.scannerExecutableURL() != nil {
                stream = ChildProcessScanner.scan(
                    request: childRequest,
                    timeout: max(600, options.enumerationTimeoutSeconds * 60))
            } else {
                stream = self.scanEngine.scan(roots: roots, label: label, options: options)
            }
            for await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .progress(let p):
                    await self.applyScanProgress(p)
                case .directoryCompleted:
                    break  // nothing consumes progressive nodes anymore
                case .completed(let result):
                    await self.finishScan(result)
                case .failed(let message):
                    await self.setScanPhase(.failed(message))
                case .cancelled:
                    await self.setScanPhase(.idle)
                }
            }
        }
    }

    private func applyScanProgress(_ p: ScanProgress) {
        scanProgress = p
    }

    private func setScanPhase(_ phase: ScanPhase) {
        scanPhase = phase
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        if scanPhase == .running { scanPhase = .idle }
    }

    private func finishScan(_ result: ScanResult) async {
        mapPath = []  // stale node references from the previous tree
        scanResult = result
        scanPhase = .done
        warmStarted = false
        recomputeHealth()
        recomputeInsights()
        recomputeRadar()

        // Candidate discovery is a full-tree walk + a watched stat per
        // candidate — run it AFTER the results are on screen so the
        // dashboard appears the moment the scan finishes.
        let engine = cleanupEngine
        let newCandidates = await Task.detached(priority: .utility) {
            await engine.findCandidates(root: result.root)
        }.value
        candidates = newCandidates
        recomputeHealth()
        recomputeInsights()
        recomputeRadar()

        // Persist to the SQLite index (tree + snapshot) and the legacy JSON
        // store (kept as the compatibility/rollback path) — both off-main.
        let store = history
        let index = storageIndex
        let volume = primaryVolume
        let retention = settings.settings.snapshotRetention
        let autoSnapshot = settings.settings.autoSnapshot
        let scanRoots = lastScanRoots
        await Task.detached(priority: .utility) {
            if autoSnapshot {
                let snapshot = Snapshot.from(result: result, volume: volume)
                store.saveSnapshot(snapshot, retention: retention)
                index?.recordScan(snapshot, retention: retention)
            }
            index?.saveTree(root: result.root, info: StorageIndex.WarmScanInfo(
                startedAt: result.startedAt,
                duration: result.duration,
                label: result.label,
                isQuickScan: result.isQuickScan,
                roots: scanRoots.map { $0.path }))
        }.value
        if autoSnapshot || index != nil {
            refreshHistory()
        }
        startFileMonitoring()
        // Top Consumers needs app footprints — analyze once per launch, in background.
        if apps.isEmpty && appPhase != .running {
            analyzeApps()
        }
        // Fire any threshold alerts (system notifications if authorized).
        let alerts = settings.settings
        if alerts.notificationsEnabled {
            NotificationManager.shared.postScanAlerts(
                freeBytes: primaryVolume?.availableBytes,
                freeWarningBytes: Int64(alerts.freeSpaceWarningGB) * 1_000_000_000,
                findings: radarFindings)
        }
    }

    /// Recompute the Phase 2 intelligence layers from current data.
    func recomputeRadar() {
        // The user's free-space warning level drives every alert surface
        // (Radar, Insights, Forecast, notifications) — not just notifications.
        let warningBytes = Int64(settings.settings.freeSpaceWarningGB) * 1_000_000_000
        offenders = RepeatOffenderEngine.compute(records: cleanupRecords, currentCandidates: candidates)
        radarFindings = RadarEngine.analyze(
            volume: primaryVolume,
            snapshots: snapshots,
            candidates: candidates,
            duplicates: duplicates,
            leftovers: leftovers,
            offenders: offenders,
            freeWarningBytes: warningBytes,
            trashBytes: scanResult?.categories[.trash] ?? 0)
        forecast = ForecastEngine.forecast(snapshots: snapshots, volume: primaryVolume, lowFreeBytes: warningBytes)
    }

    // MARK: - Assistant

    func sendAssistant(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        assistantMessages.append(ChatMessage(isUser: true, text: text))

        // Scan requests are handled as real actions.
        if text.lowercased().contains("scan my disk") || text.lowercased().contains("run a scan") {
            startFullScan()
            assistantMessages.append(ChatMessage(
                isUser: false,
                text: "Starting a full scan of your home folder now. Results stream in on the Overview dashboard — ask me anything when it's done.",
                suggestions: ["Why is my disk full?"]))
            return
        }

        let reply = AssistantEngine.respond(to: text, context: assistantContext)
        assistantMessages.append(ChatMessage(isUser: false, text: reply.text, suggestions: reply.suggestions))
        applyAssistantActions(reply.actions)
    }

    private func applyAssistantActions(_ actions: [AssistantAction]) {
        for action in actions {
            switch action {
            case .navigate(let area):
                selectedSection = section(for: area)
            case .buildPlan(let mode):
                buildPlan(mode: mode)
            case .startScan(let quick):
                quick ? startQuickScan() : startFullScan()
            case .analyzeApps:
                if apps.isEmpty { analyzeApps() }
            case .findDuplicates:
                if duplicates.isEmpty { selectedSection = .duplicates }
            }
        }
    }

    private func section(for area: AppArea) -> Section {
        switch area {
        case .overview: return .overview
        case .map: return .map
        case .cleanup: return .cleanup
        case .apps: return .apps
        case .duplicates: return .duplicates
        case .files: return .files
        case .developer: return .developer
        case .browser: return .browser
        case .radar: return .radar
        case .growth: return .growth
        case .history: return .history
        case .settings: return .settings
        }
    }

    func recomputeHealth() {
        guard let volume = primaryVolume else { return }
        let greenBytes = candidates.filter { $0.risk == .green }.reduce(0) { $0 + $1.sizeBytes }
        let dupBytes = duplicates.reduce(0) { $0 + $1.wastedBytes }
        // Trash is advisory only (Disk Robo never empties it), so it counts as a
        // health penalty — sourced from scan categories, not from candidates.
        let trashLog = (scanResult?.categories[.trash] ?? 0)
            + candidates.filter { $0.kind == .log }.reduce(0) { $0 + $1.sizeBytes }

        var growth7d: Double?
        if let delta = growthDelta {
            let days = max(1, delta.toDate.timeIntervalSince(delta.fromDate) / 86_400)
            let older = snapshots.filter { !$0.isQuickScan }
            if let prev = older.count >= 2 ? older[older.count - 2] : nil, prev.usedBytes > 0 {
                growth7d = (Double(delta.totalDelta) / Double(max(prev.usedBytes, 1))) / days * 7 / 7
            }
        }

        health = HealthScoreEngine.compute(
            freeRatio: volume.freeRatio,
            totalBytes: volume.totalBytes,
            greenRecoverableBytes: greenBytes,
            duplicateBytes: dupBytes,
            growth7dRatio: growth7d,
            trashLogBytes: trashLog
        )
    }

    func recomputeInsights() {
        insights = InsightsEngine.generate(
            result: scanResult,
            volume: primaryVolume,
            candidates: candidates,
            duplicates: duplicates,
            delta: growthDelta,
            health: health,
            fdaGranted: fdaStatus?.granted,
            freeWarningBytes: Int64(settings.settings.freeSpaceWarningGB) * 1_000_000_000)
    }

    // MARK: - Duplicates

    enum DuplicateScope: String, CaseIterable, Identifiable {
        case scanArea, downloads
        var id: String { rawValue }
        var title: String {
            switch self {
            case .scanArea: return "Scan Area"
            case .downloads: return "Downloads"
            }
        }
    }

    var duplicateScope: DuplicateScope = .scanArea
    /// Human-readable pipeline stage while a duplicate scan runs (nil when idle).
    var duplicateStageText: String?

    var duplicateScanRoots: [URL] {
        switch duplicateScope {
        case .scanArea:
            return DuplicateEngine.resolveScanAreaRoots(lastScanRoots: lastScanRoots, home: home)
        case .downloads:
            return [home.appendingPathComponent("Downloads")]
        }
    }

    static func duplicateStageLabel(_ stage: DuplicateStage) -> String {
        switch stage {
        case .collecting: return "Collecting files…"
        case .grouping: return "Grouping by size…"
        case .hashing: return "Hashing candidates…"
        case .verifying: return "Verifying byte-for-byte…"
        case .done: return "Finishing…"
        }
    }

    func findDuplicates() {
        guard duplicatePhase != .running else { return }
        duplicatePhase = .running
        duplicateStageText = Self.duplicateStageLabel(.collecting)
        let minSize = Int64(settings.settings.duplicateMinSizeMB) * 1_000_000
        let roots = duplicateScanRoots
        Task { [weak self] in
            guard let self else { return }
            let groups = await self.duplicateEngine.findDuplicates(roots: roots, minSizeBytes: max(minSize, 1)) { progress in
                Task { @MainActor in
                    self.duplicateStageText = Self.duplicateStageLabel(progress.stage)
                }
            }
            if Task.isCancelled { return }
            self.duplicates = groups
            self.duplicatePhase = .done
            self.duplicateStageText = nil
            self.recomputeHealth()
            self.recomputeInsights()
        }
    }

    // MARK: - Apps

    func analyzeApps() {
        guard appPhase != .running else { return }
        appPhase = .running
        Task { [weak self] in
            guard let self else { return }
            let result = await self.appAnalyzer.analyze()
            if Task.isCancelled { return }
            self.apps = result.apps
            self.leftovers = result.leftovers
            self.appPhase = .done
        }
    }

    // MARK: - Cleanup planning & execution

    func buildPlan(mode: CleanMode, excluding excludedIDs: Set<String> = []) {
        pendingPlan = RoboPlanner.buildPlan(from: candidates, mode: mode, excluding: excludedIDs)
        showPlanPreview = true
    }

    /// Issues the single-use approval token after the user confirms in the UI.
    func approvePendingPlan() {
        guard let plan = pendingPlan else { return }
        pendingApproval = ApprovalToken.issue(paths: plan.items.map { $0.url.path })
    }

    /// Executes the approved plan through the safety-checked trash pipeline,
    /// then prunes the trashed items from all in-memory data (instant UI update).
    func executePendingPlan() {
        guard let plan = pendingPlan, let approval = pendingApproval else { return }
        let executor = trashExecutor
        let items = plan.items.map {
            TrashedItem(url: $0.url, expected: $0.fingerprint, kind: $0.kind.rawValue,
                        userInitiated: false, approval: approval)
        }
        pendingApproval = nil  // single use
        Task { [weak self] in
            guard let self else { return }
            let outcome = await executor.trashItems(items)
            self.executionOutcome = outcome
            self.pendingPlan = nil
            self.showPlanPreview = false
            self.applyTrashOutcome(outcome)
        }
    }

    /// User-initiated single-item trash (Files explorer, duplicates, uninstaller) — still
    /// passes the full safety validation, then updates the UI immediately.
    func trashUserSelected(urls: [URL]) {
        Task { [weak self] in
            guard let self else { return }
            // Fingerprints are captured through the watched pool (stats can
            // stall on TCC-protected paths — invariant 9).
            let items = await withTaskGroup(of: TrashedItem?.self) { group in
                for url in urls {
                    group.addTask {
                        TrashedItem(url: url, expected: await ItemFingerprint.capture(path: url.path),
                                    kind: "user", userInitiated: true)
                    }
                }
                var out: [TrashedItem] = []
                for await item in group { if let item { out.append(item) } }
                return out
            }
            let outcome = await self.trashExecutor.trashItems(items)
            self.executionOutcome = outcome
            self.applyTrashOutcome(outcome)
        }
    }

    /// Real-time UI update after a trash batch: remove trashed paths from every
    /// data surface (file list, candidates, duplicates, scan tree) so deleted
    /// items disappear without waiting for a rescan.
    private func applyTrashOutcome(_ outcome: CleanupExecutionOutcome) {
        let trashed = Set(outcome.results.compactMap { result -> String? in
            if case .trashed = result.outcome { return result.path }
            return nil
        }.map { PathKit.normalize($0) })
        guard !trashed.isEmpty else {
            refreshHistory()
            return
        }

        // 1. Prune the scan tree (class instance — sunburst/map update in place)
        scanResult?.root.removeDescendants(matching: trashed)

        // 2. Refresh the scan result snapshots derived from the tree
        if var result = scanResult {
            result.largestFiles = result.largestFiles.filter { !trashed.contains(PathKit.normalize($0.url.path)) }
            result.categories = result.root.categoryTotals()
            scanResult = result
        }

        // 3. Cleanup candidates
        candidates = candidates.filter { !trashed.contains(PathKit.normalize($0.url.path)) }

        // 4. Duplicate groups (a group needs >1 file to stay a group)
        duplicates = duplicates.compactMap { group in
            let files = group.files.filter { !trashed.contains(PathKit.normalize($0.url.path)) }
            return files.count > 1 ? DuplicateGroup(files: files) : nil
        }

        // 5. Apps & leftovers — an uninstalled app (bundle trashed) or a removed
        // leftover drops out of every surface instantly; survivors refresh on Re-analyze.
        let pruned = AppAnalyzer.removingTrashed(apps: apps, leftovers: leftovers, trashedPaths: trashed)
        apps = pruned.apps
        leftovers = pruned.leftovers

        recomputeHealth()
        recomputeInsights()
        recomputeRadar()
        refreshHistory()
    }

    // MARK: - Settings

    func addExclusion(_ url: URL) {
        settings.update { s in
            s.excludedPaths.append(url.path)
        }
    }

    func removeExclusion(at index: Int) {
        settings.update { s in
            guard index < s.excludedPaths.count else { return }
            s.excludedPaths.remove(at: index)
        }
    }

    func completeOnboarding() {
        settings.update { $0.onboardingCompleted = true }
    }

    func recheckPermissions() {
        Task { [weak self] in
            guard let self else { return }
            self.fdaStatus = await self.permissions.checkFullDiskAccess()
            self.recomputeInsights()
        }
    }
}
