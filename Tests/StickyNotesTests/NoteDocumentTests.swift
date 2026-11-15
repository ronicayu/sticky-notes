import XCTest
@testable import StickyNotesKit

/// The note lifecycle with no window: a real `NoteDocument` over a real
/// `NoteStore` in a temp folder, with time moved by hand. Nothing here waits
/// for a run loop, and the caret is whatever the test says it is.
final class NoteDocumentTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var clock: ManualClock!
    private var scheduler: TestScheduler!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteDocument-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clock = ManualClock()
        scheduler = TestScheduler(clock: clock)
        store = NoteStore(rootURL: root, clock: clock)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Harness

    private func makeNote(title: String = "Note", content: String = "") -> Note {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        note.title = title
        note.content = content
        return note
    }

    /// A saved note and a document over it.
    private func open(title: String = "Note", content: String = "") -> NoteDocument {
        let note = makeNote(title: title, content: content)
        store.save(note)
        return NoteDocument(note: note, repository: store, scheduler: scheduler, clock: clock)
    }

    private func onDisk(_ document: NoteDocument) throws -> Note {
        try XCTUnwrap(store.loadNote(id: document.id), "note is not in the active folder")
    }

    private func archived(_ document: NoteDocument) throws -> Note {
        try XCTUnwrap(store.loadArchived().first { $0.id == document.id }, "note is not in the archive")
    }

    /// What Obsidian does: rewrite the file in place, behind the store's back,
    /// then the watcher reports it.
    private func writeOutside(
        _ document: NoteDocument, title: String = "Note", body: String, updated: String = "2030-01-01T00:00:00Z"
    ) throws {
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: store.activeURL, includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "md" })
        try "---\nid: \(document.id.uuidString)\ntitle: \"\(title)\"\nupdated: \(updated)\n---\n\(body)"
            .write(to: file, atomically: true, encoding: .utf8)
        store.handleFileSystemEvent()
    }

    /// An outside write that the store and the document have not been told about.
    private func writeOutsideWithoutTellingTheDocument(
        _ document: NoteDocument, title: String = "Note", body: String, updated: String = "2030-01-01T00:00:00Z"
    ) throws {
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: store.activeURL, includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "md" })
        try "---\nid: \(document.id.uuidString)\ntitle: \"\(title)\"\nupdated: \(updated)\n---\n\(body)"
            .write(to: file, atomically: true, encoding: .utf8)
    }

    /// An outside write the document hears about: the file is rewritten and the
    /// document is handed what it now holds, as the watcher would.
    private func outsideEdit(
        _ document: NoteDocument, title: String = "Note", body: String, updated: String = "2027-01-15T07:59:59Z"
    ) throws {
        try writeOutsideWithoutTellingTheDocument(document, title: title, body: body, updated: updated)
        let snapshot = try XCTUnwrap(store.snapshot(id: document.id))
        document.externalChange(snapshot.note, fingerprint: snapshot.fingerprint)
    }

    /// Makes every write into the notes folder fail, as a full disk or a
    /// revoked permission would; the folder is made writable again on teardown.
    private func failWrites() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.activeURL.path)
        let activePath = store.activeURL.path
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: activePath)
        }
    }

    private func allowWrites() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.activeURL.path)
    }

    // MARK: - Reaching disk

    func testTypingReachesDiskOnlyOnceTheDebounceElapses() throws {
        let document = open()
        document.setBody("groceries")

        scheduler.advance(by: 0.49)
        XCTAssertEqual(try onDisk(document).content, "", "saved before the debounce elapsed")
        scheduler.advance(by: 0.02)
        XCTAssertEqual(try onDisk(document).content, "groceries")
        XCTAssertFalse(document.hasUnsavedEdits)
    }

    func testEachKeystrokeRestartsTheDebounce() throws {
        let document = open()
        document.setBody("a")
        scheduler.advance(by: 0.4)
        document.setBody("ab")
        scheduler.advance(by: 0.4)

        XCTAssertEqual(try onDisk(document).content, "", "saved in the middle of a burst")
        scheduler.advance(by: 0.1)
        XCTAssertEqual(try onDisk(document).content, "ab")
    }

    func testASavedEditIsStampedWithTheClock() throws {
        let document = open()
        clock.advance(by: 86_400)
        document.setBody("a day later")
        scheduler.advance(by: 1)

        XCTAssertEqual(try onDisk(document).updatedAt.timeIntervalSince1970,
                       clock.now().timeIntervalSince1970 - 1, accuracy: 1.5)
    }

    func testTheFingerprintOfTheLastWriteIsKept() throws {
        let document = open()
        document.setBody("something")
        scheduler.advance(by: 1)

        XCTAssertNotNil(document.persistedFingerprint)
        XCTAssertEqual(document.persistedFingerprint, store.snapshot(id: document.id)?.fingerprint)
    }

    /// Quitting is the path that used to lose text: the debounce is still
    /// pending, and nothing drained it. (Regress scenario: quit flush.)
    func testFlushingWritesTextTypedSinceTheLastPause() throws {
        let document = open()
        document.setBody("half a sentence")

        XCTAssertTrue(document.flush())
        XCTAssertEqual(try onDisk(document).content, "half a sentence")
        XCTAssertEqual(scheduler.pendingCount, 0, "the debounce is still armed after a flush")
    }

    /// A note nobody typed into must not be rewritten on quit: in a synced
    /// vault that would re-upload every open note.
    func testFlushingANoteNobodyTouchedWritesNothing() throws {
        let document = open(content: "untouched")
        let before = try onDisk(document).updatedAt
        clock.advance(by: 60)

        XCTAssertTrue(document.flush())
        XCTAssertEqual(try onDisk(document).updatedAt, before, "rewrote an untouched note")
    }

    func testASaveThatAlreadyFiredIsNotWrittenAgain() throws {
        let document = open()
        document.setBody("done typing")
        scheduler.advance(by: 1)
        let after = try onDisk(document).updatedAt
        clock.advance(by: 60)

        document.flush()
        XCTAssertEqual(try onDisk(document).updatedAt, after, "flush rewrote an already-saved note")
    }

    func testChangesToTheNotesPlaceOnTheDeskAreSavedToo() throws {
        let document = open()
        document.adjust { $0.positionX = 321 }

        scheduler.advance(by: 1)
        XCTAssertEqual(try onDisk(document).positionX, 321)
    }

    func testAdjustingWithoutSavingArmsNothingUntilItIsRequested() throws {
        let document = open()
        document.adjust(save: false) { $0.positionX = 321 }
        XCTAssertEqual(scheduler.pendingCount, 0)

        document.requestSave()
        scheduler.advance(by: 1)
        XCTAssertEqual(try onDisk(document).positionX, 321)
    }

    // MARK: - A write that does not land

    /// The window used to record the text as saved before writing it, so a
    /// failed write left it looking clean and nothing tried again.
    func testAFailedSaveKeepsTheNoteDirty() throws {
        let document = open(content: "on disk")
        document.setBody("on disk plus a new thought")
        try failWrites()

        XCTAssertFalse(document.flush())
        XCTAssertEqual(try onDisk(document).content, "on disk")
        XCTAssertTrue(document.hasUnsavedEdits)

        try allowWrites()
        XCTAssertTrue(document.flush())
        XCTAssertEqual(try onDisk(document).content, "on disk plus a new thought",
                       "the failed save was not retried: the document treated its text as saved")
    }

    func testAFailedSaveIsRetriedOnItsOwnAfterTheRetryDelay() throws {
        let document = open(content: "on disk")
        document.setBody("on disk plus a new thought")
        try failWrites()
        scheduler.advance(by: 0.5)
        XCTAssertEqual(try onDisk(document).content, "on disk")
        XCTAssertEqual(scheduler.pendingCount, 1, "no retry is armed")

        try allowWrites()
        scheduler.advance(by: NoteDocument.retryDelay - 0.1)
        XCTAssertEqual(try onDisk(document).content, "on disk", "retried early")
        scheduler.advance(by: 0.2)

        XCTAssertEqual(try onDisk(document).content, "on disk plus a new thought")
        XCTAssertFalse(document.hasUnsavedEdits)
    }

    /// Archiving moves a file and closing drops the buffer: after a failed
    /// write either one loses the text.
    func testAFailedSaveDoesNotArchiveOrCloseTheNote() throws {
        let document = open(content: "on disk")
        document.setBody("on disk plus a new thought")
        try failWrites()

        guard case .refused = document.close(.archive) else { return XCTFail("closed with unsaved text") }
        XCTAssertTrue(store.loadArchived().isEmpty, "the note was archived without its text")
        XCTAssertEqual(document.buffer.content, "on disk plus a new thought")

        try allowWrites()
        guard case let .closed(archivedNote) = document.close(.archive) else { return XCTFail("still refused") }
        XCTAssertEqual(archivedNote?.content, "on disk plus a new thought")
        XCTAssertEqual(try archived(document).content, "on disk plus a new thought")
    }

    /// Nothing can be saved to a file that is gone, so it is not retried forever.
    func testASaveOfAFileThatWasRemovedIsNotRetried() throws {
        let document = open()
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: store.activeURL, includingPropertiesForKeys: nil
        ).first)
        try FileManager.default.removeItem(at: file)

        document.setBody("typed after the file went")
        XCTAssertTrue(document.flush())

        XCTAssertNil(store.loadNote(id: document.id), "a save resurrected a deleted note")
        XCTAssertEqual(store.loadTrashed().first?.content, "typed after the file went", "the typing was kept nowhere")
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    // MARK: - Closing

    /// Archiving moves the file; it does not write one. Anything typed since
    /// the last pause has to land first or it is archived missing.
    /// (Regress scenario: archive flush.)
    func testArchivingKeepsTextTypedRightBeforeIt() throws {
        let document = open(content: "first draft")
        document.setBody("first draft plus a late thought")

        guard case let .closed(archivedNote) = document.close(.archive) else { return XCTFail("refused") }

        XCTAssertEqual(archivedNote?.content, "first draft plus a late thought")
        XCTAssertEqual(try archived(document).content, "first draft plus a late thought")
        XCTAssertNil(store.loadNote(id: document.id), "the note is still active")
    }

    func testAnEmptyNoteIsDiscardedNotArchivedWhenItIsClosed() throws {
        let document = open()
        document.setBody("something")
        document.setBody("  \n")
        document.setTitle("")

        guard case let .closed(archivedNote) = document.close(.archive) else { return XCTFail("refused") }

        XCTAssertNil(archivedNote)
        XCTAssertNil(store.loadNote(id: document.id))
        XCTAssertTrue(store.loadArchived().isEmpty)
    }

    func testDiscardingRemovesTheFileWithoutArchivingIt() throws {
        let document = open(title: "", content: "")

        guard case .closed = document.close(.discard) else { return XCTFail("refused") }

        XCTAssertNil(store.loadNote(id: document.id))
        XCTAssertTrue(store.loadArchived().isEmpty)
    }

    func testAnUntouchedEmptyNoteIsAnAbandonedCaptureUntilItIsEdited() throws {
        let document = open(title: "", content: "")
        XCTAssertTrue(document.isAbandonedCapture)

        document.adjust { $0.positionX = 5 }
        XCTAssertTrue(document.isAbandonedCapture, "moving a note counted as typing into it")

        document.setBody("x")
        document.setBody("")
        XCTAssertFalse(document.isAbandonedCapture, "a note that was typed into is never swept up")
    }

    func testAnEditToColourLabelsOrFloatLevelCountsAsTouchingTheNote() throws {
        let changes: [(inout Note) -> Void] = [{ $0.color = .blue }, { $0.labels = ["a"] }, { $0.floatLevel = .desktop }]
        for change in changes {
            let document = open(title: "", content: "")
            document.edit(change)
            XCTAssertFalse(document.isAbandonedCapture)
        }
    }

    /// The reconcile that found the file gone closes the window; an armed save
    /// must not write the file back as the window goes.
    func testAClosedDocumentNeverWritesAgain() throws {
        let document = open()
        document.setBody("typed just before the other Mac archived it")
        store.discardActive(document.buffer)

        _ = document.close(.externalDeletion)
        document.setBody("and a stray edit")
        scheduler.advance(by: 10)
        document.flush()

        XCTAssertNil(store.loadNote(id: document.id), "the note was resurrected")
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    // MARK: - Edits arriving from outside

    /// The window now follows the file unless the person is in the way.
    /// (Regress scenario: 6cbd1f0 applied an outside change over unsaved typing
    /// whenever the caret was out of the note.)
    func testAnOutsideWriteReachesAnIdleDocumentThroughTheWarmCache() throws {
        let document = open(content: "original")
        _ = store.loadActive()

        try writeOutside(document, body: "rewritten in Obsidian")
        document.storeDidChange()

        XCTAssertEqual(document.buffer.content, "rewritten in Obsidian")
        XCTAssertNil(document.pendingExternal)
    }

    /// Clicking the note's own title bar mid-sentence takes the caret out of the
    /// text, so "the caret is elsewhere" must not be taken to mean "nothing to
    /// lose". (Regress scenario: 6cbd1f0.)
    func testAnOutsideChangeDoesNotDiscardUnsavedTypingEvenWithTheCaretElsewhere() throws {
        let document = open(content: "original")
        document.isEditing = { false }
        _ = store.loadActive()
        document.setBody("original plus unsaved work")

        try writeOutside(document, body: "original\nfrom Obsidian")
        document.storeDidChange()

        XCTAssertEqual(document.buffer.content, "original plus unsaved work",
                       "unsaved typing was overwritten by the version on disk")
        XCTAssertNotNil(document.pendingExternal)
        XCTAssertTrue(document.flush())
        let content = try onDisk(document).content
        XCTAssertTrue(content.contains("unsaved work") && content.contains("from Obsidian"), content)
    }

    func testAnOutsideEditIsHeldBackUnderACaretEvenWhenNothingIsUnsaved() throws {
        let document = open(content: "original")
        var editing = true
        document.isEditing = { editing }
        var applied: [NoteDocument.Applied] = []
        document.didApplyExternal = { applied.append($0) }
        _ = store.loadActive()

        try writeOutside(document, body: "original\nfrom Obsidian")
        document.storeDidChange()

        XCTAssertEqual(document.buffer.content, "original", "text changed under the caret")
        XCTAssertNotNil(document.pendingExternal)
        XCTAssertTrue(applied.isEmpty)

        editing = false
        document.blur()

        XCTAssertEqual(document.buffer.content, "original\nfrom Obsidian")
        XCTAssertNil(document.pendingExternal)
        XCTAssertEqual(applied.count, 1)
    }

    func testAnAppliedOutsideEditReportsWhichPartsChanged() throws {
        let document = open(title: "Old", content: "body")
        var applied: [NoteDocument.Applied] = []
        document.didApplyExternal = { applied.append($0) }
        _ = store.loadActive()

        try writeOutside(document, title: "New", body: "body")
        document.storeDidChange()
        try writeOutside(document, title: "New", body: "body\nmore")
        document.storeDidChange()

        XCTAssertEqual(applied.map(\.title), [true, false])
        XCTAssertEqual(applied.map(\.content), [false, true])
        XCTAssertEqual(applied.map(\.labels), [false, false])
    }

    /// (Regress scenario: 0.4, the save overwrote a deferred outside edit.)
    func testAnOutsideWriteDefersToUnsavedTypingAndBothSidesSurvive() throws {
        let document = open(content: "original")
        _ = store.loadActive()
        document.setBody("original plus mine")

        try writeOutside(document, body: "original\nfrom Obsidian")
        document.storeDidChange()

        XCTAssertEqual(document.buffer.content, "original plus mine", "typing was overwritten")
        XCTAssertNotNil(document.pendingExternal)
        document.flush()
        let content = try onDisk(document).content
        XCTAssertTrue(content.contains("original plus mine"), content)
        XCTAssertTrue(content.contains("from Obsidian"), content)
    }

    /// The debounce firing is a save path too, with nobody to hand it the edit.
    /// (Regress scenario: 0.4.)
    func testADeferredExternalEditSurvivesTheNextDebouncedSave() throws {
        let document = open()
        document.setBody("typed on this Mac")
        try outsideEdit(document, body: "written in Obsidian")
        XCTAssertNotNil(document.pendingExternal)

        scheduler.advance(by: 1)

        let content = try onDisk(document).content
        XCTAssertTrue(content.contains("typed on this Mac"), "lost the local text: \(content)")
        XCTAssertTrue(content.contains("written in Obsidian"), "lost the external text: \(content)")
        XCTAssertNil(document.pendingExternal)
    }

    /// Archiving is a save path too, so it owes the same guarantee.
    /// (Regress scenario: R3, close did not merge the deferred edit.)
    func testArchivingDoesNotDropADeferredExternalEdit() throws {
        let document = open()
        document.setBody("mine")
        try outsideEdit(document, body: "theirs")

        _ = document.close(.archive)

        let content = try archived(document).content
        XCTAssertTrue(content.contains("mine"), "lost the local text: \(content)")
        XCTAssertTrue(content.contains("theirs"), "lost the external text: \(content)")
    }

    func testLosingFocusMergesAHeldBackEditAndSavesIt() throws {
        let document = open()
        document.setBody("mine")
        try outsideEdit(document, body: "theirs")

        document.blur()

        let content = try onDisk(document).content
        XCTAssertTrue(content.contains("mine") && content.contains("theirs"), content)
        XCTAssertNil(document.pendingExternal)
    }

    func testLosingFocusWithNothingHeldBackWritesNothing() throws {
        let document = open(content: "quiet")
        let before = try onDisk(document).updatedAt
        clock.advance(by: 60)

        document.blur()

        XCTAssertEqual(try onDisk(document).updatedAt, before)
    }

    /// The title is typed in its own field. A title-only difference used to fall
    /// through to "take theirs" and wipe a rename the person was still typing.
    func testATitleBeingTypedWinsOverAnOutsideTitle() throws {
        let document = open(title: "Plan", content: "one")
        document.isEditingTitle = { true }
        document.setTitle("Plan for the wee")
        try outsideEdit(document, title: "Renamed elsewhere", body: "one\ntwo")

        document.flush()

        let saved = try onDisk(document)
        XCTAssertEqual(saved.title, "Plan for the wee")
        XCTAssertTrue(saved.content.contains("two"), "the outside body was dropped: \(saved.content)")
    }

    func testATitleOnlyOutsideEditDoesNotOverwriteATitleBeingTyped() throws {
        let document = open(title: "Plan", content: "one")
        document.isEditingTitle = { true }
        document.setTitle("Plan for the wee")
        try outsideEdit(document, title: "Renamed elsewhere", body: "one")

        document.flush()

        XCTAssertEqual(try onDisk(document).title, "Plan for the wee")
    }

    /// The inverse: an idle title field has nothing to protect, so the title
    /// changed elsewhere is the one that lands.
    func testAnOutsideTitleLandsWhenNoTitleIsBeingTyped() throws {
        let document = open(title: "Plan", content: "one")
        document.isEditingTitle = { false }
        document.setBody("one")
        try outsideEdit(document, title: "Renamed elsewhere", body: "one")

        document.flush()

        XCTAssertEqual(try onDisk(document).title, "Renamed elsewhere")
    }

    // MARK: - Closing a blank note

    /// A blank note is deleted when it is closed, so text that arrived from
    /// outside and was held back must be taken in first, not deleted with it.
    func testAnEmptyNoteWithAHeldBackOutsideEditIsNotDiscarded() throws {
        let document = open(content: "text")
        _ = store.loadActive()
        document.setBody("")
        try writeOutside(document, body: "written in Obsidian")
        document.storeDidChange()
        XCTAssertNotNil(document.pendingExternal)

        guard case let .closed(archivedNote) = document.close(.archive) else { return XCTFail("refused") }

        XCTAssertEqual(archivedNote?.content, "written in Obsidian")
        XCTAssertEqual(try archived(document).content, "written in Obsidian")
    }

    /// The watcher reports an outside write only after a delay, and the window
    /// judges "empty" from what it shows. (Model finding F3.)
    func testAnEmptyNoteWithTextOnDiskIsNotDiscarded() throws {
        let document = open(title: "", content: "")
        try writeOutsideWithoutTellingTheDocument(document, title: "", body: "typed in Obsidian a moment ago")

        guard case let .closed(archivedNote) = document.close(.archive) else { return XCTFail("refused") }

        XCTAssertEqual(archivedNote?.content, "typed in Obsidian a moment ago")
        XCTAssertEqual(try archived(document).content, "typed in Obsidian a moment ago")
    }

    func testAnAbandonedCaptureThatTextArrivedInIsKeptAndShown() throws {
        let document = open(title: "", content: "")
        var applied: [NoteDocument.Applied] = []
        document.didApplyExternal = { applied.append($0) }
        try writeOutsideWithoutTellingTheDocument(document, title: "", body: "synced in from the other Mac")

        guard case .refused = document.close(.discard) else { return XCTFail("discarded a note holding text") }

        XCTAssertEqual(try onDisk(document).content, "synced in from the other Mac")
        XCTAssertEqual(document.buffer.content, "synced in from the other Mac")
        XCTAssertEqual(applied.count, 1)
    }

    /// The outside version is older than the clock, as an Obsidian edit is: its
    /// frontmatter `updated` is not touched. A merge would let the blank local
    /// note win and append the outside text under a "Conflicted copy" divider.
    func testAnEmptyNoteWithOlderTextOnDiskIsKeptWithItsTextAndTitle() throws {
        let document = open(title: "", content: "")
        try writeOutsideWithoutTellingTheDocument(
            document, title: "Renamed in Obsidian", body: "typed in Obsidian", updated: "2000-01-01T00:00:00Z"
        )

        guard case let .closed(archivedNote) = document.close(.archive) else { return XCTFail("refused") }

        XCTAssertEqual(archivedNote?.content, "typed in Obsidian")
        XCTAssertEqual(archivedNote?.title, "Renamed in Obsidian")
        XCTAssertEqual(try archived(document).content, "typed in Obsidian")
        XCTAssertEqual(try archived(document).title, "Renamed in Obsidian")
    }

    func testAnEmptyNoteWithAnOlderHeldBackEditKeepsItsTextAndTitle() throws {
        let document = open(title: "", content: "text")
        _ = store.loadActive()
        document.setBody("")
        try writeOutside(document, title: "Renamed in Obsidian", body: "written in Obsidian", updated: "2000-01-01T00:00:00Z")
        document.storeDidChange()
        XCTAssertNotNil(document.pendingExternal)

        guard case let .closed(archivedNote) = document.close(.archive) else { return XCTFail("refused") }

        XCTAssertEqual(archivedNote?.content, "written in Obsidian")
        XCTAssertEqual(archivedNote?.title, "Renamed in Obsidian")
    }

    func testLosingFocusOnABlankNoteTakesAnOlderOutsideEditAsItIs() throws {
        let document = open(title: "", content: "")
        document.isEditing = { true }
        _ = store.loadActive()
        try writeOutside(document, title: "", body: "written in Obsidian", updated: "2000-01-01T00:00:00Z")
        document.storeDidChange()
        XCTAssertNotNil(document.pendingExternal)

        document.blur()

        XCTAssertEqual(try onDisk(document).content, "written in Obsidian")
    }

    /// Obsidian does not touch `updated`, so the outside note is usually older
    /// than the local buffer; the merge must keep both sides all the same.
    func testAnOutsideWriteOlderThanTheClockStillMergesBothSides() throws {
        let document = open(content: "original")
        _ = store.loadActive()
        document.setBody("original plus mine")

        try writeOutside(document, body: "original\nfrom Obsidian", updated: "2000-01-01T00:00:00Z")
        document.storeDidChange()
        document.flush()

        let content = try onDisk(document).content
        XCTAssertTrue(content.contains("original plus mine"), content)
        XCTAssertTrue(content.contains("from Obsidian"), content)
    }

    func testABlankClosedDocumentsBlurWritesNothing() throws {
        let document = open(content: "text")
        document.setBody("mine")
        var external = try onDisk(document)
        external.content = "theirs"
        external.updatedAt = clock.now().addingTimeInterval(-1)
        document.externalChange(external)
        store.discardActive(document.buffer)
        _ = document.close(.externalDeletion)

        document.blur()

        XCTAssertNil(store.loadNote(id: document.id), "a closed document's blur wrote the note back")
    }

    // MARK: - The file watcher's echo of our own writes

    /// The critical one. Our own writes come back through the file watcher, and
    /// mid-typing that echo carries the previous text. Treating it as someone
    /// else's edit merged the note with a stale copy of itself, so one backspace
    /// produced a "Conflicted copy" of the user's own words.
    /// (Regress scenario: R1, own echo merged as an outside edit.)
    func testTheOwnSaveEchoDoesNotDuplicateTheNote() throws {
        let document = open()
        document.setBody("hello world")
        document.flush()

        document.setBody("hello wrld")
        document.storeDidChange()
        document.flush()

        let content = try onDisk(document).content
        XCTAssertEqual(content, "hello wrld")
        XCTAssertFalse(content.contains("Conflicted copy"), "merged the note with its own echo: \(content)")
    }

    /// A note created with text (clipboard, Service, URL) is saved before its
    /// window exists, and the watcher reports that write a moment later.
    func testACreationEchoOfACapturedNoteIsNotMergedAsAConflict() throws {
        let document = open(content: "captured text")
        document.setBody("captured txt")

        document.storeDidChange()
        document.flush()

        let content = try onDisk(document).content
        XCTAssertEqual(content, "captured txt")
        XCTAssertFalse(content.contains("Conflicted copy"), "got \(content)")
    }

    func testAStoreChangeWithNothingNewLeavesTheNoteAlone() throws {
        let document = open()
        document.setBody("steady")
        document.flush()

        document.storeDidChange()

        XCTAssertNil(document.pendingExternal)
        XCTAssertEqual(document.buffer.content, "steady")
    }

    /// After adopting one outside edit the document must still follow the next
    /// one. It used to keep its record of the last save from before the first
    /// edit, so it believed it held unsaved work and held every later edit back.
    /// (Regress scenario: F2.)
    func testTwoVaultEditsInARowBothReachAnIdleDocument() throws {
        let document = open(content: "start")
        document.setBody("start\ntyped here")
        document.flush()

        var first = try onDisk(document)
        first.content = "start\ntyped here\nfrom Obsidian"
        store.save(first)
        document.storeDidChange()
        XCTAssertEqual(document.buffer.content, "start\ntyped here\nfrom Obsidian")

        var second = try onDisk(document)
        second.content = "start\ntyped here\nfrom Obsidian\nand again"
        store.save(second)
        document.storeDidChange()

        XCTAssertEqual(document.buffer.content, "start\ntyped here\nfrom Obsidian\nand again",
                       "the second outside edit was held back")
        XCTAssertNil(document.pendingExternal)
        XCTAssertFalse(document.hasUnsavedEdits)
    }

    /// Obsidian writing back an older copy while the person is mid-edit adds
    /// nothing, so it must not come back as a "Conflicted copy" block.
    func testADeferredOlderCopyIsDroppedWithoutAConflictBlock() throws {
        let document = open(content: "a\nb")
        document.setBody("a\nX\nb")
        var older = try onDisk(document)
        older.content = "a\nb"
        older.updatedAt = clock.now().addingTimeInterval(-1)
        document.externalChange(older)

        document.flush()

        XCTAssertEqual(try onDisk(document).content, "a\nX\nb")
    }

    /// What a vault user does: edit in Obsidian, come back, edit here.
    func testANoteEditedInBothPlacesKeepsBothEditsAsOneFile() throws {
        let document = open(content: "shopping")
        document.setBody("shopping\n- milk")
        document.flush()

        var fromObsidian = try onDisk(document)
        fromObsidian.content = "shopping\n- milk\n- bread"
        store.save(fromObsidian)
        document.storeDidChange()

        XCTAssertEqual(document.buffer.content, "shopping\n- milk\n- bread")
        XCTAssertEqual(store.loadActive().filter { $0.id == document.id }.count, 1, "the note was duplicated")
    }

    // MARK: - Never overwriting a file that was not read

    /// What is on disk, read from the file and not from the store's cache.
    private func fileNote(_ document: NoteDocument) throws -> Note {
        try XCTUnwrap(store.snapshot(id: document.id)?.note, "note has no file")
    }

    /// A repository that passes everything to the store and remembers each save's result.
    private final class RecordingRepository: NoteRepository {
        let store: NoteStore
        private(set) var results: [SaveResult] = []

        init(store: NoteStore) { self.store = store }

        var conflicts: Int {
            results.filter { if case .conflict = $0 { return true } else { return false } }.count
        }

        func save(_ note: Note, expecting fingerprint: Fingerprint?) -> SaveResult {
            let result = store.save(note, expecting: fingerprint)
            results.append(result)
            return result
        }
        func loadNote(id: UUID, archived: Bool) -> Note? { store.loadNote(id: id, archived: archived) }
        func snapshot(id: UUID, archived: Bool) -> NoteSnapshot? { store.snapshot(id: id, archived: archived) }
        func archive(_ note: Note) { store.archive(note) }
        func discardActive(_ note: Note) { store.discardActive(note) }
    }

    /// A file that always changes between the check and the save.
    private final class AlwaysConflictingRepository: NoteRepository {
        private(set) var saves = 0

        func save(_ note: Note, expecting fingerprint: Fingerprint?) -> SaveResult {
            saves += 1
            var other = note
            other.content = "outside version \(saves)"
            other.updatedAt = Date(timeIntervalSince1970: 1_900_000_000)
            return .conflict(onDisk: other, fingerprint: Fingerprint(of: Data("\(saves)".utf8)))
        }
        func loadNote(id: UUID, archived: Bool) -> Note? { nil }
        func snapshot(id: UUID, archived: Bool) -> NoteSnapshot? { nil }
        func archive(_ note: Note) {}
        func discardActive(_ note: Note) {}
    }

    /// An outside write lands between the last keystroke and the debounce, before
    /// the watcher has reported it. The save used to overwrite it, and the
    /// watcher's echo then matched what the window had written and was ignored.
    /// (Model finding F4.)
    func testASaveDoesNotOverwriteAVaultEditTheWatcherHasNotReported() throws {
        let document = open(content: "buy milk")
        document.setBody("buy milk\nand eggs")
        try writeOutsideWithoutTellingTheDocument(document, body: "buy milk\ncall Sam")

        scheduler.advance(by: 1)

        let saved = try fileNote(document).content
        XCTAssertTrue(saved.contains("and eggs"), saved)
        XCTAssertTrue(saved.contains("call Sam"), saved)
        XCTAssertFalse(document.hasUnsavedEdits)
        XCTAssertEqual(document.buffer.content, saved)
    }

    /// When the outside text already holds everything typed, it is taken as it is.
    func testAnUnreportedOutsideSupersetIsTakenWithoutADivider() throws {
        let document = open(content: "buy milk")
        document.setBody("buy milk\nand eggs")
        try writeOutsideWithoutTellingTheDocument(document, body: "buy milk\nand eggs\nand bread")

        scheduler.advance(by: 1)

        XCTAssertEqual(try fileNote(document).content, "buy milk\nand eggs\nand bread")
        XCTAssertEqual(document.buffer.content, "buy milk\nand eggs\nand bread")
    }

    func testClosingDoesNotOverwriteAnUnreportedOutsideEdit() throws {
        let document = open(content: "buy milk")
        document.setBody("buy milk\nand eggs")
        try writeOutsideWithoutTellingTheDocument(document, body: "buy milk\ncall Sam")

        guard case .closed = document.close(.archive) else { return XCTFail("did not close") }

        let kept = try archived(document).content
        XCTAssertTrue(kept.contains("and eggs") && kept.contains("call Sam"), kept)
    }

    func testFlushingDoesNotOverwriteAnUnreportedOutsideEdit() throws {
        let document = open(content: "buy milk")
        document.setBody("buy milk\nand eggs")
        try writeOutsideWithoutTellingTheDocument(document, body: "buy milk\ncall Sam")

        XCTAssertTrue(document.flush())

        let saved = try fileNote(document).content
        XCTAssertTrue(saved.contains("and eggs") && saved.contains("call Sam"), saved)
    }

    /// A blank buffer holds nothing to protect, so the outside text is taken
    /// whole, not appended under a divider.
    func testASaveFromABlankBufferTakesAnUnreportedOutsideEditAsItIs() throws {
        let document = open(content: "")
        document.adjust { $0.color = .blue }
        try writeOutsideWithoutTellingTheDocument(document, body: "typed in Obsidian")

        scheduler.advance(by: 1)

        XCTAssertEqual(try fileNote(document).content, "typed in Obsidian")
    }

    func testOurOwnWritesEchoNeverMakesASaveConflict() throws {
        let repository = RecordingRepository(store: store)
        let note = makeNote(content: "start")
        store.save(note)
        let document = NoteDocument(note: note, repository: repository, scheduler: scheduler, clock: clock)

        for text in ["start one", "start one two", "start one two three"] {
            document.setBody(text)
            scheduler.advance(by: 1)
            // What the watcher does after every write of ours.
            store.handleFileSystemEvent()
            document.storeDidChange()
        }

        XCTAssertEqual(repository.results.count, 3)
        XCTAssertEqual(repository.conflicts, 0, "an echo of our own write was met as a conflict")
        XCTAssertEqual(try fileNote(document).content, "start one two three")
    }

    func testAnAdoptedOutsideEditLeavesTheNextSaveWithoutAConflict() throws {
        let repository = RecordingRepository(store: store)
        let note = makeNote(content: "start")
        store.save(note)
        let document = NoteDocument(note: note, repository: repository, scheduler: scheduler, clock: clock)

        try writeOutside(document, body: "start\nfrom Obsidian")
        document.storeDidChange()
        XCTAssertEqual(document.buffer.content, "start\nfrom Obsidian")
        XCTAssertEqual(document.persistedFingerprint, store.snapshot(id: document.id)?.fingerprint)

        document.setBody("start\nfrom Obsidian\nand here")
        scheduler.advance(by: 1)

        XCTAssertEqual(repository.conflicts, 0)
        XCTAssertEqual(try fileNote(document).content, "start\nfrom Obsidian\nand here")
    }

    func testAnOutsideEditAdoptedThroughTheCacheStillGetsAFreshFingerprint() throws {
        let note = makeNote(content: "start")
        store.save(note)
        let document = NoteDocument(note: note, repository: store, scheduler: scheduler, clock: clock)

        try writeOutside(document, body: "start\nfrom Obsidian")
        document.externalChange(try fileNote(document))

        XCTAssertEqual(document.persistedFingerprint, store.snapshot(id: document.id)?.fingerprint)
    }

    /// An outside edit the document was only told about as an older version:
    /// the file has moved on again, so the stale fingerprint stays and the save
    /// merges with what is there now.
    func testAnOutsideEditThatChangedAgainBeforeItWasReadKeepsTheSaveSafe() throws {
        let document = open(content: "start")
        try writeOutsideWithoutTellingTheDocument(document, body: "start\nfirst outside edit")
        var older = try fileNote(document)
        older.content = "start\nfirst outside edit"
        try writeOutsideWithoutTellingTheDocument(document, body: "start\nfirst outside edit\nsecond outside edit")

        document.externalChange(older)
        document.setBody("start\nfirst outside edit\nmine")
        scheduler.advance(by: 1)

        let saved = try fileNote(document).content
        XCTAssertTrue(saved.contains("second outside edit") && saved.contains("mine"), saved)
    }

    func testTypingReadsNoFilesAndASaveReadsTheFileOnce() throws {
        let document = open(content: "start")
        let reads = store.readCount

        for text in ["s", "st", "sta", "star", "start!"] { document.setBody(text) }
        XCTAssertEqual(store.readCount, reads, "typing read a file")

        scheduler.advance(by: 1)
        XCTAssertEqual(store.readCount, reads + 1, "a save must read the file exactly once")
    }

    func testASaveThatKeepsMeetingAChangedFileGivesUpAndRetriesLater() {
        let repository = AlwaysConflictingRepository()
        let document = NoteDocument(
            note: makeNote(content: "start"), repository: repository, scheduler: scheduler, clock: clock
        )

        document.setBody("start\ntyped")
        scheduler.advance(by: NoteDocument.debounce + 0.01)

        XCTAssertEqual(repository.saves, NoteDocument.maxSaveAttempts)
        XCTAssertTrue(document.hasUnsavedEdits, "text that reached no file counts as saved")
        XCTAssertTrue(document.buffer.content.contains("typed"), document.buffer.content)
        XCTAssertEqual(scheduler.pendingCount, 1, "no retry is armed")

        scheduler.advance(by: NoteDocument.retryDelay + 0.01)
        XCTAssertEqual(repository.saves, 2 * NoteDocument.maxSaveAttempts)
    }

    func testANewNoteStartsWithNoFingerprintAndCreatesItsFile() throws {
        let note = makeNote(content: "")
        let repository = RecordingRepository(store: store)
        let document = NoteDocument(note: note, repository: repository, scheduler: scheduler, clock: clock)
        XCTAssertNil(document.persistedFingerprint)

        document.setBody("first words")
        scheduler.advance(by: 1)

        XCTAssertEqual(repository.conflicts, 0)
        XCTAssertNotNil(document.persistedFingerprint)
        XCTAssertEqual(try fileNote(document).content, "first words")
    }

    func testANewNoteMeetsAFileThatAppearedFirstAsAConflictAndKeepsBothTexts() throws {
        let note = makeNote(content: "")
        let document = NoteDocument(note: note, repository: store, scheduler: scheduler, clock: clock)
        var elsewhere = note
        elsewhere.content = "created on the other Mac"
        elsewhere.updatedAt = Date(timeIntervalSince1970: 1_900_000_000)
        store.save(elsewhere)

        document.setBody("created here")
        scheduler.advance(by: 1)

        let saved = try fileNote(document).content
        XCTAssertTrue(saved.contains("created here") && saved.contains("created on the other Mac"), saved)
        XCTAssertEqual(store.loadActive().filter { $0.id == note.id }.count, 1)
    }

    /// The document was handed a note that differs from the file, as when the
    /// watcher has not yet reported a change: it must not claim to have seen the file.
    func testADocumentOverANoteThatDiffersFromItsFileHoldsNoFingerprint() throws {
        let note = makeNote(content: "as last read")
        store.save(note)
        var changed = note
        changed.content = "changed since"
        store.save(changed)

        let document = NoteDocument(note: note, repository: store, scheduler: scheduler, clock: clock)

        XCTAssertNil(document.persistedFingerprint)
        document.setBody("as last read\nplus typing")
        scheduler.advance(by: 1)
        let saved = try fileNote(document).content
        XCTAssertTrue(saved.contains("changed since") && saved.contains("plus typing"), saved)
    }

    // MARK: - Rewrites that keep the text, and merging against the base

    private func count(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private let divider = "Conflicted copy"

    /// The other Mac moved or recoloured the note: the file changed, the text did not.
    func testAFrontmatterOnlyOutsideWriteThenAnEditAddsNoDivider() throws {
        let document = open(content: "milk\neggs")
        try outsideEdit(document, body: "milk\neggs", updated: "2031-01-01T00:00:00Z")

        document.setBody("milk\nbread")
        scheduler.advance(by: 1)

        XCTAssertEqual(try fileNote(document).content, "milk\nbread")
        XCTAssertEqual(document.persistedFingerprint, store.snapshot(id: document.id)?.fingerprint)
    }

    /// The same, before the watcher reports it: the save meets it as a conflict.
    func testAnUnreportedFrontmatterOnlyOutsideWriteThenAnEditAddsNoDivider() throws {
        let document = open(content: "milk\neggs")
        try writeOutsideWithoutTellingTheDocument(document, body: "milk\neggs", updated: "2031-01-01T00:00:00Z")

        document.setBody("milk\nbread")
        scheduler.advance(by: 1)

        XCTAssertEqual(try fileNote(document).content, "milk\nbread")
        XCTAssertEqual(document.buffer.content, "milk\nbread")
    }

    func testARenameTypedRightAfterAFrontmatterOnlyOutsideWriteSurvives() throws {
        let document = open(title: "Plan", content: "one")
        document.isEditingTitle = { false }
        try outsideEdit(document, title: "Plan", body: "one", updated: "2031-01-01T00:00:00Z")

        document.setTitle("Renamed")
        scheduler.advance(by: 1)

        XCTAssertEqual(try fileNote(document).title, "Renamed")
    }

    /// Obsidian rewrites properties inside the debounce, after the title was
    /// typed and Return was pressed: the old title in the file is not an edit.
    func testARenameSurvivesAnUnreportedPropertyWriteInsideTheDebounce() throws {
        let document = open(title: "Plan", content: "one")
        document.isEditingTitle = { false }
        document.setTitle("Renamed")
        try writeOutsideWithoutTellingTheDocument(document, title: "Plan", body: "one", updated: "2031-01-01T00:00:00Z")

        scheduler.advance(by: 1)

        XCTAssertEqual(try fileNote(document).title, "Renamed")
        XCTAssertEqual(document.buffer.title, "Renamed")
    }

    func testAPropertiesOnlyOutsideWriteNeverRevertsTypingOrTheTitle() throws {
        let document = open(title: "Plan", content: "one")
        document.isEditingTitle = { false }
        document.setTitle("Renamed")
        document.setBody("one\nand two")
        try outsideEdit(document, title: "Plan", body: "one", updated: "2031-01-01T00:00:00Z")

        document.flush()

        let saved = try fileNote(document)
        XCTAssertEqual(saved.title, "Renamed")
        XCTAssertEqual(saved.content, "one\nand two")
    }

    /// An untouched buffer has nothing to protect: the outside body is the note.
    func testAnOutsideBodyEditLandsInABufferThatOnlyChangedItsColour() throws {
        let document = open(content: "one")
        document.edit { $0.color = .blue }
        try outsideEdit(document, body: "one\ntwo is not a superset-only edit")

        scheduler.advance(by: 1)

        XCTAssertEqual(try fileNote(document).content, "one\ntwo is not a superset-only edit")
    }

    /// Base `a`: Obsidian appends `b` while the person types `c`, then appends `d`
    /// before the debounce. Only the newest file is merged, and the person's
    /// appended line goes after the outside lines, each once.
    func testAHeldBackEditThatChangedAgainIsMergedOnceNotTwice() throws {
        let document = open(content: "a")
        document.setBody("a\nc")
        try outsideEdit(document, body: "a\nb")
        XCTAssertNotNil(document.pendingExternal)
        try writeOutsideWithoutTellingTheDocument(document, body: "a\nb\nd")

        scheduler.advance(by: 1)

        let saved = try fileNote(document).content
        XCTAssertEqual(saved.components(separatedBy: "\n").filter { $0 == "b" }.count, 1, saved)
        XCTAssertEqual(saved.components(separatedBy: "\n").filter { $0 == "a" }.count, 1, saved)
        XCTAssertTrue(saved.contains("c") && saved.contains("d"), saved)
    }

    // MARK: - Conflict versions and unsaved text

    private func conflictVersionFile(
        of note: Note, content: String, updated: String = "1970-01-01T00:00:01Z"
    ) throws -> URL {
        let url = root.appendingPathComponent("version-\(UUID().uuidString).md")
        try "---\nid: \(note.id.uuidString)\nupdated: \(updated)\n---\n\(content)\n"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The sweep runs while the window holds unsaved text. The text is written
    /// first, so the version is merged into a file that has it, and the window
    /// then takes the merged file as it is.
    func testAConflictVersionIsMergedAfterTheWindowsUnsavedTextIsWritten() throws {
        let note = makeNote(content: "a\nx")
        store.save(note)
        let document = NoteDocument(note: note, repository: store, scheduler: scheduler, clock: clock)
        document.setBody("a\nx\nmine")
        let version = try conflictVersionFile(of: note, content: "a\ny")
        store.conflictVersionsProvider = { _ in [.init(url: version, markResolved: {})] }
        store.otherVersionsRemover = { _ in }
        store.beforeResolvingConflicts = { id in id == document.id ? document.flush() : true }

        XCTAssertEqual(store.resolveConflicts(), 1)
        document.storeDidChange()

        let saved = try fileNote(document).content
        XCTAssertEqual(count(of: divider, in: saved), 1, saved)
        XCTAssertEqual(count(of: "mine", in: saved), 1, saved)
        XCTAssertEqual(saved.components(separatedBy: "\n").filter { $0 == "x" }.count, 1, saved)
        XCTAssertEqual(document.buffer.content, saved)
        XCTAssertFalse(document.hasUnsavedEdits)
    }

    func testAConflictVersionIsLeftForLaterWhenTheWindowCannotWriteItsText() throws {
        let note = makeNote(content: "a")
        store.save(note)
        let version = try conflictVersionFile(of: note, content: "other")
        var resolved = 0
        store.conflictVersionsProvider = { _ in [.init(url: version, markResolved: { resolved += 1 })] }
        store.otherVersionsRemover = { _ in }
        store.beforeResolvingConflicts = { _ in false }

        XCTAssertEqual(store.resolveConflicts(), 0)
        XCTAssertEqual(resolved, 0)
        XCTAssertEqual(try XCTUnwrap(store.snapshot(id: note.id)).note.content, "a")
    }

    /// The system's save date for a version, not what its file says, orders the merge.
    func testAConflictVersionsSaveDateDecidesWhichTextLeads() throws {
        let note = makeNote(content: "current")
        store.save(note)
        let version = try conflictVersionFile(of: note, content: "newer elsewhere")
        store.conflictVersionsProvider = { _ in
            [.init(url: version, markResolved: {}, modificationDate: Date(timeIntervalSince1970: 4_000_000_000))]
        }
        store.otherVersionsRemover = { _ in }

        XCTAssertEqual(store.resolveConflicts(), 1)

        let saved = try XCTUnwrap(store.snapshot(id: note.id)).note.content
        XCTAssertTrue(saved.hasPrefix("newer elsewhere"), saved)
        XCTAssertTrue(saved.contains("current"), saved)
    }

    // MARK: - Each part is merged on its own

    /// The other Mac renamed the note and deleted a line while this Mac appended one.
    func testAnOutsideRenameAndDeletionSurviveWhileTheUserAppends() throws {
        let document = open(title: "Groceries", content: "milk\neggs")
        document.setBody("milk\neggs\nbread")
        try outsideEdit(document, title: "Shopping", body: "milk")

        document.flush()

        let saved = try fileNote(document)
        XCTAssertEqual(saved.title, "Shopping")
        XCTAssertEqual(saved.content, "milk\nbread")
        XCTAssertEqual(document.buffer.content, "milk\nbread")
    }

    /// Both renamed it, and only the outside changed the body, mid-line.
    func testBothRenamingAndOnlyTheOutsideChangingTheBodyAddsNoDivider() throws {
        let document = open(title: "Groceries", content: "milk\neggs")
        document.isEditingTitle = { false }
        document.setTitle("Mine")
        try outsideEdit(document, title: "Theirs", body: "milk\nbread")

        document.flush()

        let saved = try fileNote(document)
        XCTAssertEqual(saved.title, "Mine")
        XCTAssertFalse(saved.content.contains(divider), saved.content)
        XCTAssertTrue(saved.content.hasPrefix("milk\nbread"), saved.content)
        XCTAssertTrue(saved.content.contains("Also titled: Theirs"), saved.content)
    }

    /// Both bodies changed but read the same; the person renamed it and left the title field.
    func testARenameIsKeptWhenBothBodiesChangedToTheSameText() throws {
        let document = open(title: "Groceries", content: "milk")
        document.isEditingTitle = { false }
        document.setTitle("Mine")
        document.setBody("milk\nbread  ")
        try outsideEdit(document, title: "Groceries", body: "milk\nbread")

        document.flush()

        XCTAssertEqual(try fileNote(document).title, "Mine")
        XCTAssertFalse(try fileNote(document).content.contains(divider))
    }

    func testAnAppendToAnOutsideEditedBodyIsAddedOnceWhenTheOutsideAlreadyHasIt() throws {
        let document = open(content: "milk\neggs")
        document.setBody("milk\neggs\nbread")
        try outsideEdit(document, body: "milk\nbread")
        document.flush()
        try outsideEdit(document, body: "milk\nbread")

        document.flush()

        XCTAssertEqual(try fileNote(document).content, "milk\nbread")
    }

    func testAFileThatMatchesTheBufferBecomesTheBaseForLaterMerges() throws {
        let document = open(content: "a")
        document.setBody("a\nb")
        try outsideEdit(document, body: "a\nb")
        document.setBody("a\nb\nc")
        try outsideEdit(document, body: "a\nb\nd")

        document.flush()

        let saved = try fileNote(document).content
        XCTAssertTrue(saved.contains("c") && saved.contains("d"), saved)
        XCTAssertEqual(saved.components(separatedBy: "\n").filter { $0 == "b" }.count, 1, saved)
    }
}
