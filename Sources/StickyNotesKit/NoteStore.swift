import CryptoKit
import Darwin
import Foundation

/// A write or move that failed twice, or a legacy file that could not be
/// converted. Surfaced to the user rather than swallowed — a full disk or a
/// revoked vault permission would otherwise look exactly like a note that
/// saved fine.
struct StorageFailure {
    enum Kind {
        /// A write or move did not land. A later write that lands clears it.
        case write
        /// A `.json` note could not be converted, or was converted without a
        /// sync copy that had not downloaded. It stays reported until a later
        /// conversion run finds nothing wrong.
        case migration
        /// A `.json` note appeared after launch, from a Mac still on an older
        /// version. It is left alone: converting it would take the file away
        /// from the Mac that is editing it.
        case olderVersion
    }

    let url: URL
    let error: Error
    let date: Date
    var kind: Kind = .write

    var fileName: String { url.lastPathComponent }
}

/// Why a legacy `.json` note was left unconverted.
enum MigrationError: LocalizedError {
    case unreadable
    case malformed(String)
    case unreadableConflictVersion
    case couldNotWrite(String)
    case readBackDiffers
    case couldNotSetAside
    case olderVersionFilesWaiting

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The file could not be read."
        case .malformed(let detail):
            return "The file is not a valid note (\(detail)). It was left where it is."
        case .unreadableConflictVersion:
            return "A sync conflict copy of this note had not downloaded when the note was converted. The note is shown without it; the old file and a list of the missing copies are in the .converted-json folder."
        case .couldNotWrite(let detail):
            return detail
        case .readBackDiffers:
            return "The Markdown file did not read back the same as the note. The original was kept."
        case .couldNotSetAside:
            return "The note was converted, but the old .json file could not be moved out of the notes folder."
        case .olderVersionFilesWaiting:
            return "Notes from an older version are waiting. Update Sticky Notes on your other Macs, then relaunch this one."
        }
    }
}

/// What a switch of storage carried over, for the one message the person sees.
struct StorageSwitchReport: Equatable {
    /// Active notes, archived notes and trashed notes now in the new root, new or merged.
    var notes = 0
    var archived = 0
    var trashed = 0
    /// Of those, the ones the new root already had.
    var merged = 0
    /// Attachment files copied, and how many of them were kept under another
    /// name because the new root held other bytes under theirs.
    var attachments = 0
    var attachmentsKeptBoth = 0
    /// Files that could not be read, such as ones still downloading from iCloud.
    var notReadable = 0
    var couldNotCopy = 0

    var isEmpty: Bool { self == StorageSwitchReport() }

    mutating func count(_ folder: NoteStore.Folder) {
        switch folder {
        case .active: notes += 1
        case .archive: archived += 1
        case .trash: trashed += 1
        }
    }
}

/// What one run of the JSON-to-Markdown conversion did.
struct MigrationReport {
    var migrated = 0
    var failures: [StorageFailure] = []
    /// Ids that two or more files in one folder shared; the extra files got new ids.
    var reassignedDuplicateIds = 0
}

/// The body hashes this process wrote to each file, oldest first, shared by
/// every `NoteStore` in the process (a second store on the same folder must
/// honour the first one's writes). iCloud can keep an earlier save from this
/// very process as a conflict version. While the file still holds our newest
/// write, such a version holds only text the user has since edited away, so
/// it is not a conflict. Any read that finds anything else ends the lineage:
/// from then on an older save of ours may hold the only copy of some text.
/// In memory only, so after a relaunch everything merges.
enum WriteLineage {
    private static let lock = NSLock()
    // Every access holds `lock`.
    nonisolated(unsafe) private static var hashes: [String: [String]] = [:]
    private static let limit = 1000

    static func record(_ hash: String, for key: String) {
        lock.lock(); defer { lock.unlock() }
        var list = hashes[key, default: []]
        list.append(hash)
        if list.count > limit { list.removeFirst(list.count - limit) }
        hashes[key] = list
    }

    /// True when `hash` is the most recent write recorded for `key`.
    static func isNewest(_ hash: String, for key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return hashes[key]?.last == hash
    }

    /// True when `hash` is anywhere in the lineage for `key`.
    static func contains(_ hash: String, for key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return hashes[key]?.contains(hash) ?? false
    }

    static func clear(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        hashes[key] = nil
    }

    /// What a relaunch does.
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        hashes = [:]
    }
}

/// A value handed to another queue that only that queue reads.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

final class NoteStore {
    static let didChange = Notification.Name("NoteStore.didChange")

    enum Folder { case active, archive, trash }

    /// What a `didChange` notification reports, so an observer can skip the
    /// disk reads that do not concern it. Delivered in `userInfo` under
    /// `changeKey`; the notification's object is the store that posted it.
    enum Change: Equatable {
        /// This store wrote the note. Memory already holds what is on disk.
        case saved(UUID)
        case moved(UUID, from: Folder, to: Folder)
        /// Unlinked rather than moved.
        case removed(UUID)
        /// A sweep rewrote these notes from other copies of them.
        case external(Set<UUID>)
        /// Anything may have changed: a file-system event, which names no
        /// note, or a switch to another folder.
        case reset
    }

    static let changeKey = "change"

    /// The change a `didChange` notification carries. A notification without
    /// one is a `.reset`: the observer must assume everything changed.
    static func change(in notification: Notification) -> Change {
        notification.userInfo?[changeKey] as? Change ?? .reset
    }

    /// Posted when `lastFailure` changes in either direction — a new failure,
    /// or a later write succeeding and clearing it.
    static let healthDidChange = Notification.Name("NoteStore.healthDidChange")

    /// The most recent unrecovered storage failure, or nil when writes are
    /// landing. Read by the menu bar to decide whether to show a warning.
    private(set) var lastFailure: StorageFailure?

    /// What the last conversion of legacy `.json` notes did, at launch or when
    /// the storage moved.
    private(set) var lastMigration = MigrationReport()

    private(set) var rootURL: URL
    private var watcher: FileWatcher?
    private let iso8601 = ISO8601DateFormatter()

    /// The filename is creation-timestamp based (not derivable from the UUID),
    /// so we need an in-memory map to relocate files for archive/restore/delete.
    /// Populated by every load + save.
    private var pathIndex: [UUID: URL] = [:]

    /// Ids we've seen on disk in this process. If a save() targets a known
    /// id whose active file has since vanished — an external agent or
    /// another machine deleted it — we bail instead of resurrecting it.
    /// Cleared in discardActive / deleteForever.
    private var knownIds = Set<UUID>()

    /// Ids a rescan has already proved are gone from the active folder, so a
    /// controller that keeps saving doesn't re-scan the tree every time.
    /// Cleared whenever the tree changes underneath us.
    private var confirmedDeletedIds = Set<UUID>()

    /// Decoded notes keyed by directory path. Without it every panel refresh,
    /// window reconcile, and `allLabels()` call re-reads and re-parses the
    /// whole tree — `allLabels()` alone read it twice.
    ///
    /// Dropped wholesale by `notifyChange()`, which runs for both our own
    /// writes and external ones. FSEvents reports changes per directory rather
    /// than per file, so a whole-tree rescan is the granularity we'd get
    /// anyway; the win is skipping the rescan while nothing is changing.
    ///
    /// Everything here is main-queue only: `FileWatcher` sets its FSEvents
    /// dispatch queue to main, so the invalidation and the reads that
    /// repopulate it can't interleave.
    private var cache: [String: [Note]] = [:]

    /// Directory paths whose `pathIndex` entries are known to be
    /// complete, because we've read every file in them. Lets a lookup miss be
    /// trusted instead of triggering another full scan — without it, saving
    /// the Nth note in a vault re-reads the other N-1 looking for an id that
    /// isn't there. Dropped alongside `cache` whenever the tree changes
    /// underneath us.
    private var indexedDirs: Set<String> = []

    var activeURL: URL { rootURL.appendingPathComponent("notes", isDirectory: true) }
    var archiveURL: URL { rootURL.appendingPathComponent("archive", isDirectory: true) }

    private static let fileExtension = "md"

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private let clock: AppClock

    /// No default root: a store that quietly opens the user's real storage is
    /// how a test ends up writing to it. Production gets its root from `Settings`.
    init(rootURL: URL, clock: AppClock = SystemClock()) {
        self.rootURL = rootURL
        self.clock = clock
        ensureDirectories()
        migrateJSONNotes()
        startWatching()
        purgeExpiredTrash()
    }

    /// Writes whatever is on disk over. For a note this process is creating, or
    /// one whose owner holds no fingerprint yet; an owner that has read the file
    /// saves with `save(_:expecting:)`, which cannot overwrite what it has not seen.
    @discardableResult
    func save(_ note: Note) -> SaveResult {
        save(note, expectation: .anything)
    }

    /// Compare-and-swap. `expected` is the fingerprint of the file the caller
    /// last read or wrote; nil means the caller is creating the note and expects
    /// no file. If the file differs, nothing is written and the result carries
    /// what is there. The check and the write are two steps with no lock between
    /// them, so a writer that lands inside that gap is still overwritten.
    func save(_ note: Note, expecting expected: Fingerprint?) -> SaveResult {
        save(note, expectation: expected.map(Expectation.fingerprint) ?? .nothing)
    }

    private enum Expectation {
        case anything
        case nothing
        case fingerprint(Fingerprint)
    }

