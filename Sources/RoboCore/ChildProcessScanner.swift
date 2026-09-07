import Foundation

/// Spawns the DiskRoboScanner child process and streams its events back as a
/// normal `AsyncStream<ScanEvent>` (Tier 4: memory isolation).
///
/// The child does ALL scanning; when it exits, every byte of scan churn
/// (allocator high-water ~1 GB on big scans) returns to the OS immediately.
/// The parent rebuilds the StorageNode tree from the streamed node rows the
/// same way `StorageIndex.loadTree` does.
public enum ChildProcessScanner {
    struct NodeRow: Decodable {
        let path: String
        let parent: String?
        let name: String
        let kind: String
        let size: Int64
        let category: String
        let fileCount: Int
        let dirCount: Int
        let smallFiles: Int
        let smallBytes: Int64
        let symlinkCount: Int?
        let mtime: Double?
    }

    struct OutEvent: Decodable {
        let type: String
        var files: Int?
        var bytes: Int64?
        var dirs: Int?
        var elapsed: Double?
        var node: NodeRow?
        var label: String?
        var duration: Double?
        var inaccessible: Int?
        var isQuick: Bool?
        var rootPath: String?
        var message: String?
    }

    public struct Request: Codable, Sendable {
        public var roots: [String]
        public var label: String
        public var excludePaths: [String]
        public var largeFileThresholdBytes: Int64
        public var maxConcurrentDirectoryWalks: Int
        public var enumerationTimeoutSeconds: Double
        public var gentle: Bool

        public init(roots: [String], label: String, excludePaths: [String],
                    largeFileThresholdBytes: Int64 = 10_000_000,
                    maxConcurrentDirectoryWalks: Int = 8,
                    enumerationTimeoutSeconds: Double = 10,
                    gentle: Bool = false) {
            self.roots = roots
            self.label = label
            self.excludePaths = excludePaths
            self.largeFileThresholdBytes = largeFileThresholdBytes
            self.maxConcurrentDirectoryWalks = maxConcurrentDirectoryWalks
            self.enumerationTimeoutSeconds = enumerationTimeoutSeconds
            self.gentle = gentle
        }
    }

