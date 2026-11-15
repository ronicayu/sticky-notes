import AppKit
import XCTest
@testable import StickyNotesKit

/// A real `NoteWindowController` over a real `NoteStore` in a temp directory,
/// driven through the same delegate callbacks AppKit invokes. The save and merge
/// rules are tested without a window in `NoteDocumentTests`; these prove the
/// window forwards typing, title edits, closing and store changes to the
/// document, and draws what the document adopts from outside.
///
/// Not covered here: anything that needs a key window or a live field editor.
@MainActor final class NoteWindowEndToEndTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var clock: ManualClock!
    private var scheduler: TestScheduler!
    private var closed: [UUID] = []
    private var controllers: [NoteWindowController] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteWindowE2E-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clock = ManualClock()
        scheduler = TestScheduler(clock: clock)
        store = NoteStore(rootURL: root, clock: clock)
    }

    override func tearDown() async throws {
        controllers.forEach { $0.window?.close() }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Harness

    /// A saved note and an open window showing it.
    private func openNote(title: String = "Note", content: String = "") throws -> NoteWindowController {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        note.title = title
        note.content = content
        store.save(note)
        let controller = NoteWindowController(
            note: note, store: store, clock: clock, scheduler: scheduler, onClosed: { [unowned self] in closed.append($0) }
        )
        controllers.append(controller)
        return controller
    }

    /// Type into the body the way AppKit does: set the text, then fire the
    /// delegate callback that a real keystroke would.
    private func type(_ text: String, into controller: NoteWindowController) {
        controller.textView.string = text
        controller.editor.textDidChange(
            Notification(name: NSText.didChangeNotification, object: controller.textView)
        )
    }

    private func typeTitle(_ text: String, into controller: NoteWindowController) {
        controller.titleField.stringValue = text
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.titleField)
        )
    }

    private func onDisk(_ controller: NoteWindowController) throws -> Note {
        try XCTUnwrap(store.loadNote(id: controller.noteId), "note is not in the active folder")
    }

    /// What Obsidian does: rewrite the file in place, behind the store's back,
    /// then the watcher reports it.
    private func writeOutside(_ controller: NoteWindowController, title: String = "Note", body: String) throws {
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: store.activeURL, includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "md" })
        try "---\nid: \(controller.noteId.uuidString)\ntitle: \"\(title)\"\nupdated: 2030-01-01T00:00:00Z\n---\n\(body)"
            .write(to: file, atomically: true, encoding: .utf8)
        store.handleFileSystemEvent()
    }

    // MARK: - Typing reaches disk

    func testTypingReachesDiskOnceTheDebounceFires() throws {
        let controller = try openNote()
        type("groceries", into: controller)

        XCTAssertEqual(try onDisk(controller).content, "", "saved before the debounce elapsed")
        scheduler.advance(by: 0.6)
        XCTAssertEqual(try onDisk(controller).content, "groceries")
    }

    func testATitleTypedInTheFieldReachesDisk() throws {
        let controller = try openNote(title: "Old")
        typeTitle("A better title", into: controller)

        scheduler.advance(by: 0.6)
        XCTAssertEqual(try onDisk(controller).title, "A better title")
    }

    func testMovingTheWindowSavesItsPlace() throws {
        let controller = try openNote()
        let window = try XCTUnwrap(controller.window)
        window.setFrameOrigin(NSPoint(x: 123, y: 234))
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))

        scheduler.advance(by: 0.6)
        XCTAssertEqual(try onDisk(controller).positionX, Double(window.frame.origin.x))
        XCTAssertEqual(try onDisk(controller).positionY, Double(window.frame.origin.y))
    }

    func testFlushingWritesTextTypedSinceTheLastPause() throws {
        let controller = try openNote()
        type("half a sentence", into: controller)

        XCTAssertTrue(controller.flushPendingSave())
        XCTAssertEqual(try onDisk(controller).content, "half a sentence")
        XCTAssertEqual(controller.bufferedNote.content, "half a sentence")
    }

    /// Opening a window must not arm a save: otherwise quitting rewrites every
    /// open note, and in a synced vault that re-uploads all of them.
    func testOpeningAWindowLeavesTheNoteCleanAndAFlushWritesNothing() throws {
        let controller = try openNote(content: "untouched")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: store.activeURL, includingPropertiesForKeys: nil
        ).first)
        let before = try Data(contentsOf: file)
        let updated = try onDisk(controller).updatedAt
        clock.advance(by: 60)

        XCTAssertEqual(scheduler.pendingCount, 0, "opening the window armed a save")
        XCTAssertTrue(controller.flushPendingSave())

        XCTAssertEqual(try onDisk(controller).updatedAt, updated)
        XCTAssertEqual(try Data(contentsOf: file), before, "flush rewrote an untouched note")
    }

    // MARK: - Closing

    func testArchivingKeepsTextTypedRightBeforeIt() throws {
        let controller = try openNote(content: "first draft")
        var undoable: Note?
        controller.onArchived = { undoable = $0 }
        type("first draft plus a late thought", into: controller)

        controller.closeNote()

        let archived = try XCTUnwrap(store.loadArchived().first { $0.id == controller.noteId })
        XCTAssertEqual(archived.content, "first draft plus a late thought")
        XCTAssertEqual(undoable?.content, "first draft plus a late thought")
        XCTAssertEqual(closed, [controller.noteId])
    }

    func testClosingAnEmptyNoteDiscardsItWithoutAnUndo() throws {
        let controller = try openNote(title: "", content: "")
        var offered = false
        controller.onArchived = { _ in offered = true }
        type("x", into: controller)
        type("", into: controller)

        controller.closeNote()

        XCTAssertFalse(offered)
        XCTAssertNil(store.loadNote(id: controller.noteId))
        XCTAssertTrue(store.loadArchived().isEmpty)
        XCTAssertEqual(closed, [controller.noteId])
    }

    func testAFailedSaveKeepsTheWindowOpenAndOffersARetry() throws {
        let controller = try openNote(content: "on disk")
        var retry: (() -> Void)?
        controller.onCloseRefused = { retry = $0 }
        type("on disk plus a new thought", into: controller)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.activeURL.path)
        addTeardownBlock { [store = store!] in
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.activeURL.path)
        }

        controller.closeNote()

        XCTAssertTrue(closed.isEmpty, "the window closed with text that reached no file")
        XCTAssertTrue(store.loadArchived().isEmpty, "the note was archived without its text")
        XCTAssertEqual(controller.textView.string, "on disk plus a new thought")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.activeURL.path)
        try XCTUnwrap(retry)()

        XCTAssertEqual(closed, [controller.noteId])
        XCTAssertEqual(try XCTUnwrap(store.loadArchived().first).content, "on disk plus a new thought")
    }

    func testAWindowClosedBecauseItsFileVanishedDoesNotWriteItBack() throws {
        let controller = try openNote()
        type("typed just before the other Mac archived it", into: controller)
        store.discardActive(controller.bufferedNote)

        controller.closeAfterExternalDeletion()
        scheduler.advance(by: 10)

        XCTAssertNil(store.loadNote(id: controller.noteId), "the note was resurrected")
    }

    // MARK: - Edits arriving from outside

    func testAnOutsideWriteReachesAnIdleWindowAndDrawsIt() throws {
        let controller = try openNote(title: "Note", content: "original")
        _ = store.loadActive()

        try writeOutside(controller, title: "Retitled", body: "rewritten in Obsidian")
        controller.handleStoreChange()

        XCTAssertEqual(controller.textView.string, "rewritten in Obsidian")
        XCTAssertEqual(controller.titleField.stringValue, "Retitled")
        XCTAssertFalse(controller.noteDocument.hasUnsavedEdits, "drawing an outside edit counted as typing")
    }

    /// Drawing an adopted edit must not read back as the person's own typing, or
    /// the window would hold every later outside edit back.
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
        XCTAssertNil(controller.noteDocument.pendingExternal)
    }

    func testAnOutsideWriteDefersToUnsavedTypingAndBothSidesSurvive() throws {
        let controller = try openNote(content: "original")
        _ = store.loadActive()
        type("original plus mine", into: controller)

        try writeOutside(controller, body: "original\nfrom Obsidian")
        controller.handleStoreChange()

        XCTAssertEqual(controller.textView.string, "original plus mine", "typing was overwritten")
        XCTAssertNotNil(controller.noteDocument.pendingExternal)
        controller.flushPendingSave()
        let content = try onDisk(controller).content
        XCTAssertTrue(content.contains("original plus mine"), content)
        XCTAssertTrue(content.contains("from Obsidian"), content)
        XCTAssertEqual(controller.textView.string, content, "the window did not show the merged text")
    }

    func testTheAppsOwnSaveEchoDoesNotDuplicateTheNote() throws {
        let controller = try openNote()
        type("hello world", into: controller)
        controller.flushPendingSave()

        type("hello wrld", into: controller)
        controller.handleStoreChange()
        controller.flushPendingSave()

        let content = try onDisk(controller).content
        XCTAssertEqual(content, "hello wrld")
        XCTAssertFalse(content.contains("Conflicted copy"), "merged the note with its own echo: \(content)")
    }

    func testLosingKeyMergesAHeldBackEditAndShowsIt() throws {
        let controller = try openNote(content: "original")
        _ = store.loadActive()
        type("original plus mine", into: controller)
        try writeOutside(controller, body: "original\nfrom Obsidian")
        controller.handleStoreChange()

        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))

        XCTAssertNil(controller.noteDocument.pendingExternal)
        XCTAssertTrue(controller.textView.string.contains("from Obsidian"), controller.textView.string)
        XCTAssertTrue(try onDisk(controller).content.contains("original plus mine"))
    }

    // MARK: - Round trip through the vault

    func testANoteEditedInBothPlacesKeepsBothEdits() throws {
        let controller = try openNote(content: "shopping")
        type("shopping\n- milk", into: controller)
        controller.flushPendingSave()

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