    private func save(_ note: Note, expectation: Expectation) -> SaveResult {
        var expectsFile = false
        if case .fingerprint = expectation { expectsFile = true }
        if knownIds.contains(note.id) || expectsFile, existingURL(for: note.id, in: activeURL) == nil {
            // Seen before but no active file now — externally deleted (or
            // archived). Don't resurrect it here.
            //
            // Except the index can be stale in a way that looks identical:
            // an external tool renaming the file moves it out from under the
            // cached path while `indexedDirs` still says the directory is
            // fully known, which suppresses the scan that would find it under
            // its new name. Dropping the save there loses whatever the user
            // just typed, so pay for one rescan before believing it's gone.
            var found = false
            if !confirmedDeletedIds.contains(note.id) {
                switch rescanForId(note.id, in: activeURL) {
                case .found:
                    confirmedDeletedIds.remove(note.id)
                    found = true
                case .unknown:
                    // The folder could not be listed, or the file may be waiting
                    // in iCloud: nothing says the note is gone, and the text
                    // must stay with the caller.
                    return .failed(SaveError.locationUnknown)
                case .absent:
                    break
                }
            }
            if !found {
                // Really gone. Remember that, or every subsequent keystroke
                // pays for another full scan of the notes directory.
                confirmedDeletedIds.insert(note.id)
                pathIndex.removeValue(forKey: note.id)
                return .gone
            }
        }
        let url = existingURL(for: note.id, in: activeURL) ?? generateURL(for: note, in: activeURL)
        let result = writeIfUnchanged(note, to: url, expecting: expectation)
        switch result {
        case .saved:
            pathIndex[note.id] = url
            knownIds.insert(note.id)

            // A save touches exactly one known file, so patch the cache rather
            // than dropping it. Debounced saves fire on every keystroke; throwing
            // the tree away each time would make the cache useless while typing.
            upsertInCache(note, dir: activeURL)
            notifyObservers(.saved(note.id))
        case let .conflict(onDisk, _):
            upsertInCache(onDisk, dir: activeURL)
        case .gone, .failed:
            break
        }
        return result
    }

    /// Check the file at `url` against `expectation`, then write. A file that
    /// cannot be read is not overwritten: nothing is known about what it holds.
    private func writeIfUnchanged(_ note: Note, to url: URL, expecting expectation: Expectation) -> SaveResult {
        switch expectation {
        case .anything:
            break
        case .nothing, .fingerprint:
            if FileManager.default.fileExists(atPath: url.path) {
                guard let current = readMainSnapshot(url) else { return .failed(SaveError.unreadableOnDisk) }
                if case let .fingerprint(expected) = expectation, current.fingerprint == expected {
                    break
                }
                return .conflict(onDisk: current.note, fingerprint: current.fingerprint)
            } else if case .fingerprint = expectation {
                return .gone
            }
        }
        switch writeReporting(note, to: url) {
        case let .success(fingerprint): return .saved(fingerprint)
        case let .failure(error): return .failed(error)
        }
    }

    /// A note and the fingerprint of the file it came from, read from disk now.
    /// This, not `loadNote`, is what a document takes its fingerprint from.
    func snapshot(id: UUID, archived: Bool = false) -> NoteSnapshot? {
        let dir = archived ? archiveURL : activeURL
        guard let url = existingURL(for: id, in: dir) else { return nil }
        return readMainSnapshot(url)
    }

    /// Where a note's file is now, read from disk. Used when a save finds the
    /// active file gone, to put the text where the note went.
    enum Whereabouts {
        case active(NoteSnapshot)
        case archived(NoteSnapshot)
        case trashed(NoteSnapshot)
        /// Every folder was listed and none holds the note.
        case missing
        /// A folder could not be listed or the note's file could not be read, so
        /// the note may still exist.
        case unknown
    }

    func whereIs(id: UUID) -> Whereabouts {
        var unknown = false
        for folder in [Folder.active, .archive, .trash] {
            let dir = directory(of: folder)
            switch rescanForId(id, in: dir) {
            case let .found(url):
                guard let snapshot = readMainSnapshot(url) else { unknown = true; continue }
                switch folder {
                case .active: return .active(snapshot)
                case .archive: return .archived(snapshot)
                case .trash: return .trashed(snapshot)
                }
            case .unknown:
                unknown = true
            case .absent:
                break
            }
        }
        // A note renamed on another Mac and still downloading is listed under a
        // name that carries nothing of this note, so it can only be told from a
        // deleted one by a placeholder being there at all.
        return unknown || holdsICloudPlaceholder() ? .unknown : .missing
    }

    private func holdsICloudPlaceholder() -> Bool {
        [activeURL, archiveURL, trashURL].contains { dir in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return names.contains { $0.hasPrefix(".") && $0.hasSuffix(".icloud") }
        }
    }

    private func directory(of folder: Folder) -> URL {
        switch folder {
        case .active: return activeURL
        case .archive: return archiveURL
        case .trash: return trashURL
        }
    }

    /// Compare-and-swap into the archive or the trash: for text typed into a
    /// note that was archived or deleted from under the window. Writes only if
    /// the file there still has the bytes `fingerprint` was taken from.
    func save(_ note: Note, in folder: Folder, expecting fingerprint: Fingerprint) -> SaveResult {
        guard folder != .active else { return save(note, expecting: fingerprint) }
        guard let url = existingURL(for: note.id, in: directory(of: folder)) else { return .gone }
        let result = writeIfUnchanged(note, to: url, expecting: .fingerprint(fingerprint))
        if case .saved = result {
            // The trash keeps a file for 30 days from its deletion date. An atomic
            // write may or may not give the file a new "date added", so say it.
            if folder == .trash { stampDeletionDate(on: url) }
            notifyChange(.reset)
        }
        return result
    }

    /// A copy of a note whose file is gone, written to `.trash/` under a new id,
    /// so it shows in the Trash tab and is never mistaken for the original.
    /// Rewritten in place when the same note is recovered again.
    func saveRecoveredCopy(of note: Note) -> Bool {
        var copy = Note(
            id: Self.recoveredCopyId(for: note.id), title: note.title, content: note.content,
            width: note.width, height: note.height,
            color: note.color, labels: note.labels, floatLevel: note.floatLevel,
            createdAt: note.createdAt, updatedAt: note.updatedAt
        )
        copy.preserved = note.preserved
        let url = existingURL(for: copy.id, in: trashURL) ?? {
            let stamp = NoteStore.filenameFormatter.string(from: clock.now())
            return trashURL.appendingPathComponent("recovered-\(note.id.uuidString)-\(stamp).\(NoteStore.fileExtension)")
        }()
        try? FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        guard write(copy, to: url) else { return false }
        stampDeletionDate(on: url)
        pathIndex[copy.id] = url
        notifyChange(.reset)
        return true
    }

