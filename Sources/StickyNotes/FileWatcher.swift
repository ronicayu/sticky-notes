import Foundation

/// Watches one or more directories for any file system change and calls
/// `onChange` (debounced) on the main queue.
final class FileWatcher {
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
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
        for dir in directories {
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .extend, .attrib],
                queue: DispatchQueue.main
            )
            source.setEventHandler { [weak self] in
                self?.scheduleFire()
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources[dir] = source
        }
    }

    func stop() {
        for source in sources.values { source.cancel() }
        sources.removeAll()
    }

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
