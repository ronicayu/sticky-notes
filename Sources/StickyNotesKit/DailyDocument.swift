import Foundation

/// Today's daily note as a `NoteRepository`: one raw Markdown file, no
/// frontmatter, so Obsidian and its plugins stay authoritative for formatting.
/// A document edits it as a note whose body is the file's text.
final class DailyFile: NoteRepository {
    /// The file the document is on now; nil when no vault or pattern is set,
    /// in which case there is nowhere to write and nothing is kept.
    var url: URL?
    private let clock: AppClock
    private let id = UUID()

    init(clock: AppClock) {
        self.clock = clock
    }

    func note(body: String) -> Note {
        let now = clock.now()
        return Note(
            id: id, content: body,
            positionX: 0, positionY: 0, width: 0, height: 0,
            collapsed: false, color: .yellow, createdAt: now, updatedAt: now
        )
    }

    @discardableResult
    func save(_ note: Note) -> SaveResult {
        guard let url = url else { return .gone }
        do {
            // Obsidian creates the folder lazily; so do we, rather than
            // failing the first write.
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = Data(note.content.utf8)
            try data.write(to: url, options: .atomic)
            return .saved(Fingerprint(of: data))
        } catch {
            return .failed(error)
        }
    }

    func loadNote(id: UUID, archived: Bool) -> Note? {
        snapshot(id: id, archived: archived)?.note
    }

    func snapshot(id: UUID, archived: Bool) -> NoteSnapshot? {
        guard let url = url, let data = try? Data(contentsOf: url),
              let body = String(data: data, encoding: .utf8) else { return nil }
        return NoteSnapshot(note: note(body: body), fingerprint: Fingerprint(of: data))
    }

    func archive(_ note: Note) {}
    func discardActive(_ note: Note) {}
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

        guard let url = url else {
            adopt("", unavailable: false)
            return
        }
        if let raw = try? String(contentsOf: url, encoding: .utf8) {
            adopt(raw, unavailable: false)
            return
        }
        // Today's note exists but cannot be read yet. Seeding the template here
        // would overwrite real content. An evicted iCloud file does not answer
        // to `fileExists`: iCloud replaces it with a hidden `.<name>.icloud`
        // stub until something asks for the download.
        if FileManager.default.fileExists(atPath: url.path) || hasICloudPlaceholder(for: url) {
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

    private func adopt(_ body: String, unavailable: Bool) {
        isUnavailable = unavailable
        document.reset(to: file.note(body: body))
        onBodyReplaced()
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func hasICloudPlaceholder(for url: URL) -> Bool {
        let stub = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: stub.path)
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
        guard let url = url else { return }
        // A duplicate arrives as an ordinary new file in the folder watched.
        // Heal first so the read below picks up the merged text.
        healDuplicatesIfDue(now: clock.now())
        // A failed read means the file is mid-sync or undecodable, not empty:
        // treating it as empty would blank the buffer and then save that over
        // the real content. If we were waiting on a download, this is it.
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return }
        if isUnavailable {
            unavailableRetry?.cancel()
            unavailableRetry = nil
            adopt(raw, unavailable: false)
            return
        }
        document.externalChange(file.note(body: raw))
    }

    private func healDuplicates(now: Date) {
        guard let url = url else { return }
        lastDuplicateSweep = now
        DailyNote.healDuplicates(in: url.deletingLastPathComponent(), now: now)
    }

    private func healDuplicatesIfDue(now: Date) {
        guard now.timeIntervalSince(lastDuplicateSweep) > Self.duplicateSweepInterval else { return }
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
        if let onDisk = try? String(contentsOf: url, encoding: .utf8), !Self.isBlank(onDisk) {
            storeDidChange()
            return
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try? templated.write(to: url, atomically: true, encoding: .utf8)
        }
        adopt(templated, unavailable: false)
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
              !hasICloudPlaceholder(for: url) else { return }
        document.requestSave()
        document.flush()
    }
}
