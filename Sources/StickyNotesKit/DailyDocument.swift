import Foundation

/// Today's daily note as a `NoteRepository`: one raw Markdown file, no
/// frontmatter, so Obsidian and its plugins stay authoritative for formatting.
/// A document edits it as a note whose body is the file's text.
///
/// Saves are compare-and-swap, as for any note, and the file keeps a write
/// lineage in `WriteLineage` like `NoteStore` does for note files, so iCloud's
/// older copies of this Mac's own saves are told apart from another Mac's text.
final class DailyFile: NoteRepository {
    /// The file the document is on now; nil when no vault or pattern is set,
    /// in which case there is nowhere to write and nothing is kept.
    var url: URL?
    /// The same seam `NoteStore` merges conflict versions through; a test
    /// supplies its own, because real ones only exist inside iCloud.
    var conflictVersionsProvider: (URL) -> [NoteStore.ConflictVersionHandle] = NoteStore.systemConflictVersions(of:)
    var otherVersionsRemover: (URL) -> Void = NoteStore.systemRemoveOtherVersions(of:)
    private let clock: AppClock
    private let id = UUID()

    init(clock: AppClock) {
        self.clock = clock
    }

    func note(body: String, updatedAt: Date? = nil) -> Note {
        let now = clock.now()
        return Note(
            id: id, content: body,
            width: 0, height: 0,
            color: .yellow, createdAt: now, updatedAt: updatedAt ?? now
        )
    }