    private static func recoveredCopyId(for id: UUID) -> UUID {
        var digest = SHA256()
        digest.update(data: Data("recovered-copy:\(id.uuidString)".utf8))
        var bytes = Array(digest.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func loadActive() -> [Note] {
        loadAll(from: activeURL) ?? []
    }

    /// The active notes, or nil when the folder cannot be listed (a revoked
    /// permission, a drive that is away). `loadActive` answers `[]` for both
    /// that and an empty folder; a caller that closes things because a note is
    /// missing has to tell them apart.
    func listActive() -> [Note]? {
        loadAll(from: activeURL)
    }

    func loadArchived() -> [Note] {
        (loadAll(from: archiveURL) ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Served from the cache while it is warm, which costs no disk read. A cold
    /// cache reads just the one file and does not warm it; `loadActive` does.
    /// Either way the answer can be older than the file by the watcher's delay;
    /// a caller that is about to write must use `snapshot` or
    /// `save(_:expecting:)`, which look at the file itself.
    func loadNote(id: UUID, archived: Bool = false) -> Note? {
        let dir = archived ? archiveURL : activeURL
        if let cached = cache[dirKey(dir)] {
            // Last match: a directory scan lets the last file with an id win the path index.
            return cached.last { $0.id == id }
        }
        guard let url = existingURL(for: id, in: dir) else { return nil }
        return readMain(url)
    }

    func archive(_ note: Note) {
        guard let from = existingURL(for: note.id, in: activeURL) else { return }
        let to = generateURL(for: note, in: archiveURL)
        guard moveFile(from: from, to: to) else { return }
        pathIndex[note.id] = to
        notifyChange(.moved(note.id, from: .active, to: .archive))
    }

    /// Remove a note the person threw away empty. The file goes to `.trash/`
    /// rather than being unlinked: "empty" is judged from what the window shows,
    /// and the file may hold more than that.
    func discardActive(_ note: Note) {
        var change = Change.removed(note.id)
        if let url = existingURL(for: note.id, in: activeURL) {
            let destination = uniqueTrashURL(for: url)
            if moveFile(from: url, to: destination) {
                stampDeletionDate(on: destination)
                change = .moved(note.id, from: .active, to: .trash)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        pathIndex.removeValue(forKey: note.id)
        knownIds.remove(note.id)
        notifyChange(change)
    }

    func restore(_ note: Note) {
        guard let from = existingURL(for: note.id, in: archiveURL) else { return }
        let to = generateURL(for: note, in: activeURL)
        guard moveFile(from: from, to: to) else { return }
        pathIndex[note.id] = to
        notifyChange(.moved(note.id, from: .archive, to: .active))
    }

    /// Union of every label across active + archived notes, normalized and
     /// sorted alphabetically. Used by autocomplete + the chrome label menu.
    func allLabels() -> [String] {
        var seen = Set<String>()
        for note in loadActive() { seen.formUnion(note.labels) }
        for note in loadArchived() { seen.formUnion(note.labels) }
        return seen.sorted()
    }

    /// "Delete permanently" moves the file to `.trash/` instead of unlinking
    /// it. The panel calls this from a confirmation sheet, but a confirmation
    /// sheet is a poor last line of defence for something irreversible —
    /// files stay recoverable for `trashRetention` and are swept on launch.
    func deleteForever(_ note: Note) {
        var change = Change.removed(note.id)
        if let url = existingURL(for: note.id, in: archiveURL) {
            let destination = uniqueTrashURL(for: url)
            if moveFile(from: url, to: destination) {
                stampDeletionDate(on: destination)
                change = .moved(note.id, from: .archive, to: .trash)
            } else {
                // Couldn't reach the trash — fall back to removing it, since
                // the user asked for the note to be gone.
                try? FileManager.default.removeItem(at: url)
            }
        }
        pathIndex.removeValue(forKey: note.id)
        knownIds.remove(note.id)
        notifyChange(change)
    }

    /// How long a deleted note stays recoverable.
    static let trashRetention: TimeInterval = 30 * 24 * 60 * 60

    var trashURL: URL { rootURL.appendingPathComponent(".trash", isDirectory: true) }

    /// Where a converted `.json` note, and a `.md` file merged into another, is
    /// set aside. Outside `notes/`, `archive/` and `.trash/`, so no version of
    /// the app loads it, and never deleted: a Mac still on the old version may
    /// have edited the file after it was read, and nothing else holds that edit.
    var convertedJSONURL: URL { rootURL.appendingPathComponent(".converted-json", isDirectory: true) }

    /// Notes sitting in the trash, newest first.
    func loadTrashed() -> [Note] {
        (loadAll(from: trashURL) ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Put a trashed note back in the archive, where deleting it came from.
    func restoreFromTrash(_ note: Note) {
        guard let from = existingURL(for: note.id, in: trashURL) else { return }
        let to = generateURL(for: note, in: archiveURL)
        guard moveFile(from: from, to: to) else { return }
        pathIndex[note.id] = to
        notifyChange(.moved(note.id, from: .trash, to: .archive))
    }

    /// Moving a file preserves its modification date, so a note last edited
    /// months ago would land in the trash already expired. Retention has to
    /// run from the deletion, so record that as the file's modification date.
    private func stampDeletionDate(on url: URL, at date: Date? = nil) {
        let when = date ?? clock.now()
        // Retention counts from the later of the two dates, and a file that was
        // just written entered its folder just now. A switch of storage carries
        // the original deletion date over, so the arrival date is set as well,
        // where the file system lets it be set.
        if date != nil { NoteStore.setArrivalDate(when, on: url) }
        try? FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
    }

    private static func setArrivalDate(_ date: Date, on url: URL) {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)
        var value = timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)
        _ = setattrlist(url.path, &list, &value, MemoryLayout<timespec>.size, 0)
    }

    /// Delete trashed files older than `trashRetention`. Called at launch;
    /// deliberately conservative, since the whole point is not losing things.
    @discardableResult
    func purgeExpiredTrash(now explicitNow: Date? = nil) -> Int {
        let now = explicitNow ?? clock.now()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: trashURL,
            includingPropertiesForKeys: NoteStore.retentionKeys
        ) else { return 0 }

        var removed = 0
        for url in files where url.pathExtension == NoteStore.fileExtension {
            guard let deleted = NoteStore.deletionDate(of: url) else { continue }
            guard now.timeIntervalSince(deleted) > NoteStore.trashRetention else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        if removed > 0 { notifyChange(.reset) }
        return removed
    }

    private static let retentionKeys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]

    /// When a trashed file was deleted. When the file entered the trash is the
    /// only date that reflects the deletion; the modification date is a stamped
    /// fallback for filesystems that don't report it.
    private static func deletionDate(of url: URL) -> Date? {
        guard let values = try? url.resourceValues(forKeys: Set(retentionKeys)) else { return nil }
        // The later of the two: the move into the trash sets the first, and a
        // write into a trashed file stamps the second.
        return [values.addedToDirectoryDate, values.contentModificationDate].compactMap { $0 }.max()
    }

    /// Trash filenames can collide with an earlier deletion of a note created
    /// in the same second, and the trash is the one place we must not
    /// overwrite anything.
    private func uniqueTrashURL(for source: URL) -> URL {
        try? FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = trashURL.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = trashURL.appendingPathComponent("\(base)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// Switch to a new root and carry everything over: the active and archived
    /// notes, the trash with each note's deletion date, and the attachments, whose
    /// links are changed in the copied notes where a file had to take another name.
    /// Nothing the new root already holds is overwritten: a note it has is merged
    /// with, and an attachment with the same name and other bytes is kept beside
    /// the new one. Nothing in the old root is changed or deleted, so it stays a
    /// backup. A note the new root holds in another folder goes where the more
    /// recently placed of the two copies is, so an archive made on either root
    /// holds when the person comes back.
    @discardableResult
    func reconfigure(rootURL newRoot: URL) -> StorageSwitchReport {
        var report = StorageSwitchReport()
        guard dirKey(newRoot) != dirKey(rootURL) else { return report }

        // Before anything is read: an event from the root being left must not
        // run a sweep or a reload while it is being copied from.
        watcher?.stop()
        watcher = nil
        storageGeneration += 1
        invalidateCache()

        // Heals duplicate ids the way every load does, so each note is copied once.
        for dir in [activeURL, archiveURL, trashURL] { _ = loadAll(from: dir) }
        let source = switchSource(report: &report)
        let oldAttachments = attachmentsURL
        var records = loadSwitchRecords()
        let leftKey = dirKey(rootURL)
        let sinceArrival = records[leftKey] ?? [:]
        // What this root holds as it is left: if it still does when the person
        // comes back, nobody has touched it in between.
        records[leftKey] = Dictionary(
            source.map { ($0.note.id.uuidString, NoteStore.signature($0.note, $0.folder)) }, uniquingKeysWith: { first, _ in first })

        rootURL = newRoot
        pathIndex.removeAll()
        // What was known about the folders of the root just left, and of this one
        // when it was last used, says nothing about what is in them now.
        invalidateCache()
        ensureDirectories()
        awaitDownloads(in: newRoot)
        migrateJSONNotes()

        let links = copyAttachments(from: oldAttachments, report: &report)
        var destination = switchDestination()
        let sinceDeparture = records[dirKey(newRoot)] ?? [:]
        for entry in source {
            place(entry, rewritingLinksWith: links, into: &destination, report: &report,
                  unchangedSinceArrival: sinceArrival[entry.note.id.uuidString] == NoteStore.signature(entry.note, entry.folder),
                  sinceDeparture: sinceDeparture)
        }
        records[dirKey(newRoot)] = switchDestination().copies.reduce(into: [:]) { result, pair in
            if let note = pair.value.lazy.compactMap({ self.readMain($0.url) }).first, let copy = pair.value.first {
                result[pair.key.uuidString] = NoteStore.signature(note, copy.folder)
            }
        }
        saveSwitchRecords(records)

        startWatching()
        notifyChange(.reset)
        // The sweep that was waiting on the root just left is gone; the new one has its own.
        let sweep = UncheckedSendable { [weak self] in self?.resolveConflictsInBackground() }
        DispatchQueue.main.async { sweep.value() }
        return report
    }

    // MARK: - What a root held when it was left

    /// Where a switch remembers what each root held when it was left, so that
    /// coming back can tell a note nobody touched from one that was changed.
    /// Outside every storage root; nil keeps the records in memory only.
    var switchRecordsURL: URL?
    private var switchRecordsCache: [String: [String: String]]?

    private func loadSwitchRecords() -> [String: [String: String]] {
        if let switchRecordsCache { return switchRecordsCache }
        let loaded = switchRecordsURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: $0) } ?? [:]
        switchRecordsCache = loaded
        return loaded
    }

    private func saveSwitchRecords(_ records: [String: [String: String]]) {
        switchRecordsCache = records
        guard let url = switchRecordsURL, let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The text, title and labels of a note and the folder it is in.
    private static func signature(_ note: Note, _ folder: Folder) -> String {
        let name: String
        switch folder {
        case .active: name = "active"
        case .archive: name = "archive"
        case .trash: name = "trash"
        }
        return "\(name):\(contentHash(note))"
    }

    // MARK: - Files not downloaded yet

    /// How long a switch waits for files of the new root that are still in iCloud
    /// before it goes on without them.
    var downloadWait: TimeInterval = 5

    /// Ask for every placeholder in the new root, and wait a bounded time for them.
    /// What stays undownloaded is handled by name; see `switchDestination`.
    private func awaitDownloads(in root: URL) {
        let fm = FileManager.default
        func placeholders() -> [URL] {
            var found: [URL] = []
            for sub in ["notes", "archive", ".trash", Attachments.directoryName] {
                guard let walker = fm.enumerator(at: root.appendingPathComponent(sub, isDirectory: true), includingPropertiesForKeys: nil)
                else { continue }
                for case let url as URL in walker where NoteStore.isICloudPlaceholder(url) {
                    found.append(url.deletingLastPathComponent().appendingPathComponent(NoteStore.name(ofPlaceholder: url)))
                }
            }
            return found
        }
        var waiting = placeholders()
        guard !waiting.isEmpty else { return }
        for url in waiting { try? fm.startDownloadingUbiquitousItem(at: url) }
        let deadline = Date().addingTimeInterval(downloadWait)
        while Date() < deadline {
            waiting = waiting.filter { !fm.fileExists(atPath: $0.path) }
            if waiting.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// `.name.icloud` stands for `name`.
    private static func name(ofPlaceholder url: URL) -> String {
        String(url.deletingPathExtension().lastPathComponent.dropFirst())
    }

    private var attachmentsURL: URL { rootURL.appendingPathComponent(Attachments.directoryName, isDirectory: true) }

    private struct SwitchEntry {
        let note: Note
        let folder: Folder
        let url: URL
        /// When the file got where it is: the later of its modification and its
        /// arrival in the folder, which is the deletion date in the trash.
        let placed: Date
    }

    private struct DestinationCopy {
        let folder: Folder
        var url: URL
    }

    private func switchSource(report: inout StorageSwitchReport) -> [SwitchEntry] {
        var entries: [SwitchEntry] = []
        for folder in [Folder.active, .archive, .trash] {
            let files = ((try? FileManager.default.contentsOfDirectory(at: directory(of: folder), includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for url in files {
                if url.pathExtension == NoteStore.fileExtension {
                    guard let note = readMain(url) else { report.notReadable += 1; continue }
                    entries.append(SwitchEntry(
                        note: note, folder: folder, url: url, placed: NoteStore.deletionDate(of: url) ?? .distantPast))
                } else if NoteStore.isICloudPlaceholder(url) {
                    report.notReadable += 1
                }
            }
        }
        return entries
    }

    /// What the new root holds. A file that cannot be read, or a placeholder that
    /// has not downloaded, may be any note: it is kept by name, not forgotten.
    private func switchDestination() -> (copies: [UUID: [DestinationCopy]], unreadable: Set<String>) {
        var copies: [UUID: [DestinationCopy]] = [:]
        var unreadable = Set<String>()
        for folder in [Folder.active, .archive, .trash] {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory(of: folder), includingPropertiesForKeys: nil)) ?? []
            for url in files {
                if url.pathExtension == NoteStore.fileExtension {
                    if let note = readMain(url) {
                        copies[note.id, default: []].append(DestinationCopy(folder: folder, url: url))
                    } else {
                        unreadable.insert(url.lastPathComponent)
                    }
                } else if NoteStore.isICloudPlaceholder(url) {
                    unreadable.insert(NoteStore.name(ofPlaceholder: url))
                }
            }
        }
        return (copies, unreadable)
    }

    private static func isICloudPlaceholder(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(".") && url.pathExtension == "icloud"
    }

    /// Put one note of the old root in the new one.
    ///
    /// `unchangedSinceArrival`: the old root's file is what the switch left in it
    /// (or what the last switch away from it recorded), so it holds nothing the
    /// new root lacks. `sinceDeparture`: what the new root held when it was left.
    private func place(
        _ entry: SwitchEntry,
        rewritingLinksWith links: [String: String],
        into destination: inout (copies: [UUID: [DestinationCopy]], unreadable: Set<String>),
        report: inout StorageSwitchReport,
        unchangedSinceArrival: Bool,
        sinceDeparture: [String: String]
    ) {
        // Retention runs from the deletion; one past it would be purged on the next launch.
        if entry.folder == .trash, isExpiredInTrash(entry.url) { return }
        // The new root may already hold this note in a file that is not here yet.
        // Nothing is lost by leaving it: the old root keeps its copy.
        if NoteStore.couldBeUnreadableFile(of: entry, among: destination.unreadable) {
            report.notReadable += 1
            return
        }
        var note = entry.note
        if !links.isEmpty { note.content = NoteStore.rewritingAttachmentLinks(in: note.content, using: links) }

        let copies = destination.copies[note.id] ?? []
        var folder = entry.folder
        var target = copies.first { $0.folder == folder }
        let primary = target ?? copies.max(by: { placedDate(of: $0.url) < placedDate(of: $1.url) })

        if let primary, let held = readMain(primary.url) {
            if unchangedSinceArrival {
                // Nothing here the new root does not already have.
                report.count(primary.folder)
                return
            }
            if sinceDeparture[note.id.uuidString] == NoteStore.signature(held, primary.folder) {
                // Only the old root changed it: its version replaces the other, whole.
                var url = primary.url
                if primary.folder != folder {
                    let to = NoteStore.unusedURL(directory(of: folder).appendingPathComponent(primary.url.lastPathComponent))
                    guard moveFile(from: primary.url, to: to) else { report.couldNotCopy += 1; return }
                    url = to
                    destination.copies[note.id] = copies.filter { $0.url != primary.url } + [DestinationCopy(folder: folder, url: to)]
                }
                if !replaceWhole(of: url, with: note, placed: entry.placed, folder: folder) {
                    mergeCopy(of: note, into: url, placed: entry.placed, folder: folder)
                }
                report.count(folder)
                return
            }
        }

        // Both roots changed it, or nothing says which did.
        if target == nil, let other = primary {
            if entry.placed >= placedDate(of: other.url) {
                // The old root moved it last: the new root's copy follows.
                let to = NoteStore.unusedURL(directory(of: folder).appendingPathComponent(other.url.lastPathComponent))
                if moveFile(from: other.url, to: to) {
                    if folder == .trash { stampDeletionDate(on: to, at: entry.placed) }
                    target = DestinationCopy(folder: folder, url: to)
                    destination.copies[note.id] = copies.filter { $0.url != other.url } + [target!]
                }
            } else {
                target = other
                folder = other.folder
            }
        }

        if let target {
            mergeCopy(of: note, into: target.url, placed: entry.placed, folder: folder)
            report.merged += 1
        } else {
            let url = NoteStore.unusedURL(directory(of: folder).appendingPathComponent(entry.url.lastPathComponent))
            guard write(note, to: url) else { report.couldNotCopy += 1; return }
            if folder == .trash { stampDeletionDate(on: url, at: entry.placed) }
            pathIndex[note.id] = url
            destination.copies[note.id, default: []].append(DestinationCopy(folder: folder, url: url))
        }
        report.count(folder)
    }

    /// Whether a file of the new root that could not be read may be the file of `entry`'s
    /// note: it has the name a switch gives a copy, or carries the id as a generated name does.
    private static func couldBeUnreadableFile(of entry: SwitchEntry, among names: Set<String>) -> Bool {
        guard !names.isEmpty else { return false }
        if names.contains(entry.url.lastPathComponent) { return true }
        return names.contains { nameCarriesId($0, entry.note.id) }
    }

    private func placedDate(of url: URL) -> Date {
        NoteStore.deletionDate(of: url) ?? .distantPast
    }

    /// Write `note` over the file at `url` as it is, keeping that file's own frontmatter.
    private func replaceWhole(of url: URL, with note: Note, placed: Date, folder: Folder) -> Bool {
        guard let onDisk = readSnapshot(url) else { return false }
        var whole = note
        whole.preserved = onDisk.note.preserved
        if renderMarkdown(whole) != renderMarkdown(onDisk.note) {
            guard case .saved = writeIfUnchanged(whole, to: url, expecting: .fingerprint(onDisk.fingerprint)) else { return false }
        }
        if folder == .trash { stampDeletionDate(on: url, at: placed) }
        pathIndex[note.id] = url
        return true
    }

    /// Merge `note` into the file already at `existing`: written over only if the
    /// file is still what was read, and the file's own frontmatter stays as it is.
    private func mergeCopy(of note: Note, into existing: URL, placed: Date, folder: Folder) {
        let heldSince = NoteStore.deletionDate(of: existing)
        // Sync conflict versions of the file hold text it lacks.
        _ = resolveConflict(at: existing)
        for _ in 0..<2 {
            guard let onDisk = readSnapshot(existing) else { return }
            var merged = ConflictResolver.merge([onDisk.note, note], now: clock.now()) ?? note
            merged.preserved = onDisk.note.preserved
            guard renderMarkdown(merged) != renderMarkdown(onDisk.note) else { break }
            if case .saved = writeIfUnchanged(merged, to: existing, expecting: .fingerprint(onDisk.fingerprint)) { break }
        }
        if folder == .trash {
            stampDeletionDate(on: existing, at: max(heldSince ?? .distantPast, placed))
        }
        if let id = readSnapshot(existing)?.note.id { pathIndex[id] = existing }
    }

    // MARK: - Attachments in a switch

    /// Copy every file of `source` (the old root's attachments folder) into the new
    /// root's, and return how links must change: the old relative path to the new
    /// one, for each file that is not at the same path in the new root. A file
    /// whose bytes the new root already holds, under any name, is not copied again
    /// and links point at the copy there. One whose name is taken by other bytes
    /// is kept under a free name, so neither is lost.
    private func copyAttachments(from source: URL, report: inout StorageSwitchReport) -> [String: String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return [:]
        }
        let sourceBase = source.resolvingSymlinksInPath().path
        let destinationDir = attachmentsURL
        let destinationBase = destinationDir.resolvingSymlinksInPath().path
        func relativePath(_ url: URL, under base: String) -> String {
            String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1))
        }

        // Names the new root holds but whose bytes are not here yet: taken, though they cannot be compared.
        var taken = Set<String>()
        var bySize: [Int: [String]] = [:]
        if let existing = fm.enumerator(at: destinationDir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let url as URL in existing {
                if NoteStore.isICloudPlaceholder(url) {
                    let folder = relativePath(url.deletingLastPathComponent(), under: destinationBase)
                    taken.insert(folder.isEmpty ? NoteStore.name(ofPlaceholder: url)
                                 : folder + "/" + NoteStore.name(ofPlaceholder: url))
                    continue
                }
                guard !url.lastPathComponent.hasPrefix(".") else { continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                bySize[values?.fileSize ?? -1, default: []].append(relativePath(url, under: destinationBase))
            }
        }
        func isTaken(_ url: URL) -> Bool {
            fm.fileExists(atPath: url.path) || taken.contains(relativePath(url, under: destinationBase))
        }

        var links: [String: String] = [:]
        for case let url as URL in walker {
            if url.lastPathComponent.hasPrefix(".") {
                if NoteStore.isICloudPlaceholder(url) { report.notReadable += 1 }
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let relative = relativePath(url, under: sourceBase)
            let size = values?.fileSize ?? -1

            if let same = bySize[size]?.first(where: {
                fm.contentsEqual(atPath: destinationDir.appendingPathComponent($0).path, andPath: url.path)
            }) {
                if same != relative { links[relative] = same }
                continue
            }
            var target = relative
            var candidate = destinationDir.appendingPathComponent(relative)
            if isTaken(candidate) {
                let base = candidate.deletingPathExtension()
                var counter = 2
                repeat {
                    candidate = URL(fileURLWithPath: "\(base.path)-\(counter)").appendingPathExtension(candidate.pathExtension)
                    counter += 1
                } while isTaken(candidate)
                target = relativePath(candidate, under: destinationBase)
                report.attachmentsKeptBoth += 1
                links[relative] = target
            }
            do {
                try fm.createDirectory(at: candidate.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: url, to: candidate)
                report.attachments += 1
                bySize[size, default: []].append(target)
            } catch {
                report.couldNotCopy += 1
                links[relative] = nil
                if target != relative { report.attachmentsKeptBoth -= 1 }
            }
        }
        return links
    }

    /// `text` with each `../attachments/<path>` link whose path is a key of
    /// `links` pointing at the value. A link is matched as written and as the app
    /// writes it, with spaces and parentheses percent-escaped, and is rewritten in
    /// the same style.
    static func rewritingAttachmentLinks(in text: String, using links: [String: String]) -> String {
        let prefix = "../\(Attachments.directoryName)/"
        guard text.contains(prefix),
              let pattern = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: prefix) + "([^)>\"\\n]+)")
        else { return text }
        let nsText = text as NSString
        var result = ""
        var copiedUpTo = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let whole = match.range
            let reference = nsText.substring(with: match.range(at: 1))
            let name = reference.trimmingCharacters(in: .whitespaces)
            let trailing = String(reference.dropFirst(name.count))
            let replacement: String
            if let new = links[name] {
                replacement = new
            } else if let decoded = name.removingPercentEncoding, let new = links[decoded] {
                replacement = Attachments.linkDestination(new)
            } else {
                continue
            }
            result += nsText.substring(with: NSRange(location: copiedUpTo, length: whole.location - copiedUpTo))
            result += prefix + replacement + trailing
            copiedUpTo = whole.location + whole.length
        }
        return result + nsText.substring(from: copiedUpTo)
    }

    // MARK: - Internal

    /// Drop the cache before telling anyone, so observers that immediately
    /// call `loadActive()` read fresh data rather than what we just replaced.
    /// Used for changes that move or remove files, and for external changes
    /// reported by the watcher, where we can't know what else shifted.
    /// Canonical key for a directory.
    ///
    /// `contentsOfDirectory(at:)` hands back URLs with symlinks resolved, so a
    /// listed file's parent is `/private/var/…` while the directory we asked
    /// about is `/var/…`. Comparing or keying on raw paths makes those two
    /// look like different directories — which silently broke archive and
    /// restore for any storage path behind a symlink.
    private func dirKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func notifyChange(_ change: Change) {
        invalidateCache()
        notifyObservers(change)
    }

    private func invalidateCache() {
        cache.removeAll()
        indexedDirs.removeAll()
        // The file may be back — a rename, or a sync agent restoring it.
        confirmedDeletedIds.removeAll()
    }

    private func notifyObservers(_ change: Change) {
        NotificationCenter.default.post(
            name: NoteStore.didChange,
            object: self,
            userInfo: [NoteStore.changeKey: change]
        )
    }

    /// Replace-or-append a note in a warm cache. A cold cache is left cold —
    /// a single note is not a directory listing.
    private func upsertInCache(_ note: Note, dir: URL) {
        guard var notes = cache[dirKey(dir)] else { return }
        // The last match, the one `loadNote` answers with and a save writes to.
        if let index = notes.lastIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else {
            notes.append(note)
        }
        cache[dirKey(dir)] = notes
    }

    private func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: activeURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: archiveURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: trashURL, withIntermediateDirectories: true)
    }

    /// What the watcher does with an event. Internal so a test can stand in for
    /// the watcher without waiting for FSEvents.
    func handleFileSystemEvent() {
        resolveConflictsIfDue()
        noticeOlderVersionFiles()
        notifyChange(.reset)
    }

    /// A `.json` note that shows up after launch was written by a Mac still on an
    /// older version, or finished downloading late. It is not converted here: the
    /// Mac that wrote it may be editing it right now. Say so, so it is not a note
    /// that is silently missing.
    private func noticeOlderVersionFiles() {
        let fm = FileManager.default
        for dir in [activeURL, archiveURL, trashURL] {
            guard let name = (try? fm.contentsOfDirectory(atPath: dir.path))?
                .sorted().first(where: { $0.hasSuffix(".json") }) else { continue }
            if lastFailure?.kind == .olderVersion { return }
            guard lastFailure == nil || lastFailure?.kind == .migration else { return }
            lastFailure = StorageFailure(
                url: dir.appendingPathComponent(name), error: MigrationError.olderVersionFilesWaiting,
                date: clock.now(), kind: .olderVersion)
            NotificationCenter.default.post(name: NoteStore.healthDidChange, object: self)
            return
        }
        guard lastFailure?.kind == .olderVersion else { return }
        lastFailure = lastMigration.failures.last
        NotificationCenter.default.post(name: NoteStore.healthDidChange, object: self)
    }

    private func startWatching() {
        watcher = FileWatcher { [weak self] in
            guard let self = self else { return }
            // Conflict copies arrive as ordinary file changes. Merging only at
            // launch left the other Mac's edits invisible — and diverging
            // further — for the rest of the session.
            self.handleFileSystemEvent()
        }
        watcher?.watch([activeURL, archiveURL, trashURL])
    }

    /// Returns the on-disk URL for a note that already exists in the given
    /// directory, or nil if not found. Looks up the cached path and falls back
    /// to scanning the directory by frontmatter id.
    private func existingURL(for id: UUID, in dir: URL) -> URL? {
        if let cached = pathIndex[id], dirKey(cached.deletingLastPathComponent()) == dirKey(dir),
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        // The index covers this directory, so a miss is the answer — the
        // note isn't here. (The `fileExists` check above still catches an
        // entry whose file was deleted since we indexed it, which is what
        // keeps the no-resurrect guard working.)
        if indexedDirs.contains(dirKey(dir)) { return nil }
        // Cold index: scan and rebuild for this dir.
        return scanForId(id, in: dir).url
    }

    /// The two names a note's file is given: the creation time and the first six
    /// hex digits of its id, and, when another note's file already has that
    /// name, the creation time and the whole id.
    private static func fileNames(for note: Note) -> (short: String, long: String) {
        let stamp = filenameFormatter.string(from: note.createdAt)
        let hex = note.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return ("\(stamp)-\(hex.prefix(6)).\(fileExtension)", "\(stamp)-\(hex).\(fileExtension)")
    }

    /// Whether `name` is one a note with `id` could have been given.
    private static func nameCarriesId(_ name: String, _ id: UUID) -> Bool {
        let hex = id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return name.hasSuffix("-\(hex.prefix(6)).\(fileExtension)") || name.hasSuffix("-\(hex).\(fileExtension)")
    }

    /// Builds a fresh URL for a new save into the given directory. A name that
    /// another note's file already has is never reused: two notes made in the
    /// same second can share the first six digits of their ids, and the second
    /// would then meet the first one's file as if it were its own.
    private func generateURL(for note: Note, in dir: URL) -> URL {
        let names = NoteStore.fileNames(for: note)
        for name in [names.short, names.long] {
            let url = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) || readSnapshot(url)?.note.id == note.id {
                return url
            }
        }
        return NoteStore.unusedURL(dir.appendingPathComponent(names.long))
    }

    /// What a look through one folder for a note found.
    enum FileSearch {
        case found(URL)
        /// The folder was listed and holds no file of the note.
        case absent
        /// The folder could not be listed, or a file that may be the note's is
        /// unreadable or still in iCloud. Nothing can be said about the note.
        case unknown

        var url: URL? {
            if case let .found(url) = self { return url }
            return nil
        }
    }

    /// Read every file in `dir` to locate `id`, indexing all of them on the
    /// way so the next lookup here is free.
    /// A scan that ignores `indexedDirs`, for when the index is the thing
    /// we're suspicious of.
    private func rescanForId(_ id: UUID, in dir: URL) -> FileSearch {
        indexedDirs.remove(dirKey(dir))
        return scanForId(id, in: dir)
    }

    private func scanForId(_ id: UUID, in dir: URL) -> FileSearch {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return .unknown
        }
        var match: URL?
        var inconclusive = false
        for url in files {
            if url.pathExtension == NoteStore.fileExtension {
                guard let note = readMain(url) else {
                    if couldBeFile(of: id, named: url.lastPathComponent) { inconclusive = true }
                    continue
                }
                pathIndex[note.id] = url
                if note.id == id { match = url }
            } else if url.pathExtension == "icloud", url.lastPathComponent.hasPrefix(".") {
                // A file iCloud has not downloaded is listed as ".<name>.icloud".
                let name = String(url.deletingPathExtension().lastPathComponent.dropFirst())
                if couldBeFile(of: id, named: name) { inconclusive = true }
            }
        }
        if let match {
            indexedDirs.insert(dirKey(dir))
            return .found(match)
        }
        if inconclusive { return .unknown }
        indexedDirs.insert(dirKey(dir))
        return .absent
    }

    /// Whether a file that cannot be read may be this note's: it sits where the
    /// note was last seen, or carries the id in its name as `generateURL` writes it.
    private func couldBeFile(of id: UUID, named name: String) -> Bool {
        if pathIndex[id]?.lastPathComponent == name { return true }
        return NoteStore.nameCarriesId(name, id)
    }

    /// Sweeping asks the filesystem for conflict versions of every file, and
    /// the watcher fires on our own debounced saves too. Rate-limit it: iCloud
    /// takes far longer than this to deliver a conflict in the first place.
    private static let conflictSweepInterval: TimeInterval = 5
    private var lastConflictSweep = Date.distantPast

    private func resolveConflictsIfDue() {
        let now = clock.now()
        guard now.timeIntervalSince(lastConflictSweep) > NoteStore.conflictSweepInterval else { return }
        lastConflictSweep = now
        resolveConflicts()
    }

    /// Resolve every iCloud conflict in the active and archive folders,
    /// merging rather than picking a winner. Returns how many files were
    /// merged. Called on launch and whenever the watcher reports a change.
    @discardableResult
    func resolveConflicts() -> Int {
        var files: [URL] = []
        for dir in [activeURL, archiveURL] {
            guard let listed = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                continue
            }
            files += listed.filter { $0.pathExtension == NoteStore.fileExtension }
        }
        return resolveConflicts(at: files)
    }

