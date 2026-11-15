import Foundation

/// One note being edited: the text and settings the person sees, what was last
/// written to disk, and the rules that keep the two from losing each other's
/// changes. It owns the save debounce, the filter for the file watcher's echo
/// of its own writes, and the merge of an outside edit that arrived while the
/// person was typing. It has no UI: a window forwards typing in and draws
/// `buffer`.
///
/// Every note that is not today's daily note is edited through one of these.
final class NoteDocument {
    enum CloseReason {
        /// The person closed the note: it goes to the archive, unless it is empty.
        case archive
        /// Throw the note away without archiving it, as for an untouched capture.
        case discard
        /// The file is gone or moved; whoever removed it already owns the note.
        /// Text typed since the last save is written where the note went first.
        case externalDeletion
        /// As `externalDeletion`, for text the caller has already put in a
        /// recovery file because the store could not take it.
        case externalDeletionTextKept
    }

    /// Where text typed into a note whose file was archived or removed from
    /// under it was written.
    enum KeptIn {
        case archive
        case trash
        /// A copy in the trash: the note exists nowhere else.
        case recoveredCopy
    }

    enum CloseResult {
        /// The document is closed. `archived` is the note as archived, for undo,
        /// and is nil when the note was discarded or its file was already gone.
        case closed(archived: Note?)
        /// Nothing was closed: the text could not be written (a retry is armed),
        /// or a note about to be discarded turned out to hold text.
        case refused
    }

    /// Which parts of the buffer an outside version replaced.
    struct Applied {
        var title = false
        var labels = false
        var content = false
    }

    /// How long a pause in typing must last before the note is written.
    static let debounce: TimeInterval = 0.5
    /// How long to wait before trying again after a write that did not land.
    static let retryDelay: TimeInterval = 5
    /// A write that keeps failing is tried again after twice as long each time,
    /// up to this, so a cause that lasts does not cost a retry every few seconds.
    static let maxRetryDelay: TimeInterval = 300

    /// The note as the person sees it, ahead of the file by whatever is unsaved.
    private(set) var buffer: Note

    /// An outside edit that arrived while the buffer held unsaved work or the
    /// caret was in the note. Held back so the text does not jump, and merged,
    /// never dropped, before the next save.
    private(set) var pendingExternal: Note?

    /// True until the person changes this note. An untouched note left by a
    /// misfired hotkey is swept up on blur; one that was edited never is, even
    /// if it is empty now.
    private(set) var wasNeverEdited = true

    /// False for a new note that no file was ever written for. Such a note is
    /// not gone when its file is missing.
    private(set) var hasFile: Bool

    /// Set for a note that is created blank by the person asking for a new one:
    /// it gets its file with the first edit, and none if it is left untouched.
    /// Writing it sooner would make every misfired hotkey a create and a delete
    /// in a synced vault.
    var createsFileOnFirstEdit = false

    /// The person changed the note since the last write that landed.
    private var unsavedEdit = false

    /// The note's active file is gone and the text could not be written where
    /// the note went either, so it is on no disk. A person's close is then
    /// refused for a reason that waiting will not fix quickly.
    private(set) var isStranded = false

    /// The last write was refused because the note's file cannot be read or
    /// found, so the text is on no disk and a retry may be a long time coming.
    private(set) var fileCannotBeRead = false

    private var retryAttempts = 0
    private var retryArmed = false
    private var armedRetryDelay: TimeInterval = 0

    /// The active file was found gone and the text went to the archive, the
    /// trash or a recovered copy, so the note is no longer there to archive.
    private var activeFileGone = false

    /// What the last write put on disk, or what the window was handed. The file
    /// watcher reports our own writes back, and a mid-typing echo carries the
    /// previous text; comparing against this tells it from someone else's edit.
    /// Also the baseline for "unsaved". After an outside version is adopted it
    /// is that version, which may not be on disk yet because every adopting
    /// path saves right after.
    private var persistedContent: String
    private var persistedTitle: String
    private var persistedLabels: [String]

    /// The fingerprint of the file as this document last wrote or read it, the
    /// one every save is checked against. Nil means no file is expected: the
    /// note is being created, or what the file holds is not known, and a save
    /// then finds the file as a conflict and merges with it instead of
    /// overwriting it.
    private(set) var persistedFingerprint: Fingerprint?

    /// How many times one save merges with a file that changed under it before
    /// giving up and arming a retry.
    static let maxSaveAttempts = 3

