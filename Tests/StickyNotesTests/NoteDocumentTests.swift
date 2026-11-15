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
        store = NoteStore(rootURL: root, format: .markdown, clock: clock)
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
    private func writeOutside(_ document: NoteDocument, title: String = "Note", body: String) throws {
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: store.activeURL, includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "md" })
        try "---\nid: \(document.id.uuidString)\ntitle: \"\(title)\"\nupdated: 2030-01-01T00:00:00Z\n---\n\(body)"
            .write(to: file, atomically: true, encoding: .utf8)
        store.handleFileSystemEvent()
    }

    /// Makes every write into the notes folder fail, as a full disk or a
    /// revoked permission would; the folder is made writable again on teardown.
    private func failWrites() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.activeURL.path)
        addTeardownBlock { [store = store!] in
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.activeURL.path)
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
        var external = try onDisk(document)
        external.content = "written in Obsidian"
        external.updatedAt = clock.now().addingTimeInterval(-1)
        document.externalChange(external)
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
        var external = try onDisk(document)
        external.content = "theirs"
        external.updatedAt = clock.now().addingTimeInterval(-1)
        document.externalChange(external)

        _ = document.close(.archive)

        let content = try archived(document).content
        XCTAssertTrue(content.contains("mine"), "lost the local text: \(content)")
        XCTAssertTrue(content.contains("theirs"), "lost the external text: \(content)")
    }

    func testLosingFocusMergesAHeldBackEditAndSavesIt() throws {
        let document = open()
        document.setBody("mine")
        var external = try onDisk(document)
        external.content = "theirs"
        external.updatedAt = clock.now().addingTimeInterval(-1)
        document.externalChange(external)

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
        var external = try onDisk(document)
        external.title = "Renamed elsewhere"
        external.content = "one\ntwo"
        external.updatedAt = clock.now().addingTimeInterval(-1)
        document.externalChange(external)

        document.flush()

        let saved = try onDisk(document)
        XCTAssertEqual(saved.title, "Plan for the wee")
        XCTAssertTrue(saved.content.contains("two"), "the outside body was dropped: \(saved.content)")
    }

    func testATitleOnlyOutsideEditDoesNotOverwriteATitleBeingTyped() throws {
        let document = open(title: "Plan", content: "one")
        document.isEditingTitle = { true }
        document.setTitle("Plan for the wee")
        var external = try onDisk(document)
        external.title = "Renamed elsewhere"
        external.updatedAt = clock.now().addingTimeInterval(-1)
        document.externalChange(external)

        document.flush()

        XCTAssertEqual(try onDisk(document).title, "Plan for the wee")
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

    /// An outside write ends the lineage, so an older save of ours that iCloud
    /// kept as a conflict version is merged back rather than taken for text the
    /// user has since edited away.
    func testAnOutsideWriteEndsTheLineageSoAnOlderOwnVersionIsMerged() throws {
        let document = open(content: "teh cat\nsat down")
        document.setBody("the cat\nsat down")
        document.flush()
        let older = root.appendingPathComponent("older.md")
        try "---\nid: \(document.id.uuidString)\nupdated: 1970-01-01T00:00:01Z\n---\nteh cat\nsat down\n"
            .write(to: older, atomically: true, encoding: .utf8)
        store.conflictVersionsProvider = { _ in [.init(url: older, markResolved: {})] }
        store.otherVersionsRemover = { _ in }
        _ = store.loadActive()

        try writeOutside(document, body: "the cat\nsat down\nfrom Obsidian")

        let content = try onDisk(document).content
        XCTAssertTrue(content.contains("teh cat"), "the older version was dropped: \(content)")
        XCTAssertTrue(content.contains("from Obsidian"), content)
    }
}