    private func resolveConflicts(at files: [URL]) -> Int {
        var resolved = 0
        var changedIds = Set<UUID>()
        for url in files {
            if let id = resolveConflict(at: url) {
                resolved += 1
                changedIds.insert(id)
            }
        }
        if resolved > 0 { notifyChange(.external(changedIds)) }
        return resolved
    }

    /// Bumped when the storage moves, so a sweep that was looking at the old root
    /// is dropped instead of applied to the new one.
    private var storageGeneration = 0

    /// Merge the conflict versions of every note, without holding up the caller.
    /// Asking `NSFileVersion` about each file is a round trip to another process,
    /// so only that question runs on a utility queue. What it finds is merged on
    /// the main queue, where the store lives and where `beforeResolvingConflicts`
    /// lets an open window write first, and observers hear `.external(ids)` for
    /// the notes that changed. `completion` gets the number of files merged.
    func resolveConflictsInBackground(completion: ((Int) -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        let generation = storageGeneration
        // This is the sweep; the watcher's own, a moment later, would only repeat it on the main queue.
        lastConflictSweep = clock.now()
        let folders = [activeURL, archiveURL]
        let provider = UncheckedSendable(conflictVersionsProvider)
        let merge = UncheckedSendable { [weak self] (urls: [URL]) in
            guard let self, self.storageGeneration == generation else { completion?(0); return }
            let merged = self.resolveConflicts(at: urls)
            completion?(merged)
        }
        DispatchQueue.global(qos: .utility).async {
            var withConflicts: [URL] = []
            for dir in folders {
                guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                    continue
                }
                for url in files where url.pathExtension == NoteStore.fileExtension
                    && !provider.value(url).isEmpty {
                    withConflicts.append(url)
                }
            }
            let found = withConflicts
            DispatchQueue.main.async { merge.value(found) }
        }
    }

