import Foundation
import CoreServices

/// Watches one or more directories (recursively, including in-place file
/// content edits) via FSEvents and calls `onChange` (debounced) on the main
/// queue. Unlike a directory-level `DispatchSourceFileSystemObject`, this
/// fires when an external editor (Obsidian, an iCloud sync agent, etc.)
/// rewrites a `.md` / `.json` inside the watched tree.
final class FileWatcher {
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
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.scheduleFire()
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
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
        self.stream = created
    }

    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    private func scheduleFire() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.pending { return }
            self.pending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + self.debounce) { [weak self] in
                guard let self = self else { return }
                self.pending = false
                self.onChange()
            }
        }
    }
}