    static func hasICloudPlaceholder(for url: URL) -> Bool {
        let stub = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: stub.path)
    }

    private enum OnDisk {
        case missing
        /// There is a file, or one waiting in iCloud, and it cannot be read.
        case unreadable
        case file(Data, String)
    }

    private func read(_ url: URL) -> OnDisk {
        guard let data = try? Data(contentsOf: url) else {
            let present = FileManager.default.fileExists(atPath: url.path) || Self.hasICloudPlaceholder(for: url)
            return present ? .unreadable : .missing
        }
        guard let body = String(data: data, encoding: .utf8) else { return .unreadable }
        // A file that is not our newest write ends the lineage: from then on an
        // older save of ours may hold the only copy of some text.
        if !WriteLineage.isNewest(NoteStore.contentHash(body: body), for: NoteStore.lineageKey(url)) {
            WriteLineage.clear(NoteStore.lineageKey(url))
        }
        return .file(data, body)
    }

    @discardableResult
    func save(_ note: Note, expecting expected: Fingerprint?) -> SaveResult {
        guard let url = url else { return .gone }
        do {
            // Obsidian creates the folder lazily; so do we, rather than
            // failing the first write.
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            switch read(url) {
            case .unreadable:
                return .failed(SaveError.unreadableOnDisk)
            case let .file(data, body):
                let current = Fingerprint(of: data)
                if current != expected {
                    return .conflict(onDisk: self.note(body: body), fingerprint: current)
                }
            case .missing:
                // Never written, or deleted since: either way the person's text
                // goes to a new file.
                break
            }
            return .saved(try write(Data(note.content.utf8), to: url))
        } catch {
            return .failed(error)
        }
    }

    private func write(_ data: Data, to url: URL) throws -> Fingerprint {
        try Self.writeRecording(data, to: url)
    }

    private static func writeRecording(_ data: Data, to url: URL) throws -> Fingerprint {
        try data.write(to: url, options: .atomic)
        let body = String(decoding: data, as: UTF8.self)
        WriteLineage.record(NoteStore.contentHash(body: body), for: NoteStore.lineageKey(url))
        return Fingerprint(of: data)
    }

    /// Replace the file's text, only if it still has the bytes `expected` was
    /// taken from, and record the write in the lineage. For a writer that is not
    /// the document, such as healing a duplicate or applying a template. Returns
    /// the new fingerprint, or nil when the file changed or could not be written.
    static func replaceFile(at url: URL, with body: String, expecting expected: Fingerprint) -> Fingerprint? {
        guard let data = try? Data(contentsOf: url), Fingerprint(of: data) == expected else { return nil }
        return try? writeRecording(Data(body.utf8), to: url)
    }

    func loadNote(id: UUID, archived: Bool) -> Note? {
        snapshot(id: id, archived: archived)?.note
    }

    func snapshot(id: UUID, archived: Bool) -> NoteSnapshot? {
        snapshot()
    }

    /// Today's file as it is on disk now, and its fingerprint.
    func snapshot() -> NoteSnapshot? {
        guard let url = url, case let .file(data, body) = read(url) else { return nil }
        return NoteSnapshot(note: note(body: body), fingerprint: Fingerprint(of: data))
    }

    func archive(_ note: Note) {}
    func discardActive(_ note: Note) {}

    // MARK: - Conflict versions

    func unresolvedConflicts() -> [NoteStore.ConflictVersionHandle] {
        guard let url = url else { return [] }
        return conflictVersionsProvider(url)
    }

    /// Merge the file's iCloud conflict versions (`unresolvedConflicts()`) into
    /// it, as `NoteStore` does for a note: nothing is thrown away, except an
    /// older copy of this Mac's own save while the file still holds its newest.
    /// A version that cannot be read yet is left unresolved for a later sweep.
    /// Returns whether the file was rewritten.
    @discardableResult
    func resolveConflicts(_ conflicts: [NoteStore.ConflictVersionHandle]) -> Bool {
        guard let url = url, !conflicts.isEmpty else { return false }
        // Without the current file nothing can be judged, and resolving the
        // versions now would discard the only readable copies.
        guard case let .file(data, body) = read(url) else { return false }
        let current = note(body: body, updatedAt: Self.modificationDate(of: url) ?? .distantPast)

        var conflictNotes: [Note] = []
        var unreadable = Set<Int>()
        for (index, version) in conflicts.enumerated() {
            guard let raw = try? String(contentsOf: version.url, encoding: .utf8) else {
                unreadable.insert(index)
                continue
            }
            let saved = version.modificationDate ?? Self.modificationDate(of: version.url) ?? .distantPast
            conflictNotes.append(note(body: raw, updatedAt: saved))
        }

        // Cleared when the merged text did not reach the file: the versions may
        // then hold the only copy of it.
        var mergeLanded = true
        defer {
            if mergeLanded {
                for (index, version) in conflicts.enumerated() where !unreadable.contains(index) {
                    version.markResolved()
                }
                if unreadable.isEmpty { otherVersionsRemover(url) }
            }
        }

        let key = NoteStore.lineageKey(url)
        let versions = ConflictResolver.versionsToMerge(
            current: current,
            currentIsOurNewest: WriteLineage.isNewest(NoteStore.contentHash(current), for: key),
            conflicts: conflictNotes,
            isOurs: { WriteLineage.contains(NoteStore.contentHash($0), for: key) }
        )
        guard ConflictResolver.needsMerge(versions),
              let merged = ConflictResolver.merge(versions, now: clock.now()),
              merged.content != current.content else { return false }

        // Only over the file this merge was computed from; if something wrote it
        // since, the next sweep redoes the merge.
        guard case let .file(latest, _) = read(url), latest == data,
              (try? write(Data(merged.content.utf8), to: url)) != nil else {
            mergeLanded = false
            return false
        }
        return true
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// Today's daily note: which file it is, what the window shows, and the rules
/// that keep typing and outside edits from losing each other. The save,
/// echo-filter, defer and merge rules are `NoteDocument`'s, shared with every
/// other note; this adds the file (resolved from the settings and the date),
/// the day rolling over, a file that cannot be read yet, and iCloud's numbered
/// duplicates. It has no UI: a window renders `body` and forwards typing.
///
/// The clock never creates the file. Resolving the day, at launch, at midnight
/// or on wake, seeds the buffer from the template and writes nothing: every Mac
/// rolls over at the same second, and two independent creates of one path are
/// what iCloud keeps as `<name> 2.md`. A person's edit, or opening the note on
/// purpose, creates it.
final class DailyDocument {
    enum RolloverResult {
        case unchanged
        case rolled
        /// The new day was not opened: the old day's text could not be written,
        /// and replacing the buffer would throw it away. A retry is armed.
        case blocked
    }

    /// How long an unreadable file is left before it is tried again, for a
    /// failure that no file event will report.
    static let unavailableRetryDelay: TimeInterval = 5
    /// Sweeping reads the whole folder, and the watcher fires on our own saves
    /// too, so it is rate-limited. iCloud takes far longer than this to deliver
    /// a duplicate.
    static let duplicateSweepInterval: TimeInterval = 5

    private let settings: Settings
    private let clock: AppClock
    private let scheduler: Scheduler
    private let file: DailyFile
    private let document: NoteDocument
    /// Read on every use, so a change of time zone while the app runs moves the
    /// day with it.
    private let calendarProvider: () -> Calendar
    private var calendar: Calendar { calendarProvider() }

    /// Start of the day whose file this is.
    private(set) var day: Date
    private(set) var url: URL?

    /// True when the file exists but cannot be read, so what the window shows is
    /// a placeholder, not the note. Nothing is saved and nothing can be typed
    /// until it reads, or a placeholder would land on top of the real text.
    private(set) var isUnavailable = false

    private var unavailableRetry: ScheduledWork?
    private var rolloverTask: ScheduledWork?
    private var rolloverRetry: ScheduledWork?
    private var lastDuplicateSweep = Date.distantPast

    /// Where conflict versions of today's file come from. A test supplies its own.
    var conflictVersionsProvider: (URL) -> [NoteStore.ConflictVersionHandle] {
        get { file.conflictVersionsProvider }
        set { file.conflictVersionsProvider = newValue }
    }
    var otherVersionsRemover: (URL) -> Void {
        get { file.otherVersionsRemover }
        set { file.otherVersionsRemover = newValue }
    }

    /// True while the caret is in the note. See `NoteDocument.isEditing`.
    var isEditing: () -> Bool {
        get { document.isEditing }
        set { document.isEditing = newValue }
    }
    /// The text shown was replaced: a load, a new day, or an outside version
    /// adopted. Read `body` and `isUnavailable`.
    var onBodyReplaced: () -> Void = {}
    /// The file the note is on changed, so a watcher on its folder must move.
    var onFileChanged: () -> Void = {}
    /// Gives text that cannot be written anywhere a last chance to be kept,
    /// when it is about to be replaced. Returns whether it was.
    var saveRecovery: (_ body: String, _ day: Date) -> Bool = { _, _ in false }

    init(
        settings: Settings,
        clock: AppClock,
        scheduler: Scheduler = MainScheduler(),
        calendar: @escaping () -> Calendar = { .current }
    ) {
        self.settings = settings
        calendarProvider = calendar
        self.clock = clock
        self.scheduler = scheduler
        file = DailyFile(clock: clock)
        document = NoteDocument(note: file.note(body: ""), repository: file, scheduler: scheduler, clock: clock)
        day = calendar().startOfDay(for: clock.now())
        document.didApplyExternal = { [weak self] _ in self?.onBodyReplaced() }
    }

    deinit {
        unavailableRetry?.cancel()
        rolloverTask?.cancel()
        rolloverRetry?.cancel()
    }

    /// What the window shows, when it is not the placeholder.
    var body: String { document.buffer.content }
    var hasUnsavedEdits: Bool { document.hasUnsavedEdits }
    var pendingExternalBody: String? { document.pendingExternal?.content }

    // MARK: - Loading

    func load() {
        load(now: clock.now())
    }

    /// Resolve the file for `now` and put its text in the buffer.
    private func load(now: Date) {
        unavailableRetry?.cancel()
        unavailableRetry = nil
        day = calendar.startOfDay(for: now)
        url = DailyNote.resolvedURL(for: day, settings: settings)
        file.url = url
        // Before reading: a duplicate left by an earlier collision holds text
        // that belongs in the file about to be loaded.
        healDuplicates(now: now)
        // Likewise iCloud's conflict versions: another Mac's text may be only
        // there. The document holds nothing unsaved here: every caller wrote it first.
        file.resolveConflicts(file.unresolvedConflicts())

        guard let url = url else {
            adopt("", unavailable: false)
            return
        }
        if let snapshot = file.snapshot() {
            adopt(snapshot.note.content, fingerprint: snapshot.fingerprint, unavailable: false)
            return
        }
        // Today's note exists but cannot be read yet. Seeding the template here
        // would overwrite real content. An evicted iCloud file does not answer
        // to `fileExists`: iCloud replaces it with a hidden `.<name>.icloud`
        // stub until something asks for the download.
        if FileManager.default.fileExists(atPath: url.path) || DailyFile.hasICloudPlaceholder(for: url) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            adopt("", unavailable: true)
            // The watcher covers the usual case; this is the backstop for a read
            // that fails for a reason no file event reports.
            unavailableRetry = scheduler.schedule(after: Self.unavailableRetryDelay) { [weak self] in
                guard let self = self, self.isUnavailable else { return }
                self.unavailableRetry = nil
                self.load(now: self.clock.now())
            }
            return
        }
        // No file yet. The template seeds the buffer; the file stays uncreated.
        adopt(DailyNote.renderedTemplate(for: day, fileURL: url, settings: settings) ?? "", unavailable: false)
    }

    /// `fingerprint` is that of the file `body` was read from; nil when the
    /// buffer is a placeholder or a template with no file behind it.
    private func adopt(_ body: String, fingerprint: Fingerprint? = nil, unavailable: Bool) {
        isUnavailable = unavailable
        document.reset(to: file.note(body: body), fingerprint: fingerprint)
        onBodyReplaced()
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Typing and saving

    func setBody(_ text: String) {
        guard !isUnavailable else { return }
        document.setBody(text)
    }

    /// The window lost focus: fold in an outside edit that was held back.
    func blur() {
        document.blur()
    }

    /// Write any debounced edit now. False when the text did not reach disk.
    @discardableResult
    func flush() -> Bool {
        guard !isUnavailable else { return true }
        return document.flush()
    }

    // MARK: - Outside changes

    /// The folder changed: pick up an outside edit, a duplicate, or a download.
    func storeDidChange() {
        guard url != nil else { return }
        // A duplicate arrives as an ordinary new file in the folder watched.
        // Heal first so the read below picks up the merged text. The typing is
        // written before that, so the healed file has it: merged afterwards it
        // would come back as a second copy.
        if duplicateSweepIsDue(now: clock.now()) { flush() }
        healDuplicatesIfDue(now: clock.now())
        resolveConflictVersions()
        // A failed read means the file is mid-sync or undecodable, not empty:
        // treating it as empty would blank the buffer and then save that over
        // the real content. If we were waiting on a download, this is it.
        guard let snapshot = file.snapshot() else { return }
        if isUnavailable {
            unavailableRetry?.cancel()
            unavailableRetry = nil
            adopt(snapshot.note.content, fingerprint: snapshot.fingerprint, unavailable: false)
            return
        }
        document.externalChange(snapshot.note, fingerprint: snapshot.fingerprint)
    }

    /// Merge iCloud's conflict versions of today's file. Unsaved typing is written
    /// first, so the merge is made with it: merged afterwards, a version that
    /// already holds the typing comes back as a second copy of it. If that write
    /// fails the versions wait for the next change. Not rate-limited like the
    /// folder sweep: it asks about one file, and the file itself says whether it
    /// has any.
    private func resolveConflictVersions() {
        let conflicts = file.unresolvedConflicts()
        guard !conflicts.isEmpty, flush() else { return }
        file.resolveConflicts(conflicts)
    }

    private func healDuplicates(now: Date) {
        guard let url = url else { return }
        lastDuplicateSweep = now
        DailyNote.healDuplicates(in: url.deletingLastPathComponent(), now: now)
    }

    private func duplicateSweepIsDue(now: Date) -> Bool {
        now.timeIntervalSince(lastDuplicateSweep) > Self.duplicateSweepInterval
    }

    private func healDuplicatesIfDue(now: Date) {
        guard duplicateSweepIsDue(now: now) else { return }
        healDuplicates(now: now)
    }

    // MARK: - Rollover

    /// Arm the timer for the next midnight. Call once the document is in use.
    func startRollover() {
        armMidnight()
    }

    private func armMidnight() {
        rolloverTask?.cancel()
        let now = clock.now()
        guard let next = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 1),
            matchingPolicy: .strict
        ) else { return }
        rolloverTask = scheduler.scheduleOnWallClock(after: next.timeIntervalSince(now)) { [weak self] in
            guard let self = self else { return }
            self.rolloverIfNeeded(now: self.clock.now())
            self.armMidnight()
        }
    }

    /// The Mac woke. The midnight timer does not fire while it sleeps, so a
    /// machine that slept through midnight keeps showing the old day until this.
    /// The timer may also have fired late or been coalesced, so it is re-armed.
    func wakeDidHappen() {
        rolloverIfNeeded(now: clock.now())
        armMidnight()
    }

    /// Swap to the day of `now` if the calendar day advanced since the file was
    /// resolved. Cheap when the day is unchanged.
    ///
    /// The old day is saved first. If that write fails the new day is not
    /// opened: loading it would replace a buffer that exists nowhere else.
    @discardableResult
    func rolloverIfNeeded(now: Date) -> RolloverResult {
        guard calendar.startOfDay(for: now) != day else { return .unchanged }
        guard flush() else {
            armRolloverRetry()
            return .blocked
        }
        rolloverRetry?.cancel()
        rolloverRetry = nil
        load(now: now)
        onFileChanged()
        return .rolled
    }

    private func armRolloverRetry() {
        rolloverRetry?.cancel()
        rolloverRetry = scheduler.schedule(after: NoteDocument.retryDelay) { [weak self] in
            guard let self = self else { return }
            self.rolloverRetry = nil
            self.rolloverIfNeeded(now: self.clock.now())
        }
    }

    // MARK: - Settings changes

    /// The pattern or vault changed: save against the previous file, then
    /// resolve the new one. Text that cannot be saved is kept for recovery
    /// before the buffer is replaced; if that fails too, the document stays on
    /// the old file, dirty and retrying, rather than drop the text.
    func patternDidChange() {
        if !flush(), !saveRecovery(body, day) { return }
        load(now: clock.now())
        onFileChanged()
    }

    /// Re-seed today's note from the template if it is empty. Called when the
    /// template setting changes: "I just configured a template, apply it".
    /// Writing to a file that exists is an edit of an established path, so it
    /// does not race; a missing file stays uncreated.
    func templateDidChange() {
        guard let url = url, !isUnavailable,
              Self.isBlank(body), document.pendingExternal == nil,
              let templated = DailyNote.renderedTemplate(for: day, fileURL: url, settings: settings)
        else { return }
        // The buffer can be behind the file by the watcher's delay. Text on disk
        // is the note, not a blank to fill: take it in, and write no template.
        let onDisk = file.snapshot()
        if let onDisk, !Self.isBlank(onDisk.note.content) {
            storeDidChange()
            return
        }
        var fingerprint: Fingerprint?
        if let onDisk {
            // Only over the blank file just read; if it changed since, take that in.
            guard let written = DailyFile.replaceFile(at: url, with: templated, expecting: onDisk.fingerprint) else {
                storeDidChange()
                return
            }
            fingerprint = written
        } else if FileManager.default.fileExists(atPath: url.path) {
            // Present but unreadable: nothing is known about it, so it is left alone.
            return
        }
        adopt(templated, fingerprint: fingerprint, unavailable: false)
    }

    /// Write today's note out if it is not on disk yet, so opening it is enough
    /// to make it real for Obsidian and for `[[wiki links]]`. What is written
    /// is the buffer, the template or nothing, because that is what the person
    /// sees. Safe against the midnight race in a way the rollover is not: a
    /// person opening a window is not two machines acting on one clock tick.
    func createTodaysFileIfMissing() {
        guard let url = url, !isUnavailable else { return }
        // A file that exists, or is only waiting to come down from iCloud, must
        // never be written over with an empty buffer.
        guard !FileManager.default.fileExists(atPath: url.path),
              !DailyFile.hasICloudPlaceholder(for: url) else { return }
        document.requestSave()
        document.flush()
    }
}
