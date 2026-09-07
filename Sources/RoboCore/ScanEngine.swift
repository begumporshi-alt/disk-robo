import Foundation

/// Deep logical size of a directory tree (bounded, cancellation-aware).
/// Used for package bundles (`.app` etc.) and app-related library folders.
///
/// Enumeration goes through the `EnumerationWorkers` watchdog pool: some
/// system directories (e.g. `~/Library/Caches/com.apple.Music` behind the
/// Media TCC service) block `open()` forever, which would hang the whole
/// app analysis. A timed-out directory simply contributes 0 bytes.
public enum DirectorySizer {
    public static func logicalSize(of url: URL, maxItems: Int = 2_000_000,
                                   enumerationTimeout: TimeInterval = 10) async -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        guard let first = await ScanEngine.listDirectory(url, keys: keys, timeout: enumerationTimeout).contents else {
            return 0
        }

        var total: Int64 = 0
        var count = 0
        var queue: [URL] = first
        while let entry = queue.popLast() {
            count += 1
            if count > maxItems { break }
            if count % 4096 == 0 && Task.isCancelled { break }
            guard let v = try? entry.resourceValues(forKeys: Set(keys)),
                  v.isSymbolicLink != true else { continue }
            if v.isDirectory == true {
                if let children = await ScanEngine.listDirectory(entry, keys: keys, timeout: enumerationTimeout).contents {
                    queue.append(contentsOf: children)
                }
                continue
            }
            guard v.isRegularFile == true else { continue }
            total += Int64(v.fileSize ?? 0)
        }
        return total
    }
}

/// Thread-safe scan progress aggregation with yield throttling.
final class ScanProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var files = 0
    private var bytes: Int64 = 0
    private var directories = 0
    private var currentPath = ""

    /// Records a completed directory; returns true at most once per
    /// `minimumYieldInterval` (time-based, so an 8-way parallel walk can't
    /// flood the UI with hundreds of main-actor events per second).
    @discardableResult
    func add(files newFiles: Int, bytes newBytes: Int64, currentPath: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        files += newFiles
        bytes += newBytes
        directories += 1
        self.currentPath = currentPath
        let now = Date()
        if let last = lastYieldAt, now.timeIntervalSince(last) < minimumYieldInterval {
            return false
        }
        lastYieldAt = now
        return true
    }
    private var lastYieldAt: Date?
    private let minimumYieldInterval: TimeInterval = 0.15

    func snapshot(startedAt: Date) -> ScanProgress {
        lock.lock(); defer { lock.unlock() }
        return ScanProgress(filesSeen: files, bytesSeen: bytes, directoriesSeen: directories,
                            currentPath: currentPath, elapsed: Date().timeIntervalSince(startedAt))
    }
}

/// Thread-safe one-shot continuation box: a producer and the awaiting caller
/// race; whichever fires first resolves exactly once. (Handles both orders:
/// resume-before-attach stores an early result; attach-before-resume hands it
/// straight to the continuation.)
final class OnceBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var earlyResult: Value?

    func attach(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if let result = earlyResult {
            lock.unlock()
            continuation.resume(returning: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: Value) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        earlyResult = value
        lock.unlock()
    }
}

/// Fixed-width pool of dedicated enumeration worker threads.
///
/// Two hard rules, both learned from a machine whose system directories
/// (`~/Library/Caches/com.apple.Music` + 23 Group Containers entries) make
/// `open()` block forever with no error:
///
/// 1. **Directory listings never run on the Swift cooperative pool or the GCD
///    global queue** — a blocked open() parks that thread permanently, and on
///    a shared pool every later item queues behind it (or the async runtime
///    starves entirely). Here only dedicated worker threads can be lost, and
///    timed-out jobs get their worker replaced so the pool never starves.
/// 2. **Callers suspend instead of block** (`await submit`): blocking a
///    cooperative thread — even in a timed semaphore wait — can exhaust the
///    async runtime's thread width and deadlock tasks unrelated to the scan.
///
/// Watchdogs: a SINGLE repeating timer sweeps in-flight jobs for expired
/// deadlines. Per-job `DispatchSourceTimer`s (82k+ per scan) cost more than
/// the listings themselves; the sweep adds ≤ one interval of timeout
/// granularity, which no caller depends on.
final class EnumerationWorkers: @unchecked Sendable {
    static let shared = EnumerationWorkers()

