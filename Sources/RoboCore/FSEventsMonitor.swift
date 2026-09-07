import Foundation
import CoreServices

/// FSEvents wrapper: watches paths while the app runs and delivers
/// debounced batches of changed paths (default granularity reports changed
/// DIRECTORIES — exactly what `TreeReconciler` re-walks).
///
/// Tier 4 decision: monitoring runs only while the app is active — zero
/// background cost when Disk Robo isn't running.
public final class FSEventsMonitor: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "diskrobo.fsevents")
    private let lock = NSLock()
    private var pending: Set<String> = []
    private var flushWorkItem: DispatchWorkItem?
    private var handler: (@Sendable ([String]) -> Void)?
    private var debounce: TimeInterval = 1

    public static func start(watching paths: [String],
                             latency: TimeInterval = 2,
                             debounce: TimeInterval = 1,
                             handler: @escaping @Sendable ([String]) -> Void) -> FSEventsMonitor? {
        guard !paths.isEmpty else { return nil }
        let monitor = FSEventsMonitor()
        monitor.handler = handler
        monitor.debounce = debounce

        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(monitor).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<FSEventsMonitor>.fromOpaque(info).takeUnretainedValue()
            // The C header types eventPaths as void* — rebind to C strings.
            let paths = eventPaths.assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self)
            var changed: [String] = []
            for i in 0..<count {
                guard let cPath = paths[i] else { continue }
                changed.append(String(cString: cPath))
            }
            monitor.enqueue(changed)
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                               paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               latency,
                                               0) else { return nil }
        monitor.stream = stream
        FSEventStreamSetDispatchQueue(stream, monitor.queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamRelease(stream)
            return nil
        }
        return monitor
    }

    private func enqueue(_ paths: [String]) {
        lock.lock()
        pending.formUnion(paths)
        lock.unlock()
        // Flush after `debounce` seconds of quiet — bursts coalesce.
        flushWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        flushWorkItem = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func flush() {
        lock.lock()
        let batch = Array(pending)
        pending.removeAll()
        lock.unlock()
        guard !batch.isEmpty else { return }
        handler?(batch)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
