import AppKit
import XCTest
@testable import StickyNotesKit

/// End-to-end tests for a note window: real `NoteWindowController`, real
/// `NoteStore`, real files in a temp directory. Everything goes through the
/// same delegate callbacks AppKit invokes, so what's exercised is the actual
/// typing → debounce → disk path rather than a reimplementation of it.
///
/// This is the layer that had no coverage, and it is where the worst bugs
/// lived: text that never reached disk, and text that reached disk twice.
///
/// Not covered here, and worth knowing: anything that needs a key window or a
/// live field editor (the in-progress-title rule).
final class NoteWindowEndToEndTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteWindowE2E-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(rootURL: root, format: .markdown)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Harness

    /// A saved note and an open window showing it.
    private func openNote(title: String = "Note", content: String = "") throws -> NoteWindowController {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        note.title = title
        note.content = content
        store.save(note)
        return NoteWindowController(note: note, store: store, onClosed: { _ in })
    }

    /// Type into the body the way AppKit does: set the text, then fire the
    /// delegate callback that a real keystroke would.
    private func type(_ text: String, into controller: NoteWindowController) {
        controller.textView.string = text
        controller.textDidChange(
            Notification(name: NSText.didChangeNotification, object: controller.textView)
        )
    }

    private func onDisk(_ controller: NoteWindowController) throws -> Note {
        try XCTUnwrap(store.loadNote(id: controller.noteId), "note is not in the active folder")
    }

    /// Let the run loop turn for `seconds`. The save debounce is real wall
    /// time, so a test that wants to observe it has to actually wait.
    private func waitForRunLoop(_ seconds: TimeInterval) {
        let done = expectation(description: "run loop")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 5)
    }

    // MARK: - Reaching disk at all

    /// The debounced save is the normal path: type, stop, and it lands.
    func testTypingReachesDiskOnceTheDebounceFires() throws {
        let controller = try openNote()
        type("groceries", into: controller)

        XCTAssertEqual(try onDisk(controller).content, "", "saved before the debounce elapsed")
        waitForRunLoop(0.8)
        XCTAssertEqual(try onDisk(controller).content, "groceries")
    }

    /// Quitting is the path that used to lose text: the debounce is still
    /// pending, and nothing drained it.
    func testFlushingWritesTextTypedSinceTheLastPause() throws {
        let controller = try openNote()
        type("half a sentence", into: controller)

        controller.flushPendingSave()
        XCTAssertEqual(try onDisk(controller).content, "half a sentence")
    }

    /// A note nobody typed into must not be rewritten on quit — otherwise
    /// every open note gets a new modification date, and in a synced vault
    /// that means re-uploading all of them.
    func testFlushingANoteNobodyTouchedWritesNothing() throws {
        let controller = try openNote(content: "untouched")
        let before = try XCTUnwrap(store.loadNote(id: controller.noteId)).updatedAt

        controller.flushPendingSave()

        XCTAssertEqual(try onDisk(controller).updatedAt, before, "rewrote an untouched note")
    }

    /// The debounce fires once and is done; a later flush has nothing to do.
    func testASaveThatAlreadyFiredIsNotWrittenAgain() throws {
        let controller = try openNote()
        type("done typing", into: controller)
        waitForRunLoop(0.8)
        let after = try onDisk(controller).updatedAt

        controller.flushPendingSave()

        XCTAssertEqual(try onDisk(controller).updatedAt, after, "flush rewrote an already-saved note")
    }

    // MARK: - A write that does not land

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

    /// The window used to record the text as saved before writing it, so a
    /// failed write left it looking clean and nothing tried again.
    func testAFailedSaveKeepsTheNoteDirty() throws {
        let controller = try openNote(content: "on disk")
        type("on disk plus a new thought", into: controller)
        try failWrites()

        controller.flushPendingSave()
        XCTAssertEqual(try onDisk(controller).content, "on disk")

        try allowWrites()
        controller.flushPendingSave()
        XCTAssertEqual(try onDisk(controller).content, "on disk plus a new thought",
                       "the failed save was not retried: the window treated its text as saved")
    }

    /// Archiving moves a file, and closing drops the buffer: after a failed
    /// write either one loses the text.
    func testAFailedSaveDoesNotArchiveOrCloseTheNote() throws {
        var closed = false
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        note.content = "on disk"
        store.save(note)
        let controller = NoteWindowController(note: note, store: store, onClosed: { _ in closed = true })
        type("on disk plus a new thought", into: controller)
        try failWrites()

        controller.closeNote()

        XCTAssertFalse(closed, "the window closed with text that reached no file")
        XCTAssertTrue(store.loadArchived().isEmpty, "the note was archived without its text")
        XCTAssertEqual(controller.textView.string, "on disk plus a new thought")

        try allowWrites()
        controller.closeNote()

        XCTAssertTrue(closed)
        let archived = try XCTUnwrap(store.loadArchived().first)
        XCTAssertEqual(archived.content, "on disk plus a new thought")
    }

    // MARK: - Archiving

    /// Archiving moves the file; it doesn't write one. Anything typed since
    /// the last pause has to land first or it is archived missing.
    func testArchivingKeepsTextTypedRightBeforeIt() throws {
        let controller = try openNote(content: "first draft")
        type("first draft plus a late thought", into: controller)

        controller.closeNote()

        let archived = try XCTUnwrap(
            store.loadArchived().first(where: { $0.id == controller.noteId }),
            "note is not in the archive"
        )
        XCTAssertEqual(archived.content, "first draft plus a late thought")
    }

    // MARK: - Edits arriving from outside

    /// The critical one. Our own writes come back through the file watcher,
    /// and mid-typing that echo carries the *previous* text. Treating it as
    /// someone else's edit merged the note with a stale copy of itself, so a
    /// single backspace produced a "Conflicted copy" of the user's own words.
    func testTheAppsOwnSaveEchoDoesNotDuplicateTheNote() throws {
        let controller = try openNote()
        type("hello world", into: controller)
        controller.flushPendingSave()

        // Delete a character, so the live text no longer contains what is on
        // disk — the shape that made the bogus merge fire.
        type("hello wrld", into: controller)
        controller.handleStoreChange()
        controller.flushPendingSave()

        let content = try onDisk(controller).content
        XCTAssertEqual(content, "hello wrld")
        XCTAssertFalse(content.contains("Conflicted copy"),
                       "merged the note with its own echo: \(content)")
    }

    /// Found by writing these tests. A store change arriving while the caret
    /// is not in the text view used to be applied straight over the buffer,
    /// so clicking the note's own title bar mid-sentence — which drops first
    /// responder — and then any file event reverted what had been typed.
    func testAStoreChangeDoesNotDiscardUnsavedTyping() throws {
        let controller = try openNote(content: "original")
        type("original plus unsaved work", into: controller)

        // The file still holds the old text; something else touched the store.
        controller.handleStoreChange()

        XCTAssertEqual(controller.textView.string, "original plus unsaved work",
                       "unsaved typing was overwritten by the version on disk")
        controller.flushPendingSave()
        XCTAssertTrue(try onDisk(controller).content.contains("unsaved work"),
                      "unsaved typing never reached disk")
    }

    /// An unrelated store change while the text matches disk is simply
    /// nothing to do.
    func testAStoreChangeWithNothingNewLeavesTheNoteAlone() throws {
        let controller = try openNote()
        type("steady", into: controller)
        controller.flushPendingSave()

        controller.handleStoreChange()

        XCTAssertNil(controller.pendingExternalNote)
        XCTAssertEqual(controller.textView.string, "steady")
    }

    /// A real external edit deferred while the user types must survive the
    /// next save rather than be overwritten by it.
    func testADeferredExternalEditSurvivesTheNextSave() throws {
        let controller = try openNote()
        type("typed on this Mac", into: controller)

        var external = try onDisk(controller)
        external.content = "written in Obsidian"
        external.updatedAt = Date().addingTimeInterval(-1)
        controller.pendingExternalNote = external

        controller.flushPendingSave()

        let content = try onDisk(controller).content
        XCTAssertTrue(content.contains("typed on this Mac"), "lost the local text: \(content)")
        XCTAssertTrue(content.contains("written in Obsidian"), "lost the external text: \(content)")
    }

    /// Archiving is a save path too, so it owes the same guarantee.
    func testArchivingDoesNotDropADeferredExternalEdit() throws {
        let controller = try openNote()
        type("mine", into: controller)

        var external = try onDisk(controller)
        external.content = "theirs"
        external.updatedAt = Date().addingTimeInterval(-1)
        controller.pendingExternalNote = external

        controller.closeNote()

        let archived = try XCTUnwrap(
            store.loadArchived().first(where: { $0.id == controller.noteId })
        )
        XCTAssertTrue(archived.content.contains("mine"), "lost the local text: \(archived.content)")
        XCTAssertTrue(archived.content.contains("theirs"), "lost the external text: \(archived.content)")
    }

    /// After the window shows one outside edit it must still follow the next
    /// one. It used to keep its record of the last save from before the first
    /// edit, so it believed it held unsaved work and held every later edit back.
    func testTwoVaultEditsInARowBothReachAnIdleWindow() throws {
        let controller = try openNote(content: "start")
        type("start\ntyped here", into: controller)
        controller.flushPendingSave()

        var first = try onDisk(controller)
        first.content = "start\ntyped here\nfrom Obsidian"
        store.save(first)
        controller.handleStoreChange()
        XCTAssertEqual(controller.textView.string, "start\ntyped here\nfrom Obsidian")

        var second = try onDisk(controller)
        second.content = "start\ntyped here\nfrom Obsidian\nand again"
        store.save(second)
        controller.handleStoreChange()

        XCTAssertEqual(controller.textView.string, "start\ntyped here\nfrom Obsidian\nand again",
                       "the second outside edit was held back")
        XCTAssertNil(controller.pendingExternalNote)
    }

    /// Obsidian writing back an older copy while the person is mid-edit adds
    /// nothing, so it must not come back as a "Conflicted copy" block.
    func testADeferredOlderCopyIsDroppedWithoutAConflictBlock() throws {
        let controller = try openNote(content: "a\nb")
        type("a\nX\nb", into: controller)

        var older = try onDisk(controller)
        older.content = "a\nb"
        older.updatedAt = Date().addingTimeInterval(-1)
        controller.pendingExternalNote = older
        controller.flushPendingSave()

        XCTAssertEqual(try onDisk(controller).content, "a\nX\nb")
    }

    /// A note created with text (clipboard, Service, URL) is saved before its
    /// window exists, and the watcher reports that write a moment later. It
    /// must not be taken for an outside edit and merged against a quick edit.
    func testACreationEchoOfACapturedNoteIsNotMergedAsAConflict() throws {
        let controller = try openNote(content: "captured text")
        type("captured txt", into: controller)

        controller.handleStoreChange()
        controller.flushPendingSave()

        let content = try onDisk(controller).content
        XCTAssertEqual(content, "captured txt")
        XCTAssertFalse(content.contains("Conflicted copy"), "got \(content)")
    }

    // MARK: - Round trip through the vault

    /// What a vault user actually does: edit in Obsidian, come back, edit
    /// here. The note should end up with both, and still be one file.
    func testANoteEditedInBothPlacesKeepsBothEdits() throws {
        let controller = try openNote(content: "shopping")
        type("shopping\n- milk", into: controller)
        controller.flushPendingSave()

        // Obsidian appends its own line and writes the file.
        var fromObsidian = try onDisk(controller)
        fromObsidian.content = "shopping\n- milk\n- bread"
        store.save(fromObsidian)

        controller.handleStoreChange()

        XCTAssertEqual(controller.textView.string, "shopping\n- milk\n- bread",
                       "the editor did not pick up the vault's version")
        XCTAssertEqual(store.loadActive().filter { $0.id == controller.noteId }.count, 1,
                       "the note was duplicated")
    }
}
