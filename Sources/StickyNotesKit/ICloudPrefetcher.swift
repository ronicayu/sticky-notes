import Foundation

/// Eagerly pulls down dataless iCloud Drive files in the storage tree so that
/// cross-machine sync state is materialized — and visible to FSEvents — soon
/// after launch. iCloud Drive normally leaves remote-only files as zero-byte
/// placeholders until something accesses them, which means a note created on
/// Mac A wouldn't appear on Mac B until you happened to touch the file.
///
/// No-op when the storage root isn't inside iCloud Drive.
///
/// The query runs on a queue of its own and so do the downloads it asks for: with
/// hundreds of files, going through its results on the main thread is a freeze.
/// Each file is asked for once, and `onMaterialized` hears (on the main queue) of
/// files whose download has finished, not of every one asked for. The files under
/// `.trash` and the attachments are left alone: nobody is waiting for them.
///
/// `@unchecked Sendable`: `query` and `root` are touched on the main thread only,
/// and the tracker on `queue` only.
final class ICloudPrefetcher: @unchecked Sendable {
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private let onMaterialized: ([URL]) -> Void
    private let queue = OperationQueue()
    private var root: URL?
    private let tracker = Tracker()
    /// Asks iCloud for a file. A test replaces it.
    var startDownload: @Sendable (URL) -> Void = { DatalessFiles.startDownloading($0) }

    init(onMaterialized: @escaping ([URL]) -> Void) {
        self.onMaterialized = onMaterialized
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        queue.name = "StickyNotes.ICloudPrefetcher"
    }

    deinit { stop() }

    func start(at root: URL) {
        stop()
        guard isInICloud(root) else { return }
        self.root = root.standardizedFileURL

        let q = NSMetadataQuery()
        q.searchScopes = [root]
        q.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        q.notificationBatchingInterval = 0.5
        q.operationQueue = queue

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: queue) { [weak self] note in
                guard let self, let q = note.object as? NSMetadataQuery else { return }
                q.disableUpdates()
                var items: [NSMetadataItem] = []
                for index in 0..<q.resultCount {
                    if let item = q.result(at: index) as? NSMetadataItem { items.append(item) }
                }
                q.enableUpdates()
                self.look(at: items)
            },
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: queue) { [weak self] note in
                guard let self else { return }
                // Only what changed: going through every result on each update is
                // what made this cost more the larger the vault.
                var items: [NSMetadataItem] = []
                for key in [NSMetadataQueryUpdateAddedItemsKey, NSMetadataQueryUpdateChangedItemsKey] {
                    items += note.userInfo?[key] as? [NSMetadataItem] ?? []
                }
                self.look(at: items)
            }
        ]
        query = q
        q.start()
    }

    func stop() {
        if let q = query { q.stop() }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        query = nil
        root = nil
        let tracker = tracker
        queue.addOperation { tracker.forgetAll() }
    }

    /// On `queue`: ask for what is not on this Mac, once, and report what arrived.
    private func look(at items: [NSMetadataItem]) {
        var seen: [(url: URL, isCurrent: Bool)] = []
        for item in items {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            seen.append((url, status == NSMetadataUbiquitousItemDownloadingStatusCurrent))
        }
        let outcome = tracker.look(at: seen, under: rootPath)
        for url in outcome.toRequest { startDownload(url) }
        guard !outcome.arrived.isEmpty else { return }
        let done = UncheckedSendable(outcome.arrived)
        let report = UncheckedSendable(onMaterialized)
        DispatchQueue.main.async { report.value(done.value) }
    }

    /// `root`'s path, readable from `queue`. Set once, before the query starts.
    private var rootPath: String? { root?.path }

    /// Which files of the query's results to ask for, and which of those have since
    /// arrived. No threads here, so a test can drive it.
    final class Tracker: @unchecked Sendable {
        struct Outcome: Equatable {
            var toRequest: [URL] = []
            var arrived: [URL] = []
        }

        /// Paths a download was asked for, until the file is seen downloaded.
        private var requested = Set<String>()

        func forgetAll() { requested.removeAll() }

        func look(at items: [(url: URL, isCurrent: Bool)], under root: String?) -> Outcome {
            var outcome = Outcome()
            for (url, isCurrent) in items where Self.isWanted(url, under: root) {
                let path = url.path
                if isCurrent {
                    // Only a file that was asked for has "arrived"; one that was here all along has not.
                    if requested.remove(path) != nil { outcome.arrived.append(url) }
                } else if requested.insert(path).inserted {
                    outcome.toRequest.append(url)
                }
            }
            return outcome
        }

        /// Everything under the storage root but the trash and the attachments.
        static func isWanted(_ url: URL, under root: String?) -> Bool {
            guard let root else { return true }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { return true }
            let first = path.dropFirst(root.count + 1).split(separator: "/", maxSplits: 1).first.map(String.init)
            return first != ".trash" && first != Attachments.directoryName
        }
    }

    /// True for any path inside `~/Library/Mobile Documents`. That covers
    /// both regular iCloud Drive (`com~apple~CloudDocs`) and per-app
    /// containers like Obsidian's own iCloud sync
    /// (`iCloud~md~obsidian/<vault>/`).
    private func isInICloud(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard let home = fm.homeDirectoryForCurrentUser as URL? else { return false }
        let mobileDocs = home
            .appendingPathComponent("Library/Mobile Documents", isDirectory: true)
            .standardizedFileURL.path
        let target = url.standardizedFileURL.path
        return target == mobileDocs || target.hasPrefix(mobileDocs + "/")
    }
}