    private let repository: NoteRepository
    private let scheduler: Scheduler
    private let clock: AppClock
    private var saveTask: ScheduledWork?
    private var isClosed = false

    /// True while the caret is in this note and the window would be disturbed by
    /// text changing under it. Read each time a decision needs it.
    var isEditing: () -> Bool = { false }
    /// True while the title is being typed, which makes the title the person's.
    var isEditingTitle: () -> Bool = { false }
    /// Called after an outside version replaced part of the buffer, with what
    /// changed, so the view can redraw it.
    var didApplyExternal: (Applied) -> Void = { _ in }
    /// Called after text typed into a note that left the active folder was
    /// written somewhere else, so the person can be told where it is.
    var didKeepText: (KeptIn) -> Void = { _ in }

    /// `note` is as just saved or as last read, so the watcher's echo of it is
    /// not an outside edit. The file is read once here: if it holds what `note`
    /// does, its fingerprint is the baseline for saves. A note with no file yet
    /// starts with none, and one whose file differs from `note` too, so its
    /// first save merges with the file rather than replacing it.
    init(note: Note, repository: NoteRepository, scheduler: Scheduler = MainScheduler(), clock: AppClock = SystemClock()) {
        buffer = note
        persistedContent = note.content
        persistedTitle = note.title
        persistedLabels = note.labels
        self.repository = repository
        self.scheduler = scheduler
        self.clock = clock
        let snapshot = repository.snapshot(id: note.id, archived: false)
        repository.textAdopted(note.content, over: nil, ofNote: note.id)
        persistedFingerprint = Self.fingerprint(of: snapshot, matching: note)
        // A document that has seen the file has seen its properties too.
        if persistedFingerprint != nil, let snapshot { buffer.preserved = snapshot.note.preserved }
        hasFile = snapshot != nil
    }

    /// The snapshot's fingerprint when the snapshot holds the same text as
    /// `note`, so a document that adopts that fingerprint has seen the file.
    private static func fingerprint(of snapshot: NoteSnapshot?, matching note: Note) -> Fingerprint? {
        guard let snapshot, hasSameText(snapshot.note, note) else { return nil }
        return snapshot.fingerprint
    }

    private static func hasSameText(_ a: Note, _ b: Note) -> Bool {
        a.content == b.content && a.title == b.title && a.labels == b.labels
    }

    var id: UUID { buffer.id }

    /// Start over from `note`, as just read from disk: the buffer, the baseline
    /// and every armed save or held-back edit are replaced. For an owner whose
    /// document moves to another file, such as the daily note on a new day. The
    /// caller must have saved or kept whatever the buffer held. `fingerprint` is
    /// that of the file `note` was read from, or nil when there is no file yet.
    func reset(to note: Note, fingerprint: Fingerprint? = nil) {
        saveTask?.cancel()
        saveTask = nil
        pendingExternal = nil
        repository.textAdopted(note.content, over: nil, ofNote: note.id)
        buffer = note
        persistedContent = note.content
        persistedTitle = note.title
        persistedLabels = note.labels
        persistedFingerprint = fingerprint
        hasFile = fingerprint != nil
        unsavedEdit = false
        activeFileGone = false
        wasNeverEdited = true
        isClosed = false
    }

    // MARK: - Changes from the person

    /// A change to what the person wrote or chose: text, title, labels, colour.
    /// Counts as an edit, so the note is no longer disposable, and arms a save.
    func edit(_ change: (inout Note) -> Void) {
        change(&buffer)
        wasNeverEdited = false
        unsavedEdit = true
        scheduleSave()
    }

    func setBody(_ text: String) { edit { $0.content = text } }
    func setTitle(_ text: String) { edit { $0.title = text } }

    /// A change that never marked the note as touched, such as a label removed.
    /// Arms a save unless `save` is false, for a change the caller reports with
    /// `requestSave` once it has made all of them, or one that is not saved at
    /// all, such as the size hint, which goes out with the next content save.
    func adjust(save: Bool = true, _ change: (inout Note) -> Void) {
        change(&buffer)
        if save { scheduleSave() }
    }

    func requestSave() { scheduleSave() }

    // MARK: - Unsaved work

    /// True when the buffer holds text that has not reached disk: a save is
    /// still armed, or what was last written no longer matches.
    var hasUnsavedEdits: Bool {
        saveTask != nil || buffer.content != persistedContent || buffer.title != persistedTitle
    }

