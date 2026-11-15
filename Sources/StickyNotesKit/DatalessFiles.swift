import Foundation

/// Files that iCloud Drive keeps in the cloud and not on disk ("dataless"), as
/// "Optimize Mac Storage" does to files that have not been opened for a while.
/// The file is listed and has a size, but reading it makes the system fetch it
/// first, and the reader waits for the download. On the main thread that is a
/// frozen app.
public enum DatalessFiles {
    /// `SF_DATALESS` in `<sys/stat.h>`, which Swift does not import.
    private static let datalessFlag: UInt32 = 0x4000_0000

    /// Whether the file at `url` is dataless. Looks at the file's flags only, which
    /// does not fetch it. False for a file that is not there.
    static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & datalessFlag != 0
    }

    private static let downloadQueue = DispatchQueue(label: "StickyNotes.Downloads", qos: .utility)

    /// Ask iCloud to download `url`, from a queue of its own: the call goes to
    /// iCloud's daemon, which may take a long time to answer. A file that is not in
    /// iCloud is not an error.
    static func startDownloading(_ url: URL) {
        downloadQueue.async { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
    }

    /// Whether a read failed because the file is dataless and this thread is not
    /// allowed to wait for the download (`refuseMaterializingOnThisThread`): the
    /// system answers `EDEADLK`, which Foundation reports as a read error that
    /// carries the POSIX error underneath.
    static func isNotMaterializedError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EDEADLK) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
            return isNotMaterializedError(underlying)
        }
        return false
    }

    /// Makes a read of a dataless file on the calling thread fail at once with
    /// `EDEADLK` instead of waiting for the download. A backstop: every reader
    /// checks `isDataless` first, so this only catches a file that went dataless
    /// between the check and the read, or a read nobody guarded.
    public static func refuseMaterializingOnThisThread() {
        _ = setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }
}

/// What one reader of files does about dataless ones: decides whether a file may
/// be read now, and asks iCloud for it once instead of on every look. Each store
/// and each daily note has its own, so a test can say which files are dataless
/// without touching another test's. Main thread only.
final class DatalessGuard {
    /// How long a request stands before a file that is still dataless is asked for
    /// again, in case the first request was lost.
    static let requestInterval: TimeInterval = 60

    var isDataless: (URL) -> Bool = DatalessFiles.isDataless
    var startDownload: (URL) -> Void = { DatalessFiles.startDownloading($0) }
    var now: () -> Date = Date.init
    /// How a file's bytes are read. A test makes it throw what a refused read of a
    /// dataless file throws.
    var readData: (URL) throws -> Data = { try Data(contentsOf: $0) }

    private var requested: [String: Date] = [:]

    /// The same file reaches us as `/var/...` and `/private/var/...`.
    private static func key(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    /// True when `url` must not be read now because it is dataless. The first time
    /// that is found for a file, its download is requested; a file that is found
    /// present is forgotten, so evicting it again starts over.
    func blocks(_ url: URL) -> Bool {
        guard isDataless(url) else {
            if !requested.isEmpty { requested.removeValue(forKey: Self.key(url)) }
            return false
        }
        request(url)
        return true
    }

    /// Ask for the download of a file found dataless, unless that was done
    /// recently.
    func request(_ url: URL) {
        let moment = now()
        let key = Self.key(url)
        if let before = requested[key], moment.timeIntervalSince(before) < Self.requestInterval { return }
        requested[key] = moment
        startDownload(url)
    }

    enum Read {
        case bytes(Data)
        /// Dataless: not read, and its download is asked for.
        case notDownloaded
        /// Missing, or unreadable for another reason.
        case unreadable

        var isNotDownloaded: Bool {
            if case .notDownloaded = self { return true }
            return false
        }
    }

    /// The bytes of the file at `url`, unless it is dataless. `beforeReading` runs
    /// only when the file is about to be read from disk.
    func read(_ url: URL, beforeReading: () -> Void = {}) -> Read {
        if blocks(url) { return .notDownloaded }
        beforeReading()
        let result = Self.classify(url, isDataless: { _ in false }, readData: readData)
        if case .notDownloaded = result { request(url) }
        return result
    }

    /// The bytes of a file, or why there are none, without asking for anything: for a
    /// reader that is not on the main thread, which hands a `.notDownloaded` result
    /// to the main thread to be asked for.
    static func classify(_ url: URL, isDataless: (URL) -> Bool, readData: (URL) throws -> Data) -> Read {
        if isDataless(url) { return .notDownloaded }
        do {
            return .bytes(try readData(url))
        } catch {
            return DatalessFiles.isNotMaterializedError(error) ? .notDownloaded : .unreadable
        }
    }

    /// The text of the file at `url`, or nil when it is dataless, missing or not UTF-8.
    func readText(_ url: URL) -> String? {
        guard case let .bytes(data) = read(url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether a download of `url` was asked for and the file has not been seen
    /// present since.
    func isWaiting(for url: URL) -> Bool { requested[Self.key(url)] != nil }
}
