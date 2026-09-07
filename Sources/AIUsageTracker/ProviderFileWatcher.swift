import CoreServices
import Foundation

/// Recursive transcript-directory invalidation. FSEvents is intentionally
/// allowed to defer and coalesce writes; the indexer remains the source of
/// truth and does not need an event for every appended JSONL record.
final class ProviderFileWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "AIUsageTracker.provider-file-events", qos: .utility)
    private let onChange: ([String]) -> Void
    private let onRescanRequired: () -> Void
    private var stream: FSEventStreamRef?

    init(onChange: @escaping ([String]) -> Void, onRescanRequired: @escaping () -> Void) {
        self.onChange = onChange
        self.onRescanRequired = onRescanRequired
    }

    func update(paths: [String]) {
        stop()
        let uniquePaths = Array(Set(paths)).sorted()
        guard !uniquePaths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            nil,
            Self.callback,
            &context,
            uniquePaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,
            flags
        ) else {
            onRescanRequired()
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            onRescanRequired()
            return
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    private static let callback: FSEventStreamCallback = { _, context, count, rawPaths, flags, _ in
        guard let context else { return }
        let watcher = Unmanaged<ProviderFileWatcher>.fromOpaque(context).takeUnretainedValue()
        let pathArray = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as NSArray
        let paths = (0..<min(count, pathArray.count)).compactMap { pathArray[$0] as? String }
        let rescanFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged
        )
        if (0..<count).contains(where: { flags[$0] & rescanFlags != 0 }) {
            watcher.onRescanRequired()
            return
        }
        watcher.onChange(paths)
    }
}