    /// A conflict version of a file as `resolveConflict` needs it. Production
    /// builds these from `NSFileVersion`; tests supply their own, because real
    /// conflict versions only exist inside iCloud.
    struct ConflictVersionHandle {
        let url: URL
        let markResolved: () -> Void
        /// When the version was saved, as the system reports it. Nil when it
        /// does not say; the merge then goes by what the version's file holds.
        var modificationDate: Date?
    }

    static func systemConflictVersions(of url: URL) -> [ConflictVersionHandle] {
        // Asking for versions is a round trip to another process, and the watcher
        // fires after every save. The file knows whether it has any.
        if let flag = try? url.resourceValues(forKeys: [.ubiquitousItemHasUnresolvedConflictsKey])
            .ubiquitousItemHasUnresolvedConflicts, !flag {
            return []
        }
        return (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).map { version in
            ConflictVersionHandle(
                url: version.url, markResolved: { version.isResolved = true },
                modificationDate: version.modificationDate
            )
        }
    }
    static func systemRemoveOtherVersions(of url: URL) {
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
    }

    var conflictVersionsProvider: (URL) -> [ConflictVersionHandle] = NoteStore.systemConflictVersions(of:)
    var otherVersionsRemover: (URL) -> Void = NoteStore.systemRemoveOtherVersions(of:)

