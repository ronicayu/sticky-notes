import AppKit
import XCTest
@testable import StickyNotesKit

/// The desk on its own: a store in a temp folder, a throwaway settings suite and
/// a hand-moved clock. No `AppDelegate`, no menus, no observers: each test
/// calls what the real notifications would call.
@MainActor final class DeskControllerTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var isolated: IsolatedSettings!
    private var clock: ManualClock!
    private var desk: DeskController!
    private var originalTextSize: CGFloat = MarkdownStyler.baseFontSize

    override func setUpWithError() throws {
        _ = NSApplication.shared
        originalTextSize = MarkdownStyler.baseFontSize
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Desk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(rootURL: root, format: .markdown)
        isolated = IsolatedSettings()
        clock = ManualClock()
        desk = makeDesk()
    }

    override func tearDownWithError() throws {
        desk.windowControllers.values.forEach { $0.window?.close() }
        desk.dailyNote?.window?.close()
        desk = nil
        MarkdownStyler.baseFontSize = originalTextSize
        isolated.tearDown()
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDesk() -> DeskController {
        DeskController(
            store: store,
            settings: isolated.settings,
            clock: clock,
            undo: UndoCenter(clock: clock),
            recovery: RecoveryFiles(settings: isolated.settings, store: store, clock: clock)
        )
    }

    @discardableResult
    private func seed(_ title: String, labels: [String] = []) -> Note {
        var note = Note.makeNew(frame: NSRect(x: 40, y: 40, width: 240, height: 200), now: clock.now())
        note.title = title
        note.content = "body of \(title)"
        note.labels = labels
        store.save(note)
        return note
    }

    private func isShowing(_ note: Note) -> Bool {
        desk.windowControllers[note.id]?.window?.isVisible == true
    }

    /// The desk defers its store reactions with `DispatchQueue.main.async`. The
    /// main queue runs blocks in order, so a block queued after the call has run
    /// once everything the call queued has.
    private func waitForDeferredWork() {
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    // MARK: - Restoring

    func testRestoringOpensOneWindowPerActiveNoteAndNoneForAnArchivedOne() {
        let first = seed("First")
        let archived = seed("Archived")
        store.archive(archived)

        desk.restoreActiveNotes()

        XCTAssertEqual(Set(desk.windowControllers.keys), [first.id])
    }

    // MARK: - Visibility

    func testHideAllHidesEveryNoteAndShowingThemAgainBringsThemBack() {
        let a = seed("A"), b = seed("B")
        desk.restoreActiveNotes()
        XCTAssertTrue(isShowing(a) && isShowing(b))

        desk.toggleHideAll()
        XCTAssertTrue(desk.notesHidden)
        XCTAssertFalse(isShowing(a) || isShowing(b))

        desk.toggleHideAll()
        XCTAssertFalse(desk.notesHidden)
        XCTAssertTrue(isShowing(a) && isShowing(b))
    }

    func testHideAllWithNothingOnTheDeskDoesNothing() {
        desk.toggleHideAll()
        XCTAssertFalse(desk.notesHidden)
    }

    func testAHiddenLabelHidesOnlyTheNotesThatCarryIt() {
        let work = seed("Work", labels: ["work"])
        let home = seed("Home", labels: ["home"])
        let plain = seed("Plain")
        desk.restoreActiveNotes()

        desk.toggleLabelVisibility("work")

        XCTAssertFalse(isShowing(work))
        XCTAssertTrue(isShowing(home) && isShowing(plain))
        XCTAssertEqual(isolated.settings.hiddenLabels, ["work"])

        desk.toggleLabelVisibility("work")
        XCTAssertTrue(isShowing(work))
        XCTAssertEqual(isolated.settings.hiddenLabels, [])
    }

    func testShowAllLabelsBringsEveryHiddenNoteBack() {
        let work = seed("Work", labels: ["work"])
        let home = seed("Home", labels: ["home"])
        desk.restoreActiveNotes()
        desk.toggleLabelVisibility("work")
        desk.toggleLabelVisibility("home")
        XCTAssertFalse(isShowing(work) || isShowing(home))

        desk.showAllLabels()

        XCTAssertTrue(isShowing(work) && isShowing(home))
    }

    func testHideAllBeatsLabelVisibilityAndLabelsStayHiddenAfterShowAll() {
        let work = seed("Work", labels: ["work"])
        let plain = seed("Plain")
        desk.restoreActiveNotes()
        desk.toggleLabelVisibility("work")

        desk.toggleHideAll()
        desk.toggleHideAll()

        XCTAssertFalse(isShowing(work), "showing all notes brought back one whose label is hidden")
        XCTAssertTrue(isShowing(plain))
    }

    func testMakingANoteWhileEverythingIsHiddenBringsTheDeskBack() {
        let a = seed("A")
        desk.restoreActiveNotes()
        desk.toggleHideAll()

        let id = desk.makeNote(title: "Fresh")

        XCTAssertFalse(desk.notesHidden)
        XCTAssertTrue(isShowing(a))
        XCTAssertEqual(desk.windowControllers[id]?.window?.isVisible, true)
    }

    // MARK: - Making notes

    func testMakeNoteSavesAndShowsTheNoteWithTheGivenFieldsAndTheInjectedColourAndClock() throws {
        isolated.settings.defaultNoteColor = .green
        clock.advance(by: 7_200)

        let id = desk.makeNote(title: "Titled", text: "some words", labels: ["idea"])

        let saved = try XCTUnwrap(store.loadNote(id: id))
        XCTAssertEqual(saved.title, "Titled")
        XCTAssertEqual(saved.content, "some words")
        XCTAssertEqual(saved.labels, ["idea"])
        XCTAssertEqual(saved.color, .green)
        XCTAssertEqual(saved.createdAt.timeIntervalSince1970, clock.now().timeIntervalSince1970, accuracy: 1)
        XCTAssertNotNil(desk.windowControllers[id])
    }

    func testAnExplicitColourBeatsTheDefault() throws {
        isolated.settings.defaultNoteColor = .green
        let id = desk.makeNote(color: .pink)
        XCTAssertEqual(store.loadNote(id: id)?.color, .pink)
    }

    func testTwoNewNotesDoNotOpenOnTheSameSpot() throws {
        let first = desk.makeNote()
        let second = desk.makeNote()
        let frame1 = try XCTUnwrap(desk.windowControllers[first]?.window?.frame)
        let frame2 = try XCTUnwrap(desk.windowControllers[second]?.window?.frame)
        XCTAssertNotEqual(frame1.origin, frame2.origin)
    }

    // MARK: - Store changes

    func testReconcileClosesTheWindowOfANoteThatLeftTheActiveFolderAndOpensOneThatArrived() {
        let kept = seed("Kept")
        let leaving = seed("Leaving")
        desk.restoreActiveNotes()
        store.archive(leaving)
        let arrived = seed("Arrived from another Mac")

        desk.reconcileOpenWindows()

        XCTAssertEqual(Set(desk.windowControllers.keys), [kept.id, arrived.id])
    }

    func testASaveByThisStoreOfAShownNoteOnlyReappliesVisibility() {
        let shown = seed("Shown", labels: ["work"])
        desk.restoreActiveNotes()
        let unseen = seed("Synced in")
        isolated.settings.hiddenLabels = ["work"]

        desk.storeDidChange(Notification(
            name: NoteStore.didChange, object: store, userInfo: [NoteStore.changeKey: NoteStore.Change.saved(shown.id)]
        ))
        waitForDeferredWork()

        XCTAssertFalse(isShowing(shown), "the label filter was not re-applied")
        XCTAssertNil(desk.windowControllers[unseen.id], "a save by this store triggered a full reconcile")
    }

    func testAnyOtherChangeReconcilesWindowsWithTheStore() {
        seed("Shown")
        desk.restoreActiveNotes()
        let unseen = seed("Synced in")

        desk.storeDidChange(Notification(name: NoteStore.didChange, object: store))
        waitForDeferredWork()

        XCTAssertNotNil(desk.windowControllers[unseen.id])
    }

    func testASaveByAnotherStoreOfAShownNoteReconciles() {
        let shown = seed("Shown")
        desk.restoreActiveNotes()
        let unseen = seed("Synced in")
        let other = NoteStore(rootURL: root, format: .markdown)

        desk.storeDidChange(Notification(
            name: NoteStore.didChange, object: other, userInfo: [NoteStore.changeKey: NoteStore.Change.saved(shown.id)]
        ))
        waitForDeferredWork()

        XCTAssertNotNil(desk.windowControllers[unseen.id])
    }

    // MARK: - Text size

    func testChangingTheTextSizeIsRememberedAndClampedAndResets() {
        let base = isolated.settings.bodyFontSize
        desk.increaseTextSize()
        XCTAssertEqual(isolated.settings.bodyFontSize, base + 1)
        XCTAssertEqual(MarkdownStyler.baseFontSize, base + 1)

        desk.decreaseTextSize()
        desk.decreaseTextSize()
        XCTAssertEqual(MarkdownStyler.baseFontSize, base - 1)

        desk.resetTextSize()
        XCTAssertEqual(isolated.settings.bodyFontSize, Settings.defaultBodyFontSize)

        for _ in 0..<100 { desk.increaseTextSize() }
        XCTAssertEqual(isolated.settings.bodyFontSize, Settings.clampFontSize(1_000))
    }

    func testChangingTheTextSizeRestylesOpenNotes() throws {
        let note = seed("Sized")
        desk.restoreActiveNotes()
        let controller = try XCTUnwrap(desk.windowControllers[note.id])

        desk.increaseTextSize()

        let size = (controller.editor.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
        XCTAssertEqual(size, isolated.settings.bodyFontSize)
    }

    // MARK: - Daily note

    private func useVault() throws {
        let vault = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        isolated.settings.obsidianVaultPath = vault.path
        isolated.settings.dailyNotesPattern = "Daily/{YYYY}-{MM}-{DD}.md"
    }

    func testTheDailyNoteNeedsAVaultAndAPattern() {
        XCTAssertFalse(desk.canShowDailyNote)
        desk.toggleDailyNote()
        XCTAssertNil(desk.dailyNote)
    }

    func testOpeningTodaysDailyNoteShowsItAndTogglingHidesItAgain() throws {
        try useVault()

        desk.openTodaysDailyNote()
        XCTAssertTrue(desk.isDailyNoteVisible)

        desk.toggleDailyNote()
        XCTAssertFalse(desk.isDailyNoteVisible)

        desk.openTodaysDailyNote()
        XCTAssertTrue(desk.isDailyNoteVisible, "open must end with the note showing even after a hide")
    }

    func testHideAllHidesTheDailyNoteAndShowAllReturnsItOnlyIfItWasVisible() throws {
        try useVault()
        seed("Companion")
        desk.restoreActiveNotes()
        desk.openTodaysDailyNote()

        desk.toggleHideAll()
        XCTAssertFalse(desk.isDailyNoteVisible)
        desk.toggleHideAll()
        XCTAssertTrue(desk.isDailyNoteVisible)

        desk.toggleDailyNote()
        desk.toggleHideAll()
        desk.toggleHideAll()
        XCTAssertFalse(desk.isDailyNoteVisible, "a note the person hid came back with show-all")
    }

    func testWakingMovesADailyNoteLeftOpenAcrossMidnightToToday() throws {
        try useVault()
        desk.openTodaysDailyNote()
        let document = try XCTUnwrap(desk.dailyNote).dailyDocument
        let before = document.day

        clock.advance(by: 36 * 3_600)
        desk.handleWake()

        XCTAssertGreaterThan(document.day, before)
    }

    func testTearingDownTheDailyNoteRemovesItsWindow() throws {
        try useVault()
        desk.openTodaysDailyNote()

        desk.tearDownDailyNote()

        XCTAssertNil(desk.dailyNote)
    }

    // MARK: - Quitting

    func testFlushForQuitCountsNothingWhenEverythingIsOnDisk() {
        seed("Calm")
        desk.restoreActiveNotes()
        XCTAssertEqual(desk.flushForQuit(), 0)
    }
}
