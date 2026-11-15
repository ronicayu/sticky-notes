import Foundation
import CoreServices

/// Watches one or more directories (recursively, including in-place file
/// content edits) via FSEvents and calls `onChange` (debounced) on the main
/// queue. Unlike a directory-level `DispatchSourceFileSystemObject`, this
/// fires when an external editor (Obsidian, an iCloud sync agent, etc.)
/// rewrites a `.md` inside the watched tree.
///
/// `@unchecked Sendable`: it is used from the main thread only, and `onChange`
/// runs on the main queue; the compiler cannot see that, and owners call
/// `stop()` from `deinit`.
///
/// The stream itself runs on a private queue, not the main one. A stopped stream
/// gives back its file descriptors (about a dozen per watched folder) on the
/// queue it was scheduled on, so on the main queue they stay open for as long as
/// the main thread is busy: a test that makes many stores without yielding
/// exhausted the process's descriptors.
final class FileWatcher: @unchecked Sendable {
    private static let eventQueue = DispatchQueue(label: "StickyNotes.FileWatcher.events")

    /// What the stream's callback reaches. The stream owns it (the context's retain
    /// and release), so the callback never touches the watcher itself: the watcher
    /// can then be released on the main thread whatever the stream is doing, and
    /// is only looked at, on the main queue, to start the debounce.
    private final class EventSink {
        private final class WeakWatcher: @unchecked Sendable {
            weak var watcher: FileWatcher?
        }
        private let target = WeakWatcher()

        init(_ watcher: FileWatcher) { target.watcher = watcher }

        /// Called on the stream's queue.
        func fire() {
            let target = target
            DispatchQueue.main.async { target.watcher?.scheduleFire() }
        }
    }

    private var stream: FSEventStreamRef?
    private var pending = false
    private let debounce: TimeInterval
    private let onChange: () -> Void

    init(debounce: TimeInterval = 0.25, onChange: @escaping () -> Void) {
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit { stop() }

    func watch(_ directories: [URL]) {
        stop()
        guard !directories.isEmpty else { return }

        let paths = directories.map { $0.path } as CFArray
        let sink = EventSink(self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<EventSink>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<EventSink>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            Unmanaged<EventSink>.fromOpaque(info).takeUnretainedValue().fire()
        }
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(created, Self.eventQueue)
        FSEventStreamStart(created)
        self.stream = created
    }

    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            // The stream gives its descriptors back on its queue; wait for that.
            // Nothing running there waits for the main thread, so this cannot block.
            Self.eventQueue.sync {}
        }
        stream = nil
    }

    /// On the main queue.
    private func scheduleFire() {
        if pending { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self = self else { return }
            self.pending = false
            self.onChange()
        }
    }
}