    /// Called with a note's id before its conflict versions are merged, so an
    /// owner holding unsaved text for it can write that first; the merge would
    /// otherwise be made without it, and the text would come back as a second
    /// copy. Returning false leaves the versions for a later sweep.
    var beforeResolvingConflicts: (UUID) -> Bool = { _ in true }

    private func recordWrite(_ note: Note, to url: URL) {
        WriteLineage.record(NoteStore.contentHash(note), for: NoteStore.lineageKey(url))
    }

    private func isNewestOwnWrite(_ note: Note, at url: URL) -> Bool {
        WriteLineage.isNewest(NoteStore.contentHash(note), for: NoteStore.lineageKey(url))
    }

    private func isOwnWrite(_ note: Note, at url: URL) -> Bool {
        WriteLineage.contains(NoteStore.contentHash(note), for: NoteStore.lineageKey(url))
    }

    /// The same file reaches us as `/var/...` and `/private/var/...`.
    static func lineageKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    /// Covers everything a merge keeps, so a version that differs from ours
    /// only in its title or labels is never taken for our own save.
    static func contentHash(_ note: Note) -> String {
        contentHash(body: note.content, title: note.title, labels: note.labels)
    }

    static func contentHash(body: String, title: String = "", labels: [String] = []) -> String {
        let fields = [ConflictResolver.normalizedBody(body), title]
            + labels.sorted()
        let digest = SHA256.hash(data: Data(fields.joined(separator: "\u{0}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Read a note's own file. Unless it holds the newest text this process
    /// wrote, the lineage ends: the file is not ours to vouch for any more.
    private func readMain(_ url: URL) -> Note? {
        readMainSnapshot(url)?.note
    }

    private func readMainSnapshot(_ url: URL) -> NoteSnapshot? {
        guard let snapshot = readSnapshot(url) else { return nil }
        let key = NoteStore.lineageKey(url)
        if !WriteLineage.isNewest(NoteStore.contentHash(snapshot.note), for: key) {
            WriteLineage.clear(key)
        }
        return snapshot
    }

    /// Merge one file's conflict versions back into it. iCloud exposes losing
    /// versions through `NSFileVersion`; ignoring them, as we used to, silently
    /// threw away whatever the other Mac wrote.
    /// Returns the merged note's id when it rewrote the file.
    private func resolveConflict(at url: URL) -> UUID? {
        let conflicts = conflictVersionsProvider(url)
        guard !conflicts.isEmpty else { return nil }

        // Without the current file nothing can be judged, and resolving the
        // versions now would discard the only readable copies.
        guard let first = readMainSnapshot(url) else { return nil }
        guard beforeResolvingConflicts(first.note.id) else { return nil }
        // Read again: the owner may have just written its text into the file.
        guard let snapshot = readMainSnapshot(url) else { return nil }
        let current = snapshot.note

        var conflictNotes: [Note] = []
        // A version that can't be read yet (iCloud has not downloaded it) is
        // left unresolved for a later sweep; resolving it now would lose it.
        var unreadable = Set<Int>()
        for (index, version) in conflicts.enumerated() {
            guard var note = read(version.url) else {
                unreadable.insert(index)
                continue
            }
            if let saved = version.modificationDate { note.updatedAt = saved }
            conflictNotes.append(note)
        }

        // Cleared when the merged text did not reach the file: the versions
        // may then hold the only copy of it.
        var mergeLanded = true
        defer {
            // Mark the rest resolved — leaving them unresolved means being
            // asked about them forever.
            if mergeLanded {
                for (index, version) in conflicts.enumerated() where !unreadable.contains(index) {
                    version.markResolved()
                }
                if unreadable.isEmpty { otherVersionsRemover(url) }
            }
        }

        let versions = ConflictResolver.versionsToMerge(
            current: current,
            currentIsOurNewest: isNewestOwnWrite(current, at: url),
            conflicts: conflictNotes,
            isOurs: { isOwnWrite($0, at: url) }
        )

        guard ConflictResolver.needsMerge(versions),
              var merged = ConflictResolver.merge(versions, now: clock.now()) else { return nil }
        merged.preserved = current.preserved

        // A merge that changed nothing must not be written: the write comes
        // back through the watcher, which sweeps again — and a conflict that
        // won't clear would keep that cycle running every few seconds,
        // dropping the cache and reloading every window each time.
        if current.content == merged.content,
           current.title == merged.title, current.labels == merged.labels {
            return nil
        }

        // Only over the file this merge was computed from. If something wrote
        // it since, the merge is stale and the next sweep redoes it.
        guard case .saved = writeIfUnchanged(merged, to: url, expecting: .fingerprint(snapshot.fingerprint)) else {
            mergeLanded = false
            return nil
        }
        return merged.id
    }

    private func loadAll(from dir: URL) -> [Note]? {
        if let cached = cache[dirKey(dir)] { return cached }

        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        var notes: [Note] = []
        var seen = Set<UUID>()
        var sawDuplicate = false
        for url in files where url.pathExtension == NoteStore.fileExtension {
            guard let note = readMain(url) else { continue }
            if !seen.insert(note.id).inserted { sawDuplicate = true }
            pathIndex[note.id] = url
            knownIds.insert(note.id)
            notes.append(note)
        }
        // Two files with one id, as Obsidian's "Make a copy" leaves: only one of
        // them would take edits, archiving or deleting.
        if sawDuplicate {
            let healed = reassignDuplicateIds(in: dir)
            if !healed.isEmpty {
                let fresh = loadAll(from: dir)
                notifyObservers(.external(healed))
                return fresh
            }
        }
        cache[dirKey(dir)] = notes
        indexedDirs.insert(dirKey(dir))
        return notes
    }

    private func read(_ url: URL) -> Note? {
        readSnapshot(url)?.note
    }

    /// The file text for a note, for a recovery copy written outside the store.
    func recoveryText(for note: Note) -> String { renderMarkdown(note) }

    /// File reads so far. A test reads it to prove an operation touched no disk.
    private(set) var readCount = 0

    /// One read of the file, so the fingerprint is of the bytes the note was parsed from.
    private func readSnapshot(_ url: URL) -> NoteSnapshot? {
        readCount += 1
        guard let data = try? Data(contentsOf: url) else { return nil }
        let note = String(data: data, encoding: .utf8).flatMap {
            parseMarkdown($0, fallbackId: idFromFilename(url) ?? stableId(for: url))
        }
        return note.map { NoteSnapshot(note: $0, fingerprint: Fingerprint(of: data)) }
    }

    /// Write a note, retrying once. Most failures here are transient — a sync
    /// agent holding the file, or the containing directory having just been
    /// moved — so a second attempt after recreating the directory usually
    /// lands. A failure that survives the retry is reported, not dropped.
    @discardableResult
    private func write(_ note: Note, to url: URL) -> Bool {
        if case .success = writeReporting(note, to: url) { return true }
        return false
    }

    private func writeReporting(
        _ note: Note, to url: URL, carryingLegacyPlacement: Bool = false
    ) -> Result<Fingerprint, Error> {
        let data = Data(renderMarkdown(note, carryingLegacyPlacement: carryingLegacyPlacement).utf8)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                recordFailure(url: url, error: error)
                return .failure(error)
            }
        }
        recordSuccess()
        recordWrite(note, to: url)
        return .success(Fingerprint(of: data))
    }

    @discardableResult
    private func moveFile(from: URL, to: URL) -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: to)
        do {
            try fm.moveItem(at: from, to: to)
            recordSuccess()
            return true
        } catch {
            recordFailure(url: to, error: error)
            return false
        }
    }

