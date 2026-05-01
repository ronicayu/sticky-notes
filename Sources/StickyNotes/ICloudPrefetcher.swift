import Foundation

/// Eagerly pulls down dataless iCloud Drive files in the storage tree so that
/// cross-machine sync state is materialized — and visible to FSEvents — soon
/// after launch. iCloud Drive normally leaves remote-only files as zero-byte
/// placeholders until something accesses them, which means a note created on
/// Mac A wouldn't appear on Mac B until you happened to touch the file.
///
/// No-op when the storage root isn't inside iCloud Drive.
final class ICloudPrefetcher {
    private var query: NSMetadataQuery?
    private let onMaterialized: () -> Void

    init(onMaterialized: @escaping () -> Void) {
        self.onMaterialized = onMaterialized
    }

    deinit { stop() }

    func start(at root: URL) {
        stop()
        guard isInICloud(root) else { return }

        let q = NSMetadataQuery()
        q.searchScopes = [root]
        q.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        q.notificationBatchingInterval = 0.5
        q.operationQueue = .main

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGather(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: q
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: q
        )

        query = q
        q.start()
    }

    func stop() {
        if let q = query {
            q.stop()
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: q)
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: q)
        }
        query = nil
    }

    @objc private func handleGather(_ note: Notification) {
        guard let q = note.object as? NSMetadataQuery else { return }
        q.disableUpdates()
        requestDownloads(from: q)
        q.enableUpdates()
    }

    @objc private func handleUpdate(_ note: Notification) {
        guard let q = note.object as? NSMetadataQuery else { return }
        requestDownloads(from: q)
    }

    private func requestDownloads(from q: NSMetadataQuery) {
        var triggered = false
        for i in 0..<q.resultCount {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            if status == NSMetadataUbiquitousItemDownloadingStatusCurrent { continue }
            do {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                triggered = true
            } catch {
                // Best-effort: if iCloud refuses (e.g. not yet ubiquitous),
                // FSEvents will still pick up the file once it materializes
                // through normal sync.
            }
        }
        if triggered {
            // FSEvents will fire naturally as files land — this nudge just
            // covers the case where the materialized content matches what's
            // already on disk and no event is emitted.
            DispatchQueue.main.async { [weak self] in self?.onMaterialized() }
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
