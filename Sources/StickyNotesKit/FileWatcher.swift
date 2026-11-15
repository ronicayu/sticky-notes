import Foundation
import CoreServices

/// Watches one or more directories (recursively, including in-place file
/// content edits) via FSEvents and calls `onChange` (debounced) on the main
/// queue. Unlike a directory-level `DispatchSourceFileSystemObject`, this
/// fires when an external editor (Obsidian, an iCloud sync agent, etc.)
/// rewrites a `.md` inside the watched tree.
///
/// What this process writes itself is not reported: the stream marks the events
/// of our own writes, and they are dropped, since whoever wrote already knows.
/// What the report holds is the paths that changed, so the owner can look at
/// those and nothing else.
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

    /// What happened since the last report.
    struct Events: Equatable {
        /// Paths whose content, name or existence changed, by another process.
        var changed: Set<String> = []
        /// Paths where only the attributes changed: extended attributes, flags, owner.
        /// iCloud does that to a file after every write, and when a download ends.
        var metadataOnly: Set<String> = []
        /// The system lost track of what changed (dropped events, a moved root, a
        /// volume mounted): anything may have changed.
        var everything = false

        static let all = Events(everything: true)

        var isEmpty: Bool { changed.isEmpty && metadataOnly.isEmpty && !everything }

        mutating func merge(_ other: Events) {
            changed.formUnion(other.changed)
            metadataOnly.formUnion(other.metadataOnly)
            everything = everything || other.everything
        }
    }

    /// What one event says, from its path and flags.
    enum Verdict: Equatable {
        /// Our own write, or nothing a reader could see.
        case ignore
        case changed(String)
        case metadataOnly(String)
        case everything
    }

    /// Sorts one event. A flag that means the system lost track wins over every
    /// other, our own write included, because then the paths cannot be trusted.
    static func verdict(path: String, flags: UInt32) -> Verdict {
        let lostTrack = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
        if flags & UInt32(lostTrack) != 0 { return .everything }
        if flags & UInt32(kFSEventStreamEventFlagOwnEvent) != 0 { return .ignore }
        let content = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified
        if flags & UInt32(content) != 0 { return .changed(path) }
        let attributes = kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemInodeMetaMod
            | kFSEventStreamEventFlagItemFinderInfoMod | kFSEventStreamEventFlagItemChangeOwner
        return flags & UInt32(attributes) != 0 ? .metadataOnly(path) : .ignore
    }

    /// What the stream's callback reaches. The stream owns it (the context's retain
    /// and release), so the callback never touches the watcher itself: the watcher
    /// can then be released on the main thread whatever the stream is doing, and
    /// is only looked at, on the main queue, to start the debounce.
    private final class EventSink {
        private final class WeakWatcher: @unchecked Sendable {
            weak var watcher: FileWatcher?
        }
        private let target = WeakWatcher()
        private let accepts: (@Sendable (String) -> Bool)?
        private let confirmsOwnWrite: (@Sendable (String) -> Bool)?

        init(
            _ watcher: FileWatcher, accepts: (@Sendable (String) -> Bool)?,
            confirmsOwnWrite: (@Sendable (String) -> Bool)?
        ) {
            target.watcher = watcher
            self.accepts = accepts
            self.confirmsOwnWrite = confirmsOwnWrite
        }

        /// Called on the stream's queue.
        func receive(count: Int, paths: NSArray, flags: UnsafePointer<FSEventStreamEventFlags>) {
            var events = Events()
            for index in 0..<count {
                guard let path = paths[index] as? String else { continue }
                // The filter is about paths; "anything may have changed" has none.
                switch FileWatcher.verdict(path: path, flags: flags[index]) {
                case .ignore:
                    // Our own write, unless the file no longer looks as we left it.
                    if flags[index] & UInt32(kFSEventStreamEventFlagOwnEvent) != 0,
                       let confirmsOwnWrite, path.hasSuffix(".md"), !confirmsOwnWrite(path),
                       accepts?(path) ?? true {
                        events.changed.insert(path)
                    }
                case let .changed(path): if accepts?(path) ?? true { events.changed.insert(path) }
                case let .metadataOnly(path): if accepts?(path) ?? true { events.metadataOnly.insert(path) }
                case .everything: events.everything = true
                }
            }
            guard !events.isEmpty else { return }
            let target = target
            let found = events
            DispatchQueue.main.async { target.watcher?.absorb(found) }
        }
    }

    private var stream: FSEventStreamRef?
    private var pending = false
    private var gathered = Events()
    private let debounce: TimeInterval
    private let accepts: (@Sendable (String) -> Bool)?
    private let confirmsOwnWrite: (@Sendable (String) -> Bool)?
    private let onChange: (Events) -> Void

    /// `accepts` is asked, on the stream's queue, about each changed path, so a watcher
    /// on a folder that holds much else hears only about its own files.
    /// `confirmsOwnWrite` is asked about an event marked as our own write of a `.md`
    /// file, and says whether the file still looks as we left it; if not, the event is
    /// reported as another writer's.
    init(
        debounce: TimeInterval = 0.25, accepts: (@Sendable (String) -> Bool)? = nil,
        confirmsOwnWrite: (@Sendable (String) -> Bool)? = nil,
        onChange: @escaping (Events) -> Void
    ) {
        self.debounce = debounce
        self.accepts = accepts
        self.confirmsOwnWrite = confirmsOwnWrite
        self.onChange = onChange
    }

    convenience init(debounce: TimeInterval = 0.25, onChange: @escaping () -> Void) {
        self.init(debounce: debounce) { _ in onChange() }
    }

    deinit { stop() }

    func watch(_ directories: [URL]) {
        stop()
        guard !directories.isEmpty else { return }

        let paths = directories.map { $0.path } as CFArray
        let sink = EventSink(self, accepts: accepts, confirmsOwnWrite: confirmsOwnWrite)
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
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagMarkSelf |
            kFSEventStreamCreateFlagUseCFTypes
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
            guard let info = info else { return }
            let paths = unsafeBitCast(rawPaths, to: NSArray.self)
            Unmanaged<EventSink>.fromOpaque(info).takeUnretainedValue()
                .receive(count: count, paths: paths, flags: rawFlags)
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
    private func absorb(_ events: Events) {
        gathered.merge(events)
        if pending { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self = self else { return }
            self.pending = false
            let events = self.gathered
            self.gathered = Events()
            self.onChange(events)
        }
    }
}