    struct Listing: Sendable { let contents: [URL]?; let error: String? }

    private final class ListJob {
        let url: URL
        let keys: [URLResourceKey]
        let once = OnceBox<Listing>()
        let deadline: Date
        init(url: URL, keys: [URLResourceKey], deadline: Date) {
            self.url = url
            self.keys = keys
            self.deadline = deadline
        }
    }

    /// Type-erased watched job for arbitrary blocking work (stats, xattr
    /// reads — anything that can stall on TCC-protected paths).
    private final class AnyJob {
        let deadline: Date
        let run: @Sendable () -> Void
        let timeoutResume: @Sendable () -> Void
        init(deadline: Date, run: @escaping @Sendable () -> Void, timeoutResume: @escaping @Sendable () -> Void) {
            self.deadline = deadline
            self.run = run
            self.timeoutResume = timeoutResume
        }
    }

    private let lock = NSLock()
    private var jobs: [ListJob] = []
    private var watchedJobs: [AnyJob] = []
    /// Jobs handed to workers but not yet completed — the sweep's watch list.
    private var inFlight: [ListJob] = []
    private var inFlightWatched: [AnyJob] = []
    private var workerCount = 0
    /// Paths that already timed out once this session. Re-measuring them would
    /// just burn another timeout — they are answered instantly instead.
    /// (Bounded; cleared only by relaunching the app.)
    private var blockedPaths: Set<String> = []
    private let maxWorkers: Int
    private let available = DispatchSemaphore(value: 0)
    private let enumerate: @Sendable (URL, [URLResourceKey]) -> Listing
    private let sweepInterval: TimeInterval
    private var sweepTimer: DispatchSourceTimer?

    /// - Parameter enumerate: injectable for tests; defaults to the real listing.
    init(count: Int = 8,
         maxWorkers: Int = 64,
         sweepInterval: TimeInterval = 0.25,
         enumerate: @escaping @Sendable (URL, [URLResourceKey]) -> Listing = { url, keys in
            do {
                let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
                return Listing(contents: contents, error: nil)
            } catch {
                return Listing(contents: nil, error: error.localizedDescription)
            }
         }) {
        self.maxWorkers = max(maxWorkers, count)
        self.enumerate = enumerate
        self.sweepInterval = sweepInterval
        for _ in 0..<count { spawnWorker() }
    }

