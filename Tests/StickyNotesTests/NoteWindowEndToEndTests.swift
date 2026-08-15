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
/// live field editor (the in-progress-title rule), and `AppDelegate` itself,
/// which builds a `NoteStore()` against the user's real storage and so must
/// never be instantiated by a test.
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
