import Foundation
import RoboCore

/// DiskRoboScanner — the scan engine as a child process (Tier 4).
///
/// Reads a JSON scan request from stdin, streams JSONL events to stdout, and
/// exits. The parent app spawns it per scan; when the process exits, ALL scan
/// memory (the ~1.1 GB allocator high-water) returns to the OS immediately.
///
/// Event stream (one JSON object per line):
///   {"type":"progress",  "files":…, "bytes":…, "dirs":…, "elapsed":…}
///   {"type":"node",      "path":…, "parent":…, "name":…, "kind":…, "size":…,
///    "category":…, "fileCount":…, "dirCount":…, "smallFiles":…, "smallBytes":…, "mtime":…}
///   {"type":"completed", "label":…, "duration":…, "files":…, "dirs":…,
///    "inaccessible":…, "isQuick":…, "rootPath":…}
///   {"type":"failed",    "message":…}
///
/// The parent rebuilds the StorageNode tree from `node` rows exactly the way
/// StorageIndex.loadTree does (byPath index + parent-path linking).

// MARK: - Wire types (mirror RoboCore's; Codable for the line protocol)

struct ScanRequest: Codable {
    var roots: [String]
    var label: String
    var excludePaths: [String] = []
    var largeFileThresholdBytes: Int64 = 10_000_000
    var maxConcurrentDirectoryWalks: Int = 8
    var enumerationTimeoutSeconds: Double = 10
    var gentle: Bool = false
}

struct NodeRow: Codable {
    var path: String
    var parent: String?
    var name: String
    var kind: String
    var size: Int64
    var category: String
    var fileCount: Int
    var dirCount: Int
    var smallFiles: Int
    var smallBytes: Int64
    var symlinkCount: Int
    var mtime: Double?
}

struct OutEvent: Encodable {
    var type: String
    var files: Int? = nil
    var bytes: Int64? = nil
    var dirs: Int? = nil
    var elapsed: Double? = nil
    var node: NodeRow? = nil
    var label: String? = nil
    var duration: Double? = nil
    var inaccessible: Int? = nil
    var isQuick: Bool? = nil
    var rootPath: String? = nil
    var message: String? = nil
}

// MARK: - Main

setbuf(stdout, nil)  // line-buffered streaming

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let request = try? JSONDecoder().decode(ScanRequest.self, from: input) else {
    let error = OutEvent(type: "failed", message: "Invalid scan request JSON.")
    if let line = try? JSONEncoder().encode(error) { FileHandle.standardOutput.write(line + Data([0x0A])) }
    exit(1)
}

var options = ScanOptions()
options.excludePaths = request.excludePaths
options.largeFileThresholdBytes = request.largeFileThresholdBytes
options.maxConcurrentDirectoryWalks = request.gentle ? 2 : request.maxConcurrentDirectoryWalks
options.enumerationTimeoutSeconds = request.enumerationTimeoutSeconds
options.downloadsRoot = "/nonexistent-in-child"  // downloads floor handled by parent request

let encoder = JSONEncoder()

func emit(_ event: OutEvent) {
    if let line = try? encoder.encode(event) {
        FileHandle.standardOutput.write(line + Data([0x0A]))
    }
}

let startedAt = Date()

// Walk each root, emitting node rows for the whole tree.
func emitTree(_ node: StorageNode, parent: String?) {
    emit(OutEvent(type: "node", node: NodeRow(
        path: node.path, parent: parent, name: node.name, kind: node.kind.rawValue,
        size: node.size, category: node.category.rawValue,
        fileCount: node.fileCount, dirCount: node.directoryCount,
        smallFiles: node.smallFileCount, smallBytes: node.smallFileBytes,
        symlinkCount: node.symlinkCount,
        mtime: node.modDate.map { $0.timeIntervalSince1970 })))
    for child in node.children {
        emitTree(child, parent: node.path)
    }
}

let scanEngine = ScanEngine()
let semaphore = DispatchSemaphore(value: 0)

Task.detached(priority: request.gentle ? .background : .utility) {
    let stream = scanEngine.scan(roots: request.roots.map { URL(fileURLWithPath: $0) },
                                 label: request.label, options: options)
    for await event in stream {
        switch event {
        case .progress(let p):
            emit(OutEvent(type: "progress", files: p.filesSeen, bytes: p.bytesSeen,
                          dirs: p.directoriesSeen, elapsed: p.elapsed))
        case .completed(let result):
            emitTree(result.root, parent: nil)
            emit(OutEvent(type: "completed", files: result.filesCount, bytes: nil,
                          dirs: result.directoriesCount, elapsed: nil, node: nil,
                          label: result.label, duration: result.duration,
                          inaccessible: result.inaccessibleCount, isQuick: result.isQuickScan,
                          rootPath: result.root.path, message: nil))
            semaphore.signal()
            return
        case .failed(let message):
            emit(OutEvent(type: "failed", message: message))
            semaphore.signal()
            return
        case .cancelled:
            semaphore.signal()
            return
        case .directoryCompleted:
            break  // not used in the child
        }
    }
    semaphore.signal()
}

semaphore.wait()
exit(0)
