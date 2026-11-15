import AppKit
import XCTest
@testable import StickyNotesKit

/// What the person sees of their note windows while they work: a note they open
/// or type in does not vanish, and launching the app does not take their focus.
/// A test host is never active and never gives a window key status, so the desk's
/// `isKeyWindow` and `activateApp` are replaced.
@MainActor final class NoteWindowFocusAndVisibilityTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var isolated: IsolatedSettings!
    private var clock: ManualClock!
    private var desk: DeskController!
    private var activations = 0

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Focus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(rootURL: root)
        isolated = IsolatedSettings()
        clock = ManualClock()
        let undo = UndoCenter(clock: clock)
        desk = DeskController(
            store: store, settings: isolated.settings, clock: clock, undo: undo,
            recovery: RecoveryFiles(settings: isolated.settings, store: store, clock: clock),
            scheduler: TestScheduler(clock: clock)
        )
        activations = 0
        desk.activateApp = { [unowned self] in activations += 1 }
    }

    override func tearDown() async throws {
        store?.stopWatching()
        desk.windowControllers.values.forEach { $0.window?.close() }
        desk.dailyNote?.window?.close()
        desk = nil
        isolated.tearDown()
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func seed(_ title: String, labels: [String] = [], collapsed: Bool = false) -> Note {
        var note = Note.makeNew(frame: NSRect(x: 40, y: 140, width: 240, height: 200), now: clock.now())
        note.title = title
        note.content = "body of \(title)"
        note.labels = labels
        store.save(note)
        if collapsed {
            desk.layout.set(NoteLayout(x: 40, y: 140, width: 240, height: 200, collapsed: true), for: note.id)
        }
        return note
    }

    private func isShowing(_ note: Note) -> Bool {
        desk.windowControllers[note.id]?.window?.isVisible == true
    }

    /// The store tells the desk about a save of a note that has a window, and the
    /// desk reacts on the next turn of the main queue.
    private func saveHappens(to note: Note) {
        desk.storeDidChange(Notification(
            name: NoteStore.didChange, object: store,
            userInfo: [NoteStore.changeKey: NoteStore.Change.saved(note.id)]
        ))
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    // MARK: - A note does not vanish under the person

    func testANoteOpenedWhileAllAreHiddenStaysUpThroughItsFirstSave() {
        let note = seed("Opened")
        seed("Other")
        desk.restoreActiveNotes()
        desk.toggleHideAll()

        desk.focusNote(id: note.id)
        saveHappens(to: note)

        XCTAssertFalse(desk.notesHidden)
        XCTAssertTrue(isShowing(note), "the note the person opened was ordered out by its own save")
    }

    func testANoteWithAHiddenLabelThatWasOpenedOnPurposeStaysUpWhenItLosesKey() throws {
        let note = seed("Work note", labels: ["work"])
        desk.restoreActiveNotes()
        desk.toggleLabelVisibility("work")
        XCTAssertFalse(isShowing(note))

        desk.focusNote(id: note.id)
        let controller = try XCTUnwrap(desk.windowControllers[note.id])
        let window = try XCTUnwrap(controller.window)
        desk.isKeyWindow = { $0 === window }
        saveHappens(to: note)
        XCTAssertTrue(isShowing(note), "typing in a note with a hidden label made it vanish")

        desk.isKeyWindow = { _ in false }
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        saveHappens(to: note)
        desk.reconcileOpenWindows()

        XCTAssertTrue(isShowing(note), "the note the person opened vanished when they left it")
    }

    func testANoteTypedInThatGainsAHiddenLabelStaysUpAfterItLosesKey() throws {
        let note = seed("Typing", labels: ["work"])
        desk.restoreActiveNotes()
        let controller = try XCTUnwrap(desk.windowControllers[note.id])
        let window = try XCTUnwrap(controller.window)
        desk.isKeyWindow = { $0 === window }
        isolated.settings.hiddenLabels = ["work"]
        saveHappens(to: note)
        XCTAssertTrue(isShowing(note))

        desk.isKeyWindow = { _ in false }
        saveHappens(to: note)

        XCTAssertTrue(isShowing(note), "a later store change took the note away after the person left it")
    }

    func testHideAllHidesANoteTheyOpenedOnPurposeAndItDoesNotComeBackWithItsLabelHidden() throws {
        let note = seed("Work note", labels: ["work"])
        desk.restoreActiveNotes()
        desk.toggleLabelVisibility("work")
        desk.focusNote(id: note.id)
        XCTAssertTrue(isShowing(note))

        desk.toggleHideAll()
        XCTAssertFalse(isShowing(note))
        desk.toggleHideAll()

        XCTAssertFalse(isShowing(note), "the label is still hidden: showing all brought back a note it hides")
    }

    func testHidingOneOfTheLabelsOfANoteTheyOpenedOnPurposeHidesIt() throws {
        let note = seed("Both", labels: ["work", "play"])
        desk.restoreActiveNotes()
        desk.toggleLabelVisibility("work")
        desk.focusNote(id: note.id)
        XCTAssertTrue(isShowing(note))

        desk.toggleLabelVisibility("play")

        XCTAssertFalse(isShowing(note))
    }

    func testTheDailyNoteOpenedFromTheMenuWhileAllAreHiddenStaysUpThroughAStoreChange() throws {
        let vault = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        isolated.settings.obsidianVaultPath = vault.path
        isolated.settings.dailyNotesPattern = "Daily/{YYYY}-{MM}-{DD}.md"
        let note = seed("Other")
        desk.restoreActiveNotes()
        desk.toggleHideAll()

        desk.toggleDailyNote()
        saveHappens(to: note)
        desk.reconcileOpenWindows()

        XCTAssertFalse(desk.notesHidden)
        XCTAssertTrue(desk.isDailyNoteVisible, "the daily note the person opened was hidden by a store change")
    }

    func testTheHideAllCommandStillHidesTheNoteBeingTypedIn() throws {
        let note = seed("Typing")
        desk.restoreActiveNotes()
        let window = try XCTUnwrap(desk.windowControllers[note.id]?.window)
        desk.isKeyWindow = { $0 === window }

        desk.toggleHideAll()

        XCTAssertFalse(isShowing(note))
    }

    // MARK: - Launch does not take focus

    func testRestoringNotesAtLaunchDoesNotActivateTheApp() {
        seed("First")
        seed("Second", collapsed: true)

        desk.restoreActiveNotes()

        XCTAssertEqual(desk.windowControllers.count, 2)
        XCTAssertTrue(desk.windowControllers.values.allSatisfy { $0.window?.isVisible == true })
        XCTAssertEqual(activations, 0, "launching the app took focus from the app the person was in")
    }

    func testRestoringTheDailyNoteAtLaunchDoesNotActivateTheApp() throws {
        let vault = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        isolated.settings.obsidianVaultPath = vault.path
        isolated.settings.dailyNotesPattern = "Daily/{YYYY}-{MM}-{DD}.md"
        desk.openTodaysDailyNote()
        desk.tearDownDailyNote()
        activations = 0

        desk.restoreDailyNoteIfNeeded()

        XCTAssertTrue(desk.isDailyNoteVisible)
        XCTAssertEqual(activations, 0)
    }

    func testOpeningANoteOnPurposeStillActivatesTheApp() {
        let note = seed("Asked for")
        desk.restoreActiveNotes()

        desk.focusNote(id: note.id)

        XCTAssertEqual(activations, 1)
    }

    func testACollapsedNoteDoesNotStartWithFocusInItsHiddenBody() throws {
        let collapsed = seed("Bar", collapsed: true)
        let expanded = seed("Open")
        desk.restoreActiveNotes()
        let bar = try XCTUnwrap(desk.windowControllers[collapsed.id])
        let open = try XCTUnwrap(desk.windowControllers[expanded.id])

        XCTAssertFalse(bar.window?.initialFirstResponder === bar.textView, "a collapsed note would take typing into text nobody can see")
        XCTAssertTrue(open.window?.initialFirstResponder === open.textView)

        bar.dragZoneDidDoubleClick()
        XCTAssertTrue(bar.window?.initialFirstResponder === bar.textView, "expanding must put focus back in the body")
        bar.dragZoneDidDoubleClick()
        XCTAssertFalse(bar.window?.initialFirstResponder === bar.textView)
    }
}