    /// True when the buffer holds a change the person made, or a merge's result,
    /// that no file holds. A move of the window alone is not that: losing it
    /// costs nothing worth a recovered copy.
    private var holdsTextNoFileHas: Bool {
        unsavedEdit || buffer.content != persistedContent || buffer.title != persistedTitle
    }

    /// A note is disposable when nothing was ever typed into it and it holds
    /// nothing, the shape a mis-pressed hotkey leaves behind.
    var isAbandonedCapture: Bool {
        wasNeverEdited && Self.isBlank(buffer)
    }

    private static func isBlank(_ note: Note) -> Bool {
        note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Outside changes

    /// Something other than this document may have rewritten the note's file.
    /// The file is read, not the store's cache, because the fingerprint of the
    /// bytes is what keeps the next save from overwriting this version.
    func storeDidChange() {
        // Something changed on disk, which may be what a failing write was
        // waiting for: start the backoff over, and bring an armed retry forward.
        retryAttempts = 0
        if retryArmed, armedRetryDelay > Self.retryDelay { scheduleRetry() }
        guard let snapshot = repository.snapshot(id: buffer.id, archived: false) else { return }
        hasFile = true
        externalChange(snapshot.note, fingerprint: snapshot.fingerprint)
    }

    /// An outside version of the note, as read from disk. `fingerprint` is that
    /// of the file it came from, when the reader has it.
    func externalChange(_ updated: Note, fingerprint: Fingerprint? = nil) {
        hasFile = true
        // Properties the app does not own are the file's, whatever happens to
        // the text below, so the next save writes them back as they are now.
        buffer.preserved = updated.preserved
        // Our own write, echoed back by the watcher. Mid-burst it is the text as
        // of the last debounce, which is not an outside edit.
        // The file may still be new to us: a rewrite that kept the text, such as a
        // move on the other Mac or a property edited in Obsidian. Its fingerprint
        // is taken, or the next save would meet it as a conflict. Labels the
        // buffer lacks are decided below, with the rest of the merge.
        if updated.content == persistedContent, updated.title == persistedTitle,
           Set(updated.labels) == Set(persistedLabels) {
            adoptFingerprint(fingerprint, ifLabelsMatch: updated)
            return
        }
        if updated.content == buffer.content, updated.title == buffer.title, Set(updated.labels) == Set(buffer.labels) {
            // The file holds what the buffer holds, so that is the base now.
            persistedContent = updated.content
            persistedTitle = updated.title
            persistedLabels = updated.labels
            adoptFingerprint(fingerprint, ifLabelsMatch: updated)
            return
        }

        // Anything typed since the last write only exists in this buffer, so
        // applying the incoming version over it would discard it. Defer and let
        // the merge decide, the rule every save path follows. Whether the window
        // is key was not enough: clicking the note's own title bar mid-sentence
        // drops first responder, and the next change would take the text with it.
        if hasUnsavedEdits {
            pendingExternal = updated
            return
        }
        // No unsaved work, but still not under a caret that sits in the text.
        if isEditing() {
            pendingExternal = updated
            return
        }
        apply(updated, from: updated, fingerprint: fingerprint)
    }

    private func adoptFingerprint(_ fingerprint: Fingerprint?, ifLabelsMatch note: Note) {
        guard let fingerprint, note.labels == buffer.labels else { return }
        persistedFingerprint = fingerprint
    }

    /// The window lost focus: fold in an outside edit that was held back.
    @discardableResult
    func blur() -> Bool {
        guard pendingExternal != nil, !isClosed else { return true }
        mergePendingExternal()
        return persist()
    }

    /// Fold a held-back outside edit into what the person has been typing. The
    /// buffer has not necessarily been saved yet, so writing either side over
    /// the other loses text.
    ///
    /// What the document last wrote or read is the base of a three-way merge,
    /// decided for the body and the title separately. A part only one side
    /// changed away from the base is that side's, with no merge: a properties-only
    /// rewrite never reverts the person's typing, and an untouched buffer takes
    /// the outside text whole. A body both sides changed is merged by
    /// `ConflictResolver`, which keeps both, unless the outside body is an earlier
    /// write of this Mac's own, which adds nothing. A title both sides changed stays the
    /// person's, and the other is added to the text as an "Also titled" line.
    /// Labels follow the same rule as the body: added together only when both
    /// sides changed them.
    ///
    /// `fingerprint` is that of the file `external` was read from, when known.
    /// Otherwise the file is read again, and its newest version is merged in
    /// place of the held-back one, so a file that changed twice is merged once.
    private func mergePendingExternal(fingerprint knownFingerprint: Fingerprint? = nil) {
        guard var external = pendingExternal else { return }
        pendingExternal = nil
        var fingerprint = knownFingerprint
        if fingerprint == nil, let fresh = repository.snapshot(id: buffer.id, archived: false) {
            external = fresh.note
            fingerprint = fresh.fingerprint
        }

        // Each part is decided on its own, against the base.
        var taken = buffer
        let externalChangedBody = external.content != persistedContent
        let localChangedBody = buffer.content != persistedContent
        if externalChangedBody {
            if !localChangedBody {
                taken.content = external.content
            } else if repository.isEarlierOwnBody(external.content, ofNote: buffer.id),
                      ConflictResolver.isCovered(external.content, by: persistedContent) {
                // An older copy of what the person wrote, put back by Obsidian or
                // a sync: every line in it was typed here, and it adds nothing to
                // what the window last wrote or read, so the buffer is kept.
                // One that has a line the base lacks may be a restore the other
                // Mac made on purpose, and is merged like any outside text.
                taken.content = buffer.content
            } else {
                taken.content = Self.mergedBody(
                    base: persistedContent, local: buffer.content,
                    external: external.content, externalDate: external.updatedAt, now: clock.now()
                )
            }
        }

        let externalChangedTitle = external.title != persistedTitle
        let localChangedTitle = buffer.title != persistedTitle
        if externalChangedTitle && external.title != buffer.title {
            if !localChangedTitle || buffer.title.isEmpty {
                taken.title = external.title
            } else if !external.title.isEmpty {
                // Both renamed it: the person's title stays, and the other is kept
                // as text, as `ConflictResolver` does.
                let line = "Also titled: \(external.title)"
                if !taken.content.contains(line) { taken.content += "\n\n" + line }
            }
        }

        // Labels are decided like the body: a set only the outside changed is the
        // outside's, so a label removed in Obsidian stays removed, and only a set
        // both sides changed is added together.
        if Set(external.labels) != Set(persistedLabels) {
            let localChangedLabels = Set(buffer.labels) != Set(persistedLabels)
            taken.labels = localChangedLabels
                ? buffer.labels + external.labels.filter { !buffer.labels.contains($0) }
                : external.labels
        }
        taken.preserved = external.preserved
        apply(taken, from: external, fingerprint: fingerprint)
    }

    /// Merge a body both sides changed. When one side only added lines at the end
    /// of the base, that addition is put at the end of the other side's version,
    /// so the other side's edits and deletions stand. Anything else is
    /// `ConflictResolver`'s: both texts are kept.
    private static func mergedBody(base: String, local: String, external: String, externalDate: Date, now: Date) -> String {
        func appendedLines(in changed: String) -> String? {
            guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  changed.hasPrefix(base) else { return nil }
            let tail = String(changed.dropFirst(base.count))
            guard !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  tail.hasPrefix("\n") || base.hasSuffix("\n") else { return nil }
            return tail
        }
        if let tail = appendedLines(in: local) {
            return external.contains(tail) ? external : external + tail
        }
        if let tail = appendedLines(in: external) {
            return local.contains(tail) ? local : local + tail
        }
        return ConflictResolver.mergeBodies(local: local, external: external, externalDate: externalDate, now: now)
    }

    /// Make `updated` the buffer's text. It came from the outside version
    /// `source`, which the next save must not overwrite unseen, so the
    /// fingerprint is brought up to the file that version was read from.
    private func apply(_ updated: Note, from source: Note, fingerprint: Fingerprint?) {
        if let fingerprint {
            persistedFingerprint = fingerprint
        } else if let fresh = Self.fingerprint(
            of: repository.snapshot(id: buffer.id, archived: false), matching: source
        ) {
            persistedFingerprint = fresh
        }
        // Otherwise the file has moved on since `source` was read, and the stale
        // fingerprint stays, so the next save meets it as a conflict and merges.

        // The file holds `source`, so that is the baseline the buffer is compared
        // against; a merged buffer differs from it until the save that follows.
        // A stale record made every later outside edit look like it landed on
        // unsaved work and get deferred.
        repository.textAdopted(updated.content, over: buffer.content, ofNote: buffer.id)
        persistedContent = source.content
        persistedTitle = source.title
        persistedLabels = source.labels
        buffer.preserved = updated.preserved
        var applied = Applied()
        if updated.title != buffer.title {
            buffer.title = updated.title
            applied.title = true
        }
        if updated.labels != buffer.labels {
            buffer.labels = updated.labels
            applied.labels = true
        }
        if updated.content != buffer.content {
            buffer.content = updated.content
            applied.content = true
        }
        didApplyExternal(applied)
    }

    // MARK: - Saving

    private func scheduleRetry() {
        let delay = min(Self.retryDelay * pow(2, Double(retryAttempts)), Self.maxRetryDelay)
        retryAttempts += 1
        scheduleSave(after: delay, isRetry: true)
    }

    private func scheduleSave(after delay: TimeInterval = NoteDocument.debounce, isRetry: Bool = false) {
        guard !isClosed else { return }
        if createsFileOnFirstEdit, !hasFile, wasNeverEdited, Self.isBlank(buffer) { return }
        retryArmed = isRetry
        armedRetryDelay = delay
        saveTask?.cancel()
        saveTask = scheduler.schedule(after: delay) { [weak self] in
            guard let self = self else { return }
            // Clear first: leaving it set made `flush` believe a save was still
            // owed, so quitting rewrote every open note.
            self.saveTask = nil
            self.retryArmed = false
            guard !self.isClosed else { return }
            // A held-back outside edit has to be folded in first, or this write
            // silently overwrites it.
            self.mergePendingExternal()
            self.persist()
        }
    }

    /// Write the note and remember exactly what went to disk.
    ///
    /// The write is checked against the fingerprint of the file as this document
    /// last read or wrote it. When the file has changed since, nothing is
    /// overwritten: that version is merged into the buffer the way any outside
    /// edit is, and the save is tried again against it. A file that keeps
    /// changing under the save is given up on after `maxSaveAttempts`; the
    /// buffer keeps the merged text and counts as unsaved.
    ///
    /// A write that did not land does not mark the buffer as persisted, so it
    /// still counts as unsaved, and another attempt is armed. Returns false for
    /// that case, so a caller about to archive or close can stop. A note whose
    /// file is gone returns true: there is nothing to retry, and the window is
    /// closed by the reconcile that found it gone.
    ///
    /// A note whose file is gone does not mark typing as saved. Text typed since
    /// the last write is put where the note went: into its file in the archive
    /// or the trash, merged with what that file holds, or into a recovered copy
    /// in the trash when the note exists nowhere. Only when that lands does the
    /// buffer count as persisted; otherwise a retry is armed.
    @discardableResult
    private func persist() -> Bool {
        guard !isClosed else { return true }
        fileCannotBeRead = false
        for _ in 0..<Self.maxSaveAttempts {
            buffer.updatedAt = clock.now()
            switch repository.save(buffer, expecting: persistedFingerprint) {
            case let .failed(error):
                switch error as? SaveError {
                case .unreadableOnDisk?, .locationUnknown?: fileCannotBeRead = true
                case nil: fileCannotBeRead = false
                }
                scheduleRetry()
                return false
            case let .saved(fingerprint):
                markPersisted()
                hasFile = true
                activeFileGone = false
                persistedFingerprint = fingerprint
                return true
            case .gone:
                guard repository.canKeepTextElsewhere, holdsTextNoFileHas else {
                    markPersisted()
                    return true
                }
                switch keepTextElsewhere() {
                case .done: return true
                case .again: continue
                case .failed:
                    isStranded = true
                    scheduleRetry()
                    return false
                }
            case let .conflict(onDisk, fingerprint):
                hasFile = true
                // The newest outside version replaces any held-back older one.
                pendingExternal = onDisk
                mergePendingExternal(fingerprint: fingerprint)
                // Set even when the merge kept the buffer as it was, or the same
                // conflict would come back every time.
                persistedFingerprint = fingerprint
            }
        }
        scheduleRetry()
        return false
    }

    private func markPersisted() {
        retryAttempts = 0
        isStranded = false
        fileCannotBeRead = false
        persistedContent = buffer.content
        persistedTitle = buffer.title
        persistedLabels = buffer.labels
        unsavedEdit = false
    }

    private enum Kept {
        case done
        /// The situation changed under the attempt: look again.
        case again
        case failed
    }

    /// The active file is gone. Write the buffer where the note went.
    private func keepTextElsewhere() -> Kept {
        switch repository.whereIs(id: buffer.id) {
        case let .active(snapshot):
            // Found again by a rescan: the file is back, so save against it as
            // for any outside version.
            pendingExternal = snapshot.note
            mergePendingExternal(fingerprint: snapshot.fingerprint)
            persistedFingerprint = snapshot.fingerprint
            return .again
        case let .archived(snapshot):
            return keepText(in: .archive, over: snapshot, as: .archive)
        case let .trashed(snapshot):
            return keepText(in: .trash, over: snapshot, as: .trash)
        case .missing:
            guard repository.saveRecoveredCopy(of: buffer) else { return .failed }
            finishKeeping(in: .recoveredCopy)
            return .done
        case .unknown:
            return .failed
        }
    }

    /// Merge what the file in the archive or trash holds into the buffer, as
    /// for any outside version, then write the result over exactly that file.
    private func keepText(in folder: NoteStore.Folder, over snapshot: NoteSnapshot, as place: KeptIn) -> Kept {
        pendingExternal = snapshot.note
        mergePendingExternal(fingerprint: snapshot.fingerprint)
        buffer.updatedAt = clock.now()
        switch repository.save(buffer, in: folder, expecting: snapshot.fingerprint) {
        case let .saved(fingerprint):
            persistedFingerprint = fingerprint
            finishKeeping(in: place)
            return .done
        case .conflict, .gone:
            return .again
        case .failed:
            return .failed
        }
    }

    private func finishKeeping(in place: KeptIn) {
        markPersisted()
        activeFileGone = true
        didKeepText(place)
    }

    /// Write any debounced edit now. Saves are debounced, so quitting mid-sentence
    /// would otherwise drop everything typed since the last pause.
    ///
    /// Returns false when the text did not reach disk, so a caller about to end
    /// the process can save it somewhere else.
    @discardableResult
    func flush() -> Bool {
        guard saveTask != nil, !isClosed else { return true }
        saveTask?.cancel()
        saveTask = nil
        mergePendingExternal()
        return persist()
    }

    // MARK: - Closing

    func close(_ reason: CloseReason) -> CloseResult {
        saveTask?.cancel()
        saveTask = nil
        switch reason {
        case .externalDeletionTextKept:
            // An armed save would resurrect the file just as the window goes.
            isClosed = true
            return .closed(archived: nil)
        case .externalDeletion:
            // The note is gone from the active folder, but text typed into it
            // must not go with the window. Where that cannot be written the
            // window stays, and a retry is armed.
            if holdsTextNoFileHas {
                mergePendingExternal()
                guard persist() else { return .refused }
            }
            isClosed = true
            return .closed(archived: nil)
        case .discard, .archive:
            foldInOutsideText()
            if Self.isBlank(buffer) {
                discard()
                return .closed(archived: nil)
            }
            // Text arrived from outside: the window shows it, so keep it open.
            guard reason == .archive else { return .refused }
            // `archive` only moves the file on disk, so anything typed since the
            // last save has to land first, an outside edit held back included.
            mergePendingExternal()
            // The text is on no disk: archiving would move a file that lacks it,
            // and closing would throw it away. Stay open; the retry is armed.
            guard persist() else { return .refused }
            isClosed = true
            repository.archive(buffer)
            // Nothing was archived, and so nothing is there to undo, when the
            // note had already left the active folder.
            return .closed(archived: activeFileGone ? nil : buffer)
        }
    }

    /// A blank note is deleted, so whatever outside text it holds must be taken
    /// in first: an edit held back, or one the file watcher has not reported
    /// yet, which only the file itself shows.
    private func foldInOutsideText() {
        mergePendingExternal()
        guard Self.isBlank(buffer), pendingExternal == nil,
              let snapshot = repository.snapshot(id: buffer.id, archived: false),
              !Self.isBlank(snapshot.note),
              snapshot.note.content != persistedContent || snapshot.note.title != persistedTitle else { return }
        pendingExternal = snapshot.note
        mergePendingExternal(fingerprint: snapshot.fingerprint)
    }

    /// A note that never had a file has nothing to remove, and a removal is
    /// announced to every window.
    private func discard() {
        isClosed = true
        guard hasFile || repository.snapshot(id: buffer.id, archived: false) != nil else { return }
        repository.discardActive(buffer)
    }
}