    private func spawnWorker() {
        lock.lock()
        guard workerCount < maxWorkers else { lock.unlock(); return }
        workerCount += 1
        let index = workerCount
        lock.unlock()
        let thread = Thread { [self] in workerLoop(index) }
        thread.name = "diskrobo.enumerate.\(index)"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func workerLoop(_ index: Int) {
        while true {
            available.wait()
            lock.lock()
            if !watchedJobs.isEmpty {
                let job = watchedJobs.removeFirst()
                inFlightWatched.append(job)
                if sweepTimer == nil { startSweepTimerLocked() }
                lock.unlock()
                job.run()
                lock.lock()
                inFlightWatched.removeAll { $0 === job }
                lock.unlock()
                continue
            }
            guard !jobs.isEmpty else { lock.unlock(); continue }
            let job = jobs.removeFirst()
            inFlight.append(job)
            if sweepTimer == nil { startSweepTimerLocked() }
            lock.unlock()

            let listing = enumerate(job.url, job.keys)

            lock.lock()
            inFlight.removeAll { $0 === job }
            lock.unlock()
            job.once.resume(listing)
        }
    }

    /// One repeating timer for the whole pool; started lazily on the first
    /// in-flight job. Runs forever once started — the cost of one timer per
    /// process is negligible.
    private func startSweepTimerLocked() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + sweepInterval, repeating: sweepInterval)
        timer.setEventHandler { [weak self] in
            self?.sweep()
        }
        timer.resume()
        sweepTimer = timer
    }

    private func sweep() {
        let now = Date()
        var expired: [ListJob] = []
        var expiredWatched: [AnyJob] = []
        lock.lock()
        if !inFlight.isEmpty {
            var remaining: [ListJob] = []
            for job in inFlight {
                if job.deadline <= now { expired.append(job) } else { remaining.append(job) }
            }
            inFlight = remaining
        }
        if !inFlightWatched.isEmpty {
            var remaining: [AnyJob] = []
            for job in inFlightWatched {
                if job.deadline <= now { expiredWatched.append(job) } else { remaining.append(job) }
            }
            inFlightWatched = remaining
        }
        lock.unlock()

        for job in expired {
            // The worker on this job is almost certainly blocked in an
            // uninterruptible open() — replace it and remember the path so it
            // is never measured again this session.
            job.once.resume(Listing(contents: nil,
                                     error: "Timed out — this location did not respond (system-protected)."))
            noteBlocked(PathKit.normalize(job.url.path))
            spawnWorker()
        }
        for job in expiredWatched {
            // Same story for arbitrary watched work (stats, xattr reads).
            job.timeoutResume()
            spawnWorker()
        }
    }

    /// Runs arbitrary blocking work (typically filesystem metadata calls that
    /// can stall on TCC-protected paths) on a dedicated worker under the
    /// sweep watchdog. Returns nil when the work times out; the blocked
    /// worker is replaced so the pool never starves.
    func runWatched<T: Sendable>(timeout: TimeInterval, _ work: @escaping @Sendable () -> T) async -> T? {
        let box = OnceBox<T?>()
        let job = AnyJob(
            deadline: Date(timeIntervalSinceNow: timeout),
            run: { box.resume(work()) },
            timeoutResume: { box.resume(nil) })
        enqueueWatched(job)
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            box.attach(continuation)
        }
    }

    private func enqueueWatched(_ job: AnyJob) {
        lock.lock()
        watchedJobs.append(job)
        if sweepTimer == nil { startSweepTimerLocked() }
        lock.unlock()
        available.signal()
    }

    /// Suspends until the listing completes or the sweep watchdog expires it.
    func submit(_ url: URL, keys: [URLResourceKey], timeout: TimeInterval) async -> Listing {
        let pathKey = PathKit.normalize(url.path)
        if isKnownBlocked(pathKey) {
            return Listing(contents: nil,
                           error: "Skipped — this location did not respond earlier (system-protected).")
        }

        let job = ListJob(url: url, keys: keys, deadline: Date(timeIntervalSinceNow: timeout))
        let listing: Listing = await withCheckedContinuation { (continuation: CheckedContinuation<Listing, Never>) in
            job.once.attach(continuation)
            lock.lock()
            jobs.append(job)
            if sweepTimer == nil { startSweepTimerLocked() }
            lock.unlock()
            available.signal()
        }
        return listing
    }

    private func isKnownBlocked(_ pathKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return blockedPaths.contains(pathKey)
    }

    private func noteBlocked(_ pathKey: String) {
        lock.lock()
        if blockedPaths.count < 1024 { blockedPaths.insert(pathKey) }
        lock.unlock()
    }
}

/// Fixed-width pool of dedicated worker threads for arbitrary blocking work
/// (file hashing, etc.) that must never occupy Swift cooperative threads
/// (invariant 9). Unlike `EnumerationWorkers` there is no watchdog: jobs are
/// expected to terminate on their own (file reads return or error).
final class DedicatedPool: @unchecked Sendable {
    /// Pool for content hashing (partial + full SHA-256) during duplicate scans.
    static let hashing = DedicatedPool(count: 4, name: "diskrobo.hash")

    private final class PoolJob {
        let work: @Sendable () -> Void
        init(work: @escaping @Sendable () -> Void) { self.work = work }
    }

    private let lock = NSLock()
    private var jobs: [PoolJob] = []
    private let available = DispatchSemaphore(value: 0)