    /// Locates the scanner executable: bundled next to the app binary
    /// (Contents/MacOS/DiskRoboScanner), in SPM build dirs during
    /// development, or on the PATH as a fallback.
    public static func scannerExecutableURL() -> URL? {
        let fm = FileManager.default
        let candidates: [URL]
        let mainBundlePath = Bundle.main.bundleURL.path
        if mainBundlePath.hasSuffix(".app") {
            candidates = [
                Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/DiskRoboScanner"),
                Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/DiskRoboPackage_DiskRoboScanner"),
            ]
        } else {
            // swift run / test context: SPM build products
            let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
            candidates = [
                cwd.appendingPathComponent(".build/arm64-apple-macosx/debug/DiskRoboScanner"),
                cwd.appendingPathComponent(".build/arm64-apple-macosx/release/DiskRoboScanner"),
                cwd.appendingPathComponent(".build/debug/DiskRoboScanner"),
                cwd.appendingPathComponent(".build/release/DiskRoboScanner"),
            ]
        }
        for url in candidates where fm.isExecutableFile(atPath: url.path) {
            return url
        }
        // PATH fallback
        let path = "/usr/bin:/usr/local/bin:/opt/homebrew/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
        for dir in path.split(separator: ":") {
            let url = URL(fileURLWithPath: String(dir)).appendingPathComponent("DiskRoboScanner")
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// Runs the scan in the child process, yielding the same event types the
    /// in-process engine produces. `timeout` bounds the whole scan; on expiry
    /// the child is terminated and a `.failed` event is emitted.
    public static func scan(request: Request, timeout: TimeInterval) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                guard let scannerURL = scannerExecutableURL() else {
                    continuation.yield(.failed("DiskRoboScanner executable not found."))
                    continuation.finish()
                    return
                }

                let process = Process()
                process.executableURL = scannerURL
                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = Pipe()

                let stdout = stdoutPipe
                stdout.fileHandleForReading.readabilityHandler = nil

                guard let inputData = try? JSONEncoder().encode(request),
                      (try? process.run()) != nil else {
                    continuation.yield(.failed("Could not launch the scanner process."))
                    continuation.finish()
                    return
                }
                stdinPipe.fileHandleForWriting.write(inputData)
                stdinPipe.fileHandleForWriting.closeFile()

                // Whole-scan watchdog: kill the child on expiry.
                let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                watchdog.schedule(deadline: .now() + timeout)
                watchdog.setEventHandler {
                    if process.isRunning {
                        process.terminate()
                    }
                }
                watchdog.resume()

                var nodes: [NodeRow] = []
                var completed: OutEvent?
                var failure: String?

                let decoder = JSONDecoder()
                let handle = stdout.fileHandleForReading
                let streamReader = LineReader(handle: handle)
                while let line = streamReader.nextLine() {
                    if Task.isCancelled { break }
                    guard !line.isEmpty, let event = try? decoder.decode(OutEvent.self, from: Data(line.utf8)) else { continue }
                    switch event.type {
                    case "progress":
                        continuation.yield(.progress(ScanProgress(
                            filesSeen: event.files ?? 0,
                            bytesSeen: event.bytes ?? 0,
                            directoriesSeen: event.dirs ?? 0,
                            currentPath: "",
                            elapsed: event.elapsed ?? 0)))
                    case "node":
                        if let node = event.node { nodes.append(node) }
                    case "completed":
                        completed = event
                        streamReader.stop()
                    case "failed":
                        failure = event.message
                        streamReader.stop()
                    default:
                        break
                    }
                }

                watchdog.cancel()
                process.waitUntilExit()

                if Task.isCancelled {
                    if process.isRunning { process.terminate() }
                    continuation.yield(.cancelled)
                    continuation.finish()
                    return
                }
                if let failure {
                    continuation.yield(.failed(failure))
                    continuation.finish()
                    return
                }
                guard let completed, let rootRow = nodes.first(where: { $0.parent == nil }) else {
                    continuation.yield(.failed("The scanner process ended without a result."))
                    continuation.finish()
                    return
                }

                // Rebuild the tree: byPath index + parent linking (the
                // StorageIndex.loadTree construction).
                func makeNode(_ row: NodeRow) -> StorageNode {
                    let node = StorageNode(
                        url: URL(fileURLWithPath: row.path),
                        name: row.name,
                        kind: NodeKind(rawValue: row.kind) ?? .directory,
                        size: row.size,
                        modDate: row.mtime.map { Date(timeIntervalSince1970: $0) },
                        category: StorageCategory(rawValue: row.category) ?? .other)
                    node.fileCount = row.fileCount
                    node.directoryCount = row.dirCount
                    node.smallFileCount = row.smallFiles
                    node.smallFileBytes = row.smallBytes
                    node.symlinkCount = row.symlinkCount ?? 0
                    return node
                }

                var byPath: [String: StorageNode] = [:]
                for row in nodes { byPath[row.path] = makeNode(row) }
                guard let root = byPath[rootRow.path] else {
                    continuation.yield(.failed("Could not rebuild the scan tree."))
                    continuation.finish()
                    return
                }
                for row in nodes {
                    guard let parentPath = row.parent,
                          let parent = byPath[parentPath],
                          let child = byPath[row.path] else { continue }
                    // Direct append, NOT adopt(): the streamed aggregates
                    // already include every descendant.
                    parent.children.append(child)
                }

                let result = ScanResult(
                    root: root,
                    label: completed.label ?? request.label,
                    startedAt: Date(),
                    duration: completed.duration ?? 0,
                    filesCount: completed.files ?? root.fileCount,
                    directoriesCount: completed.dirs ?? root.directoryCount,
                    inaccessibleCount: completed.inaccessible ?? 0,
                    categories: root.categoryTotals(),
                    largestFiles: root.largestFiles(limit: 300),
                    isQuickScan: completed.isQuick ?? (request.roots.count > 1))
                continuation.yield(.completed(result))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Buffered line reader over a file handle.
final class LineReader: @unchecked Sendable {
    private let handle: FileHandle
    private var buffer = Data()
    private var stopped = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    func stop() { stopped = true }

    func nextLine() -> String? {
        while !stopped {
            if let range = buffer.firstRange(of: Data([0x0A])) {
                let line = String(data: buffer[..<range.lowerBound], encoding: .utf8)
                buffer.removeSubrange(..<range.upperBound)
                if let line { return line }
                continue
            }
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }  // EOF
            buffer.append(chunk)
        }
        return nil
    }
}
