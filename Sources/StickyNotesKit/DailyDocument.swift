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
    /// Which files are in iCloud and not on this Mac; such a file is never read.
    let dataless = DatalessGuard()
    /// This Mac's name as a conflict version's saving computer is compared with it.
    lazy var computerName: String? = NoteStore.systemComputerName

    init(clock: AppClock) {
        self.clock = clock
        dataless.now = { clock.now() }
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
        /// The file is in iCloud and not on this Mac. It was not read; its download
        /// has been asked for.
        case notDownloaded
        case file(Data, String)
    }

    private func read(_ url: URL) -> OnDisk {
        let data: Data
        switch dataless.read(url) {
        case let .bytes(bytes):
            data = bytes
        case .notDownloaded:
            return .notDownloaded
        case .unreadable:
            let present = FileManager.default.fileExists(atPath: url.path) || Self.hasICloudPlaceholder(for: url)
            return present ? .unreadable : .missing
        }
        guard let body = String(data: data, encoding: .utf8) else { return .unreadable }
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
            case .notDownloaded:
                return .failed(SaveError.notDownloadedYet)
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

    private func write(_ data: Data, to url: URL, asMerge: Bool = false) throws -> Fingerprint {
        try Self.writeRecording(data, to: url, at: clock.now(), asMerge: asMerge)
    }

    private static func writeRecording(
        _ data: Data, to url: URL, at date: Date, asMerge: Bool = false
    ) throws -> Fingerprint {
        try data.write(to: url, options: .atomic)
        let body = String(decoding: data, as: UTF8.self)
        WriteLineage.record(body: body, at: date, merged: asMerge, for: NoteStore.lineageKey(url))
        return Fingerprint(of: data)
    }

    /// Replace the file's text, only if it still has the bytes `expected` was
    /// taken from, and record the write in the lineage. For a writer that is not
    /// the document, such as healing a duplicate or applying a template. Returns
    /// the new fingerprint, or nil when the file changed or could not be written.
    ///
    /// `asMerge` says the text comes from other versions, as a healed duplicate's
    /// does, so it vouches for nothing; a template the person asked for is their own
    /// write (`asMerge: false`).
    static func replaceFile(
        at url: URL, with body: String, expecting expected: Fingerprint, at date: Date = Date(), asMerge: Bool = true,
        dataless: DatalessGuard = DatalessGuard()
    ) -> Fingerprint? {
        guard case let .bytes(data) = dataless.read(url), Fingerprint(of: data) == expected else { return nil }
        return try? writeRecording(Data(body.utf8), to: url, at: date, asMerge: asMerge)
    }

    func isEarlierOwnBody(_ body: String, ofNote id: UUID) -> Bool {
        guard let url = url else { return false }
        return WriteLineage.containsEarlierBody(body, for: NoteStore.lineageKey(url), countingMerges: true)
    }

    func textAdopted(_ body: String, over previous: String?, ofNote id: UUID) {
        guard let url = url else { return }
        WriteLineage.adopted(body, over: previous, for: NoteStore.lineageKey(url))
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
    /// earlier copy of this Mac's own saves (see `ConflictResolver.versionsToMerge`).
    /// A version that cannot be read yet is left unresolved for a later sweep.
    /// Returns whether the file was rewritten.
    @discardableResult
    func resolveConflicts(_ conflicts: [NoteStore.ConflictVersionHandle]) -> Bool {
        resolveConflictsReporting(conflicts) == .merged
    }

    enum MergeOutcome {
        /// Nothing to merge, or nothing that a later try would change.
        case unchanged
        case merged
        /// The merged text could not be written, so the versions are still there.
        case couldNotWrite
    }

    func resolveConflictsReporting(_ conflicts: [NoteStore.ConflictVersionHandle]) -> MergeOutcome {
        guard let url = url, !conflicts.isEmpty else { return .unchanged }
        // Without the current file nothing can be judged, and resolving the
        // versions now would discard the only readable copies.
        guard case let .file(data, body) = read(url) else { return .unchanged }
        let current = note(body: body, updatedAt: Self.modificationDate(of: url) ?? .distantPast)

        var conflictNotes: [ConflictResolver.Candidate] = []
        var unreadable = Set<Int>()
        for (index, version) in conflicts.enumerated() {
            guard let raw = dataless.readText(version.url) else {
                unreadable.insert(index)
                continue
            }
            let saved = version.modificationDate ?? Self.modificationDate(of: version.url) ?? .distantPast
            conflictNotes.append(.init(
                note: note(body: raw, updatedAt: saved),
                savedAt: version.modificationDate, computer: version.savingComputer
            ))
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

        let history = WriteLineage.history(for: NoteStore.lineageKey(url))
        let thisComputer = computerName
        let handled = ConflictResolver.handlingStaleFile(
            current, newestBody: history.newestBody,
            isEarlierBody: { history.contains(body: NoteStore.contentHash(body: $0)) },
            isNewestBody: { history.newest?.body == NoteStore.contentHash(body: $0) }
        )
        let judged = handled.current
        let versions = ConflictResolver.versionsToMerge(
            current: judged,
            conflicts: conflictNotes,
            ours: ConflictResolver.OwnWrites(
                isOurs: {
                    history.isOwnEarlierSave(
                        full: NoteStore.contentHash($0.note), savedAt: $0.savedAt,
                        computer: $0.computer, thisComputer: thisComputer
                    )
                },
                isNewest: { history.isNewest(full: NoteStore.contentHash($0)) },
                newestLines: history.newestLines,
                newestIsAdded: handled.addedNewest != nil
            )
        ) + (handled.addedNewest.map { [$0] } ?? [])
        guard ConflictResolver.needsMerge(versions) || judged.content != current.content,
              let merged = ConflictResolver.merge(versions, now: clock.now()),
              merged.content != current.content else { return .unchanged }

        // Only over the file this merge was computed from; if something wrote it
        // since, the next sweep redoes the merge.
        guard case let .file(latest, _) = read(url), latest == data else {
            mergeLanded = false
            return .unchanged
        }
        guard (try? write(Data(merged.content.utf8), to: url, asMerge: true)) != nil else {
            mergeLanded = false
            return .couldNotWrite
        }
        return .merged
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
    /// Asking whether the file has conflict versions goes to iCloud's daemons, and
    /// the watcher reports every outside change to the file, so the question is
    /// asked at most this often; a change that comes sooner is checked when the
    /// interval is up.
    static let conflictCheckInterval: TimeInterval = 30

    /// Where the questions for iCloud's daemons are asked; see `OffMain`.
    var offMain: OffMain = .background

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
    private var conflictRetry: ScheduledWork?
    private var conflictRetryAttempts = 0
    private var conflictCheckTask: ScheduledWork?
    private var lastConflictCheck = Date.distantPast
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
    /// Says whether a file is dataless, which is never read. A test names the files.
    var isDataless: (URL) -> Bool {
        get { file.dataless.isDataless }
        set { file.dataless.isDataless = newValue }
    }
    /// Asks iCloud for a file. A test replaces it to see which were asked for.
    var startDownload: (URL) -> Void {
        get { file.dataless.startDownload }
        set { file.dataless.startDownload = newValue }
    }
    /// This Mac's name, which a conflict version's saving computer is compared with.
    var computerName: String? {
        get { file.computerName }
        set { file.computerName = newValue }
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
        conflictCheckTask?.cancel()
        unavailableRetry?.cancel()
        rolloverTask?.cancel()
        rolloverRetry?.cancel()
        conflictRetry?.cancel()
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
        loadFile(now: now)
        // After the file is read: another Mac's text may be only in a conflict
        // version, and asking for those is slow. The document holds nothing unsaved
        // here: every caller wrote it first.
        checkConflictVersions(force: true)
    }

    private func loadFile(now: Date) {
        unavailableRetry?.cancel()
        unavailableRetry = nil
        day = calendar.startOfDay(for: now)
        url = DailyNote.resolvedURL(for: day, settings: settings)
        file.url = url
        // Before reading: a duplicate left by an earlier collision holds text
        // that belongs in the file about to be loaded.
        healDuplicates(now: now)

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
            file.dataless.request(url)
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
        adopt(DailyNote.renderedTemplate(for: day, fileURL: url, settings: settings, dataless: file.dataless) ?? "", unavailable: false)
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
        refreshFromDisk(forcingConflictCheck: false)
    }

    private func refreshFromDisk(forcingConflictCheck: Bool) {
        guard url != nil else { return }
        // A duplicate arrives as an ordinary new file in the folder watched.
        // Heal first so the read below picks up the merged text. The typing is
        // written before that, so the healed file has it: merged afterwards it
        // would come back as a second copy.
        if duplicateSweepIsDue(now: clock.now()) { flush() }
        healDuplicatesIfDue(now: clock.now())
        checkConflictVersions(force: forcingConflictCheck)
        adoptDiskState()
    }

    /// Take what the file holds now into the buffer, as an outside change.
    private func adoptDiskState() {
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

    /// Ask whether today's file has conflict versions, off the main thread, and merge
    /// them when it does. Rate-limited to `conflictCheckInterval`; a check that is
    /// not due yet is made when it is.
    private func checkConflictVersions(force: Bool) {
        guard let url = url else { return }
        let now = clock.now()
        let wait = Self.conflictCheckInterval - now.timeIntervalSince(lastConflictCheck)
        if !force, wait > 0 {
            if conflictCheckTask == nil {
                conflictCheckTask = scheduler.schedule(after: wait) { [weak self] in
                    self?.conflictCheckTask = nil
                    self?.checkConflictVersions(force: true)
                }
            }
            return
        }
        lastConflictCheck = now
        conflictCheckTask?.cancel()
        conflictCheckTask = nil
        let provider = UncheckedSendable(file.conflictVersionsProvider)
        offMain.ask({ UncheckedSendable(provider.value(url)) }) { [weak self] found in
            guard let self, self.url == url else { return }
            self.resolveConflictVersions(found.value)
        }
    }

    /// Merge iCloud's conflict versions of today's file. Unsaved typing is written
    /// first, so the merge is made with it: merged afterwards, a version that
    /// already holds the typing comes back as a second copy of it. If that write
    /// fails, or the merged text cannot be written, a retry is armed.
    private func resolveConflictVersions(_ conflicts: [NoteStore.ConflictVersionHandle]) {
        conflictRetry?.cancel()
        conflictRetry = nil
        guard !conflicts.isEmpty else {
            conflictRetryAttempts = 0
            return
        }
        guard flush() else {
            armConflictRetry()
            return
        }
        if file.resolveConflictsReporting(conflicts) == .couldNotWrite {
            armConflictRetry()
        } else {
            conflictRetryAttempts = 0
        }
        // Asked for after the folder's change was already taken in: the merge is a change too.
        adoptDiskState()
    }

    /// A merge that waited on a write, or could not be written, is tried again
    /// with a growing delay, as a save is, instead of waiting for the next change.
    private func armConflictRetry() {
        let delay = min(NoteDocument.retryDelay * pow(2, Double(conflictRetryAttempts)), NoteDocument.maxRetryDelay)
        conflictRetryAttempts += 1
        conflictRetry = scheduler.schedule(after: delay) { [weak self] in
            guard let self = self else { return }
            self.conflictRetry = nil
            self.refreshFromDisk(forcingConflictCheck: true)
        }
    }

    private func healDuplicates(now: Date) {
        guard let url = url else { return }
        lastDuplicateSweep = now
        let dataless = file.dataless
        DailyNote.healDuplicates(
            in: url.deletingLastPathComponent(), now: now, dataless: dataless,
            write: { DailyFile.replaceFile(at: $0, with: $1, expecting: $2, at: now, dataless: dataless) != nil }
        )
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
              let templated = DailyNote.renderedTemplate(for: day, fileURL: url, settings: settings, dataless: file.dataless)
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
            guard let written = DailyFile.replaceFile(
                at: url, with: templated, expecting: onDisk.fingerprint, at: clock.now(), asMerge: false
            ) else {
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