    init(count: Int, name: String) {
        for i in 0..<count {
            let thread = Thread { [self] in
                while true {
                    available.wait()
                    lock.lock()
                    guard !jobs.isEmpty else { lock.unlock(); continue }
                    let job = jobs.removeFirst()
                    lock.unlock()
                    job.work()
                }
            }
            thread.name = "\(name).\(i)"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    /// Runs `work` on the pool and awaits its result. `OnceBox` makes the
    /// worker-finishes-first order safe.
    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let box = OnceBox<T>()
        enqueue(PoolJob { box.resume(work()) })
        return await withCheckedContinuation { continuation in
            box.attach(continuation)
        }
    }

    private func enqueue(_ job: PoolJob) {
        lock.lock()
        jobs.append(job)
        lock.unlock()
        available.signal()
    }
}

/// Asynchronous, cancellable, memory-bounded filesystem scanner.
///
/// - Directories and files ≥ `options.largeFileThresholdBytes` become nodes.
/// - Smaller files are aggregated per directory (`smallFileCount` / `smallFileBytes`).
/// - Symlinks are never followed; packages are single leaves with deep sizes.
/// - Inaccessible directories (TCC) become flagged nodes — never estimated.
/// - Bounded parallelism; progressive `directoryCompleted` events for shallow depths.
public struct ScanEngine: Sendable {
    public init() {}

    // MARK: - Enumeration watchdog

    /// Directory listing with a hard timeout, run on the dedicated
    /// `EnumerationWorkers` pool. Async by design: callers suspend while the
    /// dedicated worker enumerates, so a blocked directory can never consume a
    /// Swift cooperative thread.
    static func listDirectory(_ url: URL, keys: [URLResourceKey], timeout: TimeInterval,
                              workers: EnumerationWorkers = .shared) async -> (contents: [URL]?, error: String?) {
        let listing = await workers.submit(url, keys: keys, timeout: timeout)
        return (listing.contents, listing.error)
    }

    public func scan(root: URL, options: ScanOptions = .standard) -> AsyncStream<ScanEvent> {
        scan(roots: [root], label: root.lastPathComponent, options: options)
    }

