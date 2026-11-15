import Foundation

/// What this process last wrote to each file, as the file looked right after: its
/// size, modification time and inode. The file watcher drops an event that the
/// system marks as our own write, but the mark can survive the merging of events:
/// another writer that changes the file in the same instant would be dropped with
/// it. An own-marked event is therefore dropped only when the file still looks as
/// we left it. A file that is gone is taken as our own move or removal.
final class OwnWriteLog: @unchecked Sendable {
    static let shared = OwnWriteLog()

    struct Stamp: Equatable {
        let size: Int64
        let seconds: Int
        let nanoseconds: Int
        let inode: UInt64
    }

    private let lock = NSLock()
    private var stamps: [String: Stamp] = [:]

    private static func stamp(ofPath path: String) -> Stamp? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Stamp(
            size: Int64(info.st_size), seconds: Int(info.st_mtimespec.tv_sec),
            nanoseconds: Int(info.st_mtimespec.tv_nsec), inode: UInt64(info.st_ino))
    }

    /// Call right after writing or moving a file in.
    func record(_ url: URL) {
        let path = url.resolvingSymlinksInPath().path
        guard let stamp = Self.stamp(ofPath: path) else { return }
        lock.lock()
        stamps[path] = stamp
        lock.unlock()
    }

    /// Whether an own-marked event for the file at `path` (as the file system
    /// reports it) is really about what this process wrote.
    func confirms(_ path: String) -> Bool {
        guard let now = Self.stamp(ofPath: path) else { return true }
        lock.lock()
        let written = stamps[path]
        lock.unlock()
        return written == now
    }
}
