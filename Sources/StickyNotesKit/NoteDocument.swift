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
        case externalDeletion
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

    /// What the last write put on disk, or what the window was handed. The file
    /// watcher reports our own writes back, and a mid-typing echo carries the
    /// previous text; comparing against this tells it from someone else's edit.
    /// Also the baseline for "unsaved". After an outside version is adopted it
    /// is that version, which may not be on disk yet because every adopting
    /// path saves right after.
    private var persistedContent: String
    private var persistedTitle: String

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

    /// `note` is as just saved or as last read, so the watcher's echo of it is
    /// not an outside edit. The file is read once here: if it holds what `note`
    /// does, its fingerprint is the baseline for saves. A note with no file yet
    /// starts with none, and one whose file differs from `note` too, so its
    /// first save merges with the file rather than replacing it.
    init(note: Note, repository: NoteRepository, scheduler: Scheduler = MainScheduler(), clock: AppClock = SystemClock()) {
        buffer = note
        persistedContent = note.content
        persistedTitle = note.title
        self.repository = repository
        self.scheduler = scheduler
        self.clock = clock
        persistedFingerprint = Self.fingerprint(of: repository.snapshot(id: note.id, archived: false), matching: note)
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
        buffer = note
        persistedContent = note.content
        persistedTitle = note.title
        persistedFingerprint = fingerprint
        wasNeverEdited = true
        isClosed = false
    }

    // MARK: - Changes from the person

    /// A change to what the person wrote or chose: text, title, labels, colour.
    /// Counts as an edit, so the note is no longer disposable, and arms a save.
    func edit(_ change: (inout Note) -> Void) {
        change(&buffer)
        wasNeverEdited = false
        scheduleSave()
    }

    func setBody(_ text: String) { edit { $0.content = text } }
    func setTitle(_ text: String) { edit { $0.title = text } }

    /// A change to how the note sits on the desk, or one that never marked a
    /// note as touched. Arms a save unless `save` is false, for a change the
    /// caller reports with `requestSave` once it has made all of them.
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
        guard let snapshot = repository.snapshot(id: buffer.id, archived: false) else { return }
        externalChange(snapshot.note, fingerprint: snapshot.fingerprint)
    }

    /// An outside version of the note, as read from disk. `fingerprint` is that
    /// of the file it came from, when the reader has it.
    func externalChange(_ updated: Note, fingerprint: Fingerprint? = nil) {
        // Our own write, echoed back by the watcher. Mid-burst it is the text as
        // of the last debounce, which is not an outside edit.
        if updated.content == persistedContent, updated.title == persistedTitle { return }
        if updated.content == buffer.content, updated.title == buffer.title { return }

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

    /// The window lost focus: fold in an outside edit that was held back.
    @discardableResult
    func blur() -> Bool {
        guard pendingExternal != nil, !isClosed else { return true }
        mergePendingExternal()
        return persist()
    }

    /// Fold a held-back outside edit into what the person has been typing. The
    /// buffer has not necessarily been saved yet, so writing either side over
    /// the other loses text; `ConflictResolver` keeps both.
    ///
    /// `fingerprint` is that of the file `external` was read from, when known;
    /// otherwise the file is read again.
    private func mergePendingExternal(fingerprint: Fingerprint? = nil) {
        guard let external = pendingExternal else { return }
        pendingExternal = nil

        // Nothing of the person's own to protect: take the outside note as it is.
        // Merging would let the newer local stamp win, and an empty base is
        // never a superset, so the outside text would come back appended under
        // a "Conflicted copy" divider.
        if Self.isBlank(buffer) {
            var taken = external
            taken.labels = buffer.labels + external.labels.filter { !buffer.labels.contains($0) }
            apply(taken, from: external, fingerprint: fingerprint)
            return
        }

        var local = buffer
        local.updatedAt = clock.now()

        // The title is edited in its own field, and `needsMerge` only weighs
        // bodies and labels, so a title-only difference used to fall through
        // to "apply theirs" and wipe a rename the person was still typing.
        let localTitleWins = local.title != external.title && isEditingTitle()

        guard ConflictResolver.needsMerge([local, external]),
              var merged = ConflictResolver.merge([local, external], now: clock.now())
        else {
            if localTitleWins { return }
            apply(external, from: external, fingerprint: fingerprint)
            return
        }
        if localTitleWins { merged.title = local.title }
        apply(merged, from: external, fingerprint: fingerprint)
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

        // The buffer now is this version, so it is what the buffer is compared
        // against. A stale record made every later outside edit look like it
        // landed on unsaved work and get deferred.
        persistedContent = updated.content
        persistedTitle = updated.title
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

    private func scheduleSave(after delay: TimeInterval = NoteDocument.debounce) {
        guard !isClosed else { return }
        saveTask?.cancel()
        saveTask = scheduler.schedule(after: delay) { [weak self] in
            guard let self = self else { return }
            // Clear first: leaving it set made `flush` believe a save was still
            // owed, so quitting rewrote every open note.
            self.saveTask = nil
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
    @discardableResult
    private func persist() -> Bool {
        guard !isClosed else { return true }
        for _ in 0..<Self.maxSaveAttempts {
            buffer.updatedAt = clock.now()
            switch repository.save(buffer, expecting: persistedFingerprint) {
            case .failed:
                scheduleSave(after: Self.retryDelay)
                return false
            case let .saved(fingerprint):
                markPersisted()
                persistedFingerprint = fingerprint
                return true
            case .gone:
                markPersisted()
                return true
            case let .conflict(onDisk, fingerprint):
                // The newest outside version replaces any held-back older one.
                pendingExternal = onDisk
                mergePendingExternal(fingerprint: fingerprint)
                // Set even when the merge kept the buffer as it was, or the same
                // conflict would come back every time.
                persistedFingerprint = fingerprint
            }
        }
        scheduleSave(after: Self.retryDelay)
        return false
    }

    private func markPersisted() {
        persistedContent = buffer.content
        persistedTitle = buffer.title
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
        case .externalDeletion:
            // An armed save would resurrect the file just as the window goes.
            isClosed = true
            return .closed(archived: nil)
        case .discard:
            foldInOutsideText()
            // The note holds text after all; the window shows it, so keep it open.
            guard Self.isBlank(buffer) else { return .refused }
            discard()
            return .closed(archived: nil)
        case .archive:
            foldInOutsideText()
            if Self.isBlank(buffer) {
                discard()
                return .closed(archived: nil)
            }
            // `archive` only moves the file on disk, so anything typed since the
            // last save has to land first, an outside edit held back included.
            mergePendingExternal()
            // The text is on no disk: archiving would move a file that lacks it,
            // and closing would throw it away. Stay open; the retry is armed.
            guard persist() else { return .refused }
            isClosed = true
            repository.archive(buffer)
            return .closed(archived: buffer)
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

    private func discard() {
        isClosed = true
        repository.discardActive(buffer)
    }
}