    /// Multi-root scan (used by Quick Scan over known cleanup locations).
    public func scan(roots: [URL], label: String, options: ScanOptions = .standard) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                await ScanEngine.run(roots: roots, label: label, options: options, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func run(roots: [URL], label: String, options initialOptions: ScanOptions,
                    continuation: AsyncStream<ScanEvent>.Continuation) async {
        var options = initialOptions
        options.excludePaths = options.excludePaths.map { PathKit.normalize($0) }
        let startedAt = Date()
        let tracker = ScanProgressTracker()

        let rootNode: StorageNode
        if roots.count == 1 {
            // Single root: the walked node IS the result root (no synthetic wrapper).
            rootNode = await walk(roots[0], depth: 0, options: options, tracker: tracker,
                                  continuation: continuation, startedAt: startedAt)
        } else {
            // Multi-root (quick scan): a synthetic parent labeled for display.
            rootNode = StorageNode(url: URL(fileURLWithPath: "/"), name: label)
            for url in roots {
                if Task.isCancelled { break }
                let child = await walk(url, depth: 0, options: options, tracker: tracker,
                                       continuation: continuation, startedAt: startedAt)
                rootNode.adopt(child)
            }
        }

        if Task.isCancelled {
            continuation.yield(.cancelled)
            continuation.finish()
            return
        }

        rootNode.children.sort { $0.size > $1.size }
        ClassificationEngine().classifyTree(rootNode)

        let result = ScanResult(
            root: rootNode,
            label: label,
            startedAt: startedAt,
            duration: Date().timeIntervalSince(startedAt),
            filesCount: rootNode.fileCount,
            directoriesCount: rootNode.directoryCount,
            inaccessibleCount: rootNode.inaccessibleCount,
            categories: rootNode.categoryTotals(),
            largestFiles: rootNode.largestFiles(limit: 300),
            isQuickScan: roots.count > 1
        )
        continuation.yield(.completed(result))
        continuation.finish()
    }

    static func walk(_ url: URL, depth: Int, options: ScanOptions, tracker: ScanProgressTracker,
                     continuation: AsyncStream<ScanEvent>.Continuation?, startedAt: Date) async -> StorageNode {
        let node = StorageNode(url: url)
        if Task.isCancelled { return node }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                      .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        let listing = await Self.listDirectory(url, keys: keys, timeout: options.enumerationTimeoutSeconds)
        guard let contents = listing.contents else {
            node.errorDescription = listing.error ?? "Directory could not be read."
            node.flags.insert(.inaccessible)
            return node
        }

        var childDirs: [URL] = []
        // PF-5: one `lstat` provides size, mtime, and type for every entry.
        // `resourceValues` (a second stat + a Set allocation per entry) is
        // reserved for the one thing lstat can't answer: isPackage — and only
        // directories can be packages, so files skip it entirely.
        let packageKeySet: Set<URLResourceKey> = [.isPackageKey]
        let isDownloadsRoot = PathKit.normalize(url.path) == PathKit.normalize(options.downloadsRoot)
        for entry in contents {
            var st = stat()
            guard lstat(entry.path, &st) == 0 else { continue }  // vanished mid-listing
            let mode = st.st_mode & S_IFMT

            if mode == S_IFLNK {
                node.symlinkCount += 1
                continue
            }
            if mode == S_IFDIR {
                // Packages (.app, .bundle, …) become single leaves with deep
                // sizes — isPackage is the ONE fact lstat can't provide, so
                // only directories pay the resourceValues stat.
                if let values = try? entry.resourceValues(forKeys: packageKeySet),
                   values.isPackage == true {
                    let packageBytes = await DirectorySizer.logicalSize(of: entry)
                    node.size += packageBytes
                    node.fileCount += 1
                    node.children.append(StorageNode(url: entry, kind: .package, size: packageBytes,
                                                     modDate: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))))
                    continue
                }
                if isExcluded(entry.path, options: options) {
                    node.excludedCount += 1
                    continue
                }
                childDirs.append(entry)
                continue
            }
            guard mode == S_IFREG else { continue }  // fifos, sockets, devices

            let size = Int64(st.st_size)
            let modDate = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            node.size += size
            node.fileCount += 1
            // Downloads root files use the lower materialization bar (SV-4).
            let materializationFloor = isDownloadsRoot
                ? min(options.downloadsMaterializationBytes, options.largeFileThresholdBytes)
                : options.largeFileThresholdBytes
            if size >= materializationFloor {
                node.children.append(StorageNode(url: entry, kind: .file, size: size, modDate: modDate))
            } else {
                node.smallFileCount += 1
                node.smallFileBytes += size
            }
        }

        if tracker.add(files: node.fileCount, bytes: node.size, currentPath: url.path) {
            continuation?.yield(.progress(tracker.snapshot(startedAt: startedAt)))
        }

        // Expand child directories — sequentially for narrow/deep trees,
        // bounded TaskGroup parallelism for wide ones.
        if childDirs.count <= 1 || depth >= options.parallelDepthLimit {
            for dir in childDirs {
                if Task.isCancelled { break }
                node.adopt(await walk(dir, depth: depth + 1, options: options, tracker: tracker,
                                      continuation: continuation, startedAt: startedAt))
            }
        } else {
            await withTaskGroup(of: StorageNode.self) { group in
                var index = 0
                func spawnNext() {
                    guard index < childDirs.count else { return }
                    let dir = childDirs[index]
                    index += 1
                    group.addTask {
                        await walk(dir, depth: depth + 1, options: options, tracker: tracker,
                                   continuation: continuation, startedAt: startedAt)
                    }
                }
                for _ in 0..<min(options.maxConcurrentDirectoryWalks, childDirs.count) { spawnNext() }
                while let child = await group.next() {
                    node.adopt(child)
                    spawnNext()
                }
            }
        }

        node.children.sort { $0.size > $1.size }
        if depth >= 1 && depth <= options.progressEventMaxDepth {
            continuation?.yield(.directoryCompleted(node))
        }
        return node
    }

    static func isExcluded(_ path: String, options: ScanOptions) -> Bool {
        let p = PathKit.normalize(path)
        return options.excludePaths.contains { PathKit.isDescendant(path: p, of: $0) }
    }
}