    // MARK: - Conversion from JSON

    /// Convert every `<uuid>.json` note in `notes/`, `archive/` and `.trash/` to
    /// Markdown beside it. Runs at launch and when the storage moves, so a root
    /// last used by an older version is converted whichever way it is reached.
    /// A vault root holds no such files and is left as it is.
    ///
    /// Each note is written, read back and compared before its JSON is deleted,
    /// so no state exists in which neither file holds it. A file that fails any
    /// step stays where it is and is reported in `lastMigration` and
    /// `lastFailure`. Safe to run again: it only ever finds what is left.
    @discardableResult
    func migrateJSONNotes() -> MigrationReport {
        var report = MigrationReport()
        for dir in [activeURL, archiveURL, trashURL] {
            migrateJSONNotes(in: dir, into: &report)
        }
        lastMigration = report
        if let failure = report.failures.last {
            lastFailure = failure
            NotificationCenter.default.post(name: NoteStore.healthDidChange, object: self)
        } else if lastFailure?.kind == .migration {
            lastFailure = nil
            NotificationCenter.default.post(name: NoteStore.healthDidChange, object: self)
        }
        return report
    }

    private func migrateJSONNotes(in dir: URL, into report: inout MigrationReport) {
        report.reassignedDuplicateIds += reassignDuplicateIds(in: dir).count
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return
        }
        let ordered = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let legacy = ordered.filter { $0.pathExtension == "json" }
        guard !legacy.isEmpty else { return }

        // A note with an id that already has a Markdown file in this folder is
        // a conversion an earlier run did not finish, or a copy that came back.
        var markdown: [UUID: (url: URL, snapshot: NoteSnapshot)] = [:]
        for url in ordered where url.pathExtension == NoteStore.fileExtension {
            if let snapshot = readSnapshot(url) { markdown[snapshot.note.id] = (url, snapshot) }
        }

        for url in legacy {
            // A file converted now would enter the trash today and live another
            // thirty days, so one that has already outlived its retention goes
            // the way an expired Markdown file does at launch.
            if dirKey(dir) == dirKey(trashURL), isExpiredInTrash(url) {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            switch migrateJSONNote(at: url, in: dir, markdown: &markdown) {
            case .converted:
                report.migrated += 1
            case .convertedWithoutSomeCopies:
                report.migrated += 1
                report.failures.append(StorageFailure(
                    url: url, error: MigrationError.unreadableConflictVersion, date: clock.now(), kind: .migration))
            case .failed(let error):
                report.failures.append(StorageFailure(url: url, error: error, date: clock.now(), kind: .migration))
            }
        }
    }

    private func isExpiredInTrash(_ url: URL) -> Bool {
        guard let deleted = NoteStore.deletionDate(of: url) else { return false }
        return clock.now().timeIntervalSince(deleted) > NoteStore.trashRetention
    }

    private enum Conversion {
        case converted
        /// Converted, but a sync copy of the JSON had not downloaded, so its text
        /// is not in the note.
        case convertedWithoutSomeCopies
        case failed(MigrationError)
    }

    private func migrateJSONNote(
        at url: URL,
        in dir: URL,
        markdown: inout [UUID: (url: URL, snapshot: NoteSnapshot)]
    ) -> Conversion {
        guard let data = try? Data(contentsOf: url) else { return .failed(.unreadable) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let note: Note
        do {
            note = try decoder.decode(Note.self, from: data)
        } catch {
            return .failed(.malformed(error.localizedDescription))
        }

        // A sync conflict on the JSON file holds text this Mac does not have, so
        // fold it in. One that has not downloaded cannot hold the note back: the
        // note is shown without it, and the file and the missing copy are set
        // aside where they can be found.
        var versions = [note]
        var folded: [ConflictVersionHandle] = []
        var missing: [ConflictVersionHandle] = []
        for conflict in conflictVersionsProvider(url) {
            if let conflictData = try? Data(contentsOf: conflict.url),
               let conflictNote = try? decoder.decode(Note.self, from: conflictData) {
                versions.append(conflictNote)
                folded.append(conflict)
            } else {
                missing.append(conflict)
            }
        }

        let existing = markdown[note.id]
        if let existing { versions.insert(existing.snapshot.note, at: 0) }

        // The newest version keeps the metadata and the title; text and labels
        // from the others are kept as `ConflictResolver` always does.
        var merged = ConflictResolver.merge(versions, now: clock.now()) ?? versions[0]
        if merged.title.isEmpty, let title = versions.first(where: { !$0.title.isEmpty })?.title {
            merged.title = title
        }
        // The properties of the file in place are its own, whichever version won.
        if let existing { merged.preserved = existing.snapshot.note.preserved }

        if let existing, renderMarkdown(merged) == renderMarkdown(existing.snapshot.note) {
            // The Markdown file already holds everything the JSON does.
        } else {
            let destination = existing?.url ?? NoteStore.unusedURL(generateURL(for: merged, in: dir))
            let result: SaveResult
            if let existing {
                result = writeIfUnchanged(merged, to: destination, expecting: .fingerprint(existing.snapshot.fingerprint))
            } else {
                switch writeReporting(merged, to: destination, carryingLegacyPlacement: true) {
                case let .success(fingerprint): result = .saved(fingerprint)
                case let .failure(error): result = .failed(error)
                }
            }
            guard case let .saved(fingerprint) = result else {
                return .failed(.couldNotWrite(existing == nil ? "The Markdown file could not be written." : "The Markdown file for this note changed while it was being updated."))
            }
            guard let back = readSnapshot(destination), back.fingerprint == fingerprint,
                  NoteStore.readsBackAs(merged, back.note) else {
                if existing == nil { try? FileManager.default.removeItem(at: destination) }
                return .failed(.readBackDiffers)
            }
            markdown[merged.id] = (destination, back)

            // The file entered the trash folder just now, which is not when the
            // note was deleted. Carry the stamped deletion date over; purging
            // goes by when a file entered the folder, so this only keeps the
            // record straight and the converted note lives at most thirty days
            // longer, never fewer.
            if existing == nil, dirKey(dir) == dirKey(trashURL), let deleted = NoteStore.deletionDate(of: url) {
                try? FileManager.default.setAttributes([.modificationDate: deleted], ofItemAtPath: destination.path)
            }
        }

        guard let asideURL = setAside(url, under: dir.lastPathComponent) else { return .failed(.couldNotSetAside) }
        for conflict in folded { conflict.markResolved() }
        if !missing.isEmpty {
            let list = missing.map(\.url.path).joined(separator: "\n")
            let text = "These sync conflict copies of \(url.lastPathComponent) had not downloaded when it was converted:\n\(list)\n"
            try? Data(text.utf8).write(to: asideURL.appendingPathExtension("unread-conflict-copies.txt"))
            return .convertedWithoutSomeCopies
        }
        return .converted
    }

    /// Move `url` into `.converted-json/<subfolder>/` under a name that is free.
    private func setAside(_ url: URL, under subfolder: String) -> URL? {
        let fm = FileManager.default
        let folder = convertedJSONURL.appendingPathComponent(subfolder, isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = NoteStore.unusedURL(folder.appendingPathComponent(url.lastPathComponent))
            try fm.moveItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Give every file but one a new id when several files in `dir` share one.
    /// Obsidian's "Make a copy" and two Macs converting the same note both do
    /// this, and while it stands only one of the files takes edits, archiving or
    /// deleting. The file whose name a fresh save would give it keeps the id,
    /// else the oldest by creation date, else the first by name. Each other file
    /// has only its `id:` line rewritten, in place, and is read back; nothing is
    /// merged or moved, so every file keeps its own text. Returns the ids that
    /// were involved, old and new.
    @discardableResult
    private func reassignDuplicateIds(in dir: URL) -> Set<UUID> {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else {
            return []
        }
        var groups: [UUID: [(url: URL, snapshot: NoteSnapshot)]] = [:]
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension == NoteStore.fileExtension {
            if let snapshot = readSnapshot(url) { groups[snapshot.note.id, default: []].append((url, snapshot)) }
        }

        var touched = Set<UUID>()
        for (id, group) in groups where group.count > 1 {
            func created(_ url: URL) -> Date {
                (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
            }
            let original = group.first {
                let names = NoteStore.fileNames(for: $0.snapshot.note)
                return [names.short, names.long].contains($0.url.lastPathComponent)
            }
                ?? group.min { (created($0.url), $0.url.lastPathComponent) < (created($1.url), $1.url.lastPathComponent) }!
            for copy in group where copy.url != original.url {
                if reassignId(of: copy.url, expecting: copy.snapshot) { touched.formUnion([id]) }
            }
        }
        if !touched.isEmpty {
            pathIndex.removeAll()
            indexedDirs.remove(dirKey(dir))
        }
        return touched
    }

    /// Replace the value of the `id:` frontmatter line with a new id and nothing
    /// else, if the file is still what was read.
    private func reassignId(of url: URL, expecting snapshot: NoteSnapshot) -> Bool {
        guard let data = try? Data(contentsOf: url), Fingerprint(of: data) == snapshot.fingerprint,
              let text = String(data: data, encoding: .utf8) else { return false }
        let newId = UUID()
        guard let rewritten = MarkdownFile.replacingValue(ofKey: "id", in: text, with: newId.uuidString) else {
            return false
        }
        let updated = Data(rewritten.utf8)
        do {
            try updated.write(to: url, options: .atomic)
        } catch {
            recordFailure(url: url, error: error)
            return false
        }
        guard let back = readSnapshot(url), back.fingerprint == Fingerprint(of: updated), back.note.id == newId else {
            return false
        }
        recordWrite(back.note, to: url)
        return true
    }

    /// Whether `back`, read from the Markdown file written for `note`, is the
    /// same note. Dates keep whole seconds and the size hint two decimals on
    /// disk, and labels come back normalised, so those are compared as stored.
    private static func readsBackAs(_ note: Note, _ back: Note) -> Bool {
        func seconds(_ date: Date) -> Int { Int(date.timeIntervalSince1970.rounded(.down)) }
        let labels = note.labels.map(NoteLabel.normalize).filter { !$0.isEmpty }
        return back.id == note.id
            && back.title == note.title
            && back.content == note.content
            && back.color == note.color
            && back.floatLevel == note.floatLevel
            && back.labels == labels
            && seconds(back.createdAt) == seconds(note.createdAt)
            && seconds(back.updatedAt) == seconds(note.updatedAt)
            && abs(back.width - note.width) < 0.01
            && abs(back.height - note.height) < 0.01
    }

    /// `candidate`, or the first of `name-2.md`, `name-3.md`… that is free.
    private static func unusedURL(_ candidate: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = candidate.deletingPathExtension()
        var counter = 2
        while true {
            let next = base.deletingLastPathComponent()
                .appendingPathComponent("\(base.lastPathComponent)-\(counter).\(candidate.pathExtension)")
            if !fm.fileExists(atPath: next.path) { return next }
            counter += 1
        }
    }

    // MARK: - Health

    private func recordFailure(url: URL, error: Error, kind: StorageFailure.Kind = .write) {
        lastFailure = StorageFailure(url: url, error: error, date: clock.now(), kind: kind)
        NotificationCenter.default.post(name: NoteStore.healthDidChange, object: self)
    }

    /// A landed write clears a write failure. A note that could not be converted
    /// is still unconverted, so the failure to convert it comes back into view,
    /// and only a later conversion run clears that one.
    private func recordSuccess() {
        guard let failure = lastFailure, failure.kind == .write else { return }
        lastFailure = lastMigration.failures.last
        NotificationCenter.default.post(name: NoteStore.healthDidChange, object: self)
    }

    // MARK: - Markdown serialization

    /// The Markdown text of a note. The window's position and collapsed state
    /// are this Mac's (`DeviceLayoutStore`) and are not in it; a file that still
    /// has them loses them with the next write. `carryingLegacyPlacement` keeps
    /// them, for a note converted from JSON that no layout has seen yet.
    private func renderMarkdown(_ note: Note, carryingLegacyPlacement: Bool = false) -> String {
        let labelsField = "[" + note.labels.joined(separator: ", ") + "]"
        var frontmatter: [(String, String)] = [
            ("id", note.id.uuidString),
            ("title", note.title),
            ("color", note.color.rawValue),
            ("labels", labelsField)
        ]
        if carryingLegacyPlacement, let placement = note.legacyPlacement {
            frontmatter += [
                ("positionX", String(format: "%.2f", placement.x)),
                ("positionY", String(format: "%.2f", placement.y))
            ]
        }
        frontmatter += [
            ("width", String(format: "%.2f", note.width)),
            ("height", String(format: "%.2f", note.height))
        ]
        if carryingLegacyPlacement, let placement = note.legacyPlacement {
            frontmatter.append(("collapsed", placement.collapsed ? "true" : "false"))
        }
        frontmatter += [
            ("float", note.floatLevel.rawValue),
            ("created", unreadableDate("created", of: note) ?? iso8601.string(from: note.createdAt)),
            ("updated", unreadableDate("updated", of: note) ?? iso8601.string(from: note.updatedAt))
        ]
        let document = MarkdownFile.Document(
            frontmatter: frontmatter, body: note.content, layout: note.preserved.layout,
            originals: note.preserved.originals
        )
        return MarkdownFile.serialize(
            document, forceQuoteKeys: ["title"], blockListKeys: note.preserved.labelsAsBlock ? ["labels"] : []
        )
    }

    /// The date the file wrote for `key` in a format the app cannot read, such as
    /// a plugin's `2026-11-15 10:00`, while the note still holds the date the
    /// parser made up in its place. The app writes ISO dates only when it has
    /// a date of its own to write.
    private func unreadableDate(_ key: String, of note: Note) -> String? {
        guard let original = note.preserved.originals[key], iso8601.date(from: original.value) == nil else { return nil }
        if key == "updated", note.updatedAt != note.createdAt { return nil }
        return original.value
    }

    /// The keys the app reads and writes itself. Any other key in a note's
    /// frontmatter is carried through as it was; see `PreservedFrontmatter`.
    /// `positionX`, `positionY` and `collapsed` are read only, to place a note
    /// once. They are named here so they are not kept as lines of the file
    /// that belong to someone else, and they are not written.
    private static let ownedFrontmatterKeys: Set<String> = [
        "id", "title", "color", "labels", "positionX", "positionY", "width", "height",
        "collapsed", "float", "created", "updated"
    ]

    private func parseMarkdown(_ raw: String, fallbackId: UUID?) -> Note? {
        let doc = MarkdownFile.parse(raw, ownedKeys: Self.ownedFrontmatterKeys)
        let id: UUID = doc.value(for: "id").flatMap(UUID.init(uuidString:)) ?? fallbackId ?? UUID()
        let title = doc.value(for: "title") ?? ""
        let color = doc.value(for: "color").flatMap(NoteColor.init(rawValue:)) ?? .yellow
        let labels = parseLabelsList(doc.value(for: "labels"))
        let legacyPlacement = Double(doc.value(for: "positionX") ?? "").flatMap { x in
            Double(doc.value(for: "positionY") ?? "").map { y in
                LegacyPlacement(x: x, y: y, collapsed: (doc.value(for: "collapsed") ?? "false") == "true")
            }
        }
        let width = Double(doc.value(for: "width") ?? "") ?? 240
        let height = Double(doc.value(for: "height") ?? "") ?? 200
        let floatLevel = doc.value(for: "float").flatMap(NoteFloatLevel.init(rawValue:)) ?? .floating
        let createdAt = doc.value(for: "created").flatMap(iso8601.date(from:)) ?? clock.now()
        let updatedAt = doc.value(for: "updated").flatMap(iso8601.date(from:)) ?? createdAt
        var note = Note(
            id: id,
            title: title,
            content: doc.body,
            width: width,
            height: height,
            color: color,
            labels: labels,
            floatLevel: floatLevel,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        note.preserved = PreservedFrontmatter(
            layout: doc.layout, labelsAsBlock: doc.blockListKeys.contains("labels"), originals: doc.originals
        )
        note.legacyPlacement = legacyPlacement
        return note
    }

    /// Parse a flat YAML inline-list value like `[a, b, c]`. Tolerates missing
    /// brackets and stray quotes — frontmatter is hand-edited often.
    private func parseLabelsList(_ raw: String?) -> [String] {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return [] }
        if s.hasPrefix("[") { s.removeFirst() }
        if s.hasSuffix("]") { s.removeLast() }
        return s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .compactMap { token -> String? in
                let n = NoteLabel.normalize(token)
                return n.isEmpty ? nil : n
            }
    }

    private func idFromFilename(_ url: URL) -> UUID? {
        UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    /// An id for a vault file that carries no `id:` of its own — a note
    /// someone wrote in Obsidian and dropped in the folder. Deriving it from
    /// the path keeps it the same on every load; minting a random one made
    /// each reload look like the old note had vanished and a new one
    /// appeared, so its window was torn down and rebuilt on every change.
    private func stableId(for url: URL) -> UUID {
        var digest = SHA256()
        digest.update(data: Data(url.standardizedFileURL.path.utf8))
        var bytes = Array(digest.finalize().prefix(16))
        // Shape the bytes as a v4 UUID so nothing downstream sees anything odd.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
