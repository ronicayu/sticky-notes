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
    private var undo: UndoCenter!
    private var scheduler: TestScheduler!
    private var originalTextSize: CGFloat = MarkdownStyler.baseFontSize

    override func setUp() async throws {
        _ = NSApplication.shared
        originalTextSize = MarkdownStyler.baseFontSize
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Desk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(rootURL: root)
        isolated = IsolatedSettings()
        clock = ManualClock()
        desk = makeDesk()
    }

    override func tearDown() async throws {
        for folder in [store.activeURL, store.archiveURL] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
        desk.windowControllers.values.forEach { $0.window?.close() }
        desk.dailyNote?.window?.close()
        desk = nil
        MarkdownStyler.baseFontSize = originalTextSize
        isolated.tearDown()
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDesk() -> DeskController {
        undo = UndoCenter(clock: clock)
        scheduler = TestScheduler(clock: clock)
        return DeskController(
            store: store,
            settings: isolated.settings,
            clock: clock,
            undo: undo,
            recovery: RecoveryFiles(settings: isolated.settings, store: store, clock: clock),
            scheduler: scheduler
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
        XCTAssertEqual(desk.windowControllers[id]?.bufferedNote.color, .pink)
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
        let other = NoteStore(rootURL: root)

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

    // MARK: - Notes that leave the active folder under typing, and new notes

    private func type(_ text: String, into controller: NoteWindowController) {
        controller.textView.string = text
        controller.editor.textDidChange(
            Notification(name: NSText.didChangeNotification, object: controller.textView)
        )
    }

    private func files(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
    }

    private func setPermissions(_ mode: Int, on folder: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: folder.path)
    }

    /// ⌘⌫ in the notes panel within the debounce of typing used to move a file
    /// that lacked the typing, and the window's save was then dropped.
    /// (Model finding F5, plan R9.)
    func testArchivingFromThePanelKeepsTextTypedJustBefore() throws {
        let note = seed("Groceries")
        desk.restoreActiveNotes()
        let controller = try XCTUnwrap(desk.windowControllers[note.id])
        type("body of Groceries plus a late thought", into: controller)

        desk.showNotesPanel()
        try XCTUnwrap(desk.notesPanel).archiveFirstRow()

        XCTAssertEqual(store.loadArchived().first { $0.id == note.id }?.content, "body of Groceries plus a late thought")
        XCTAssertNil(desk.windowControllers[note.id], "the window of an archived note stayed")
        XCTAssertNil(store.loadNote(id: note.id))
        XCTAssertTrue(undo.hasPendingOffer, "the panel's archive offered no undo")
    }

    func testArchivingFromThePanelAnUnopenedNoteOffersTheUndoToo() throws {
        let note = seed("No window")

        desk.archiveNote(note)

        XCTAssertEqual(store.loadArchived().map(\.id), [note.id])
        XCTAssertTrue(undo.hasPendingOffer)
    }

    /// (Model finding F5, trace a-removal-r3: the watcher closes the window.)
    func testReconcileKeepsTheTypingOfANoteArchivedElsewhere() throws {
        let note = seed("Shared")
        desk.restoreActiveNotes()
        let controller = try XCTUnwrap(desk.windowControllers[note.id])
        type("body of Shared and typed after the other Mac archived it", into: controller)
        store.archive(note)

        desk.reconcileOpenWindows()

        XCTAssertNil(desk.windowControllers[note.id])
        XCTAssertEqual(
            store.loadArchived().first { $0.id == note.id }?.content,
            "body of Shared and typed after the other Mac archived it"
        )
    }

    func testReconcileKeepsTheTypingOfANoteThatWasRemovedInARecoveredCopyAndSaysSo() throws {
        let note = seed("Removed")
        desk.restoreActiveNotes()
        let controller = try XCTUnwrap(desk.windowControllers[note.id])
        type("body of Removed plus more", into: controller)
        try FileManager.default.removeItem(at: XCTUnwrap(files(in: store.activeURL).first))
        store.handleFileSystemEvent()

        desk.reconcileOpenWindows()

        XCTAssertNil(desk.windowControllers[note.id])
        XCTAssertEqual(store.loadTrashed().first?.content, "body of Removed plus more")
        XCTAssertNil(store.loadNote(id: note.id))
        XCTAssertTrue(undo.hasPendingOffer, "the person was not told where the text went")
    }

    /// Where the store cannot take the text, a recovery file beside the storage does.
    func testReconcileFallsBackToARecoveryFileWhenTheStoreCannotTakeTheText() throws {
        let note = seed("Locked")
        desk.restoreActiveNotes()
        let controller = try XCTUnwrap(desk.windowControllers[note.id])
        type("body of Locked and more", into: controller)
        store.archive(note)
        try setPermissions(0o555, on: store.archiveURL)

        desk.reconcileOpenWindows()

        XCTAssertNil(desk.windowControllers[note.id])
        let recovered = try files(in: RecoveryFiles(settings: isolated.settings, store: store, clock: clock).folder)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertTrue(try String(contentsOf: XCTUnwrap(recovered.first)).contains("body of Locked and more"))
    }

    func testReconcileKeepsTheWindowWhenNothingCanTakeTheText() throws {
        let note = seed("Stuck")
        desk.restoreActiveNotes()
        let controller = try XCTUnwrap(desk.windowControllers[note.id])
        type("body of Stuck and more", into: controller)
        store.archive(note)
        try setPermissions(0o555, on: store.archiveURL)
        try setPermissions(0o555, on: isolated.localRoot)
        addTeardownBlock { [root = isolated.localRoot] in
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        }

        desk.reconcileOpenWindows()

        XCTAssertNotNil(desk.windowControllers[note.id], "the window closed with its text nowhere")
        XCTAssertEqual(controller.bufferedNote.content, "body of Stuck and more")
    }

    /// A folder that cannot be listed reads as a vault with no notes in it.
    /// (Plan R3.)
    func testReconcileClosesNothingWhenTheNotesFolderCannotBeListed() throws {
        let first = seed("First")
        let second = seed("Second")
        desk.restoreActiveNotes()
        let controller = try XCTUnwrap(desk.windowControllers[first.id])
        type("body of First plus typing", into: controller)
        try setPermissions(0o000, on: store.activeURL)
        store.handleFileSystemEvent()

        desk.reconcileOpenWindows()

        XCTAssertEqual(Set(desk.windowControllers.keys), [first.id, second.id])
        XCTAssertFalse(controller.flushPendingSave(), "the text was marked saved while the folder was unreachable")
        try setPermissions(0o755, on: store.activeURL)
        XCTAssertTrue(controller.flushPendingSave())
        XCTAssertEqual(store.loadNote(id: first.id)?.content, "body of First plus typing")
    }

    func testReconcileKeepsTheWindowOfANoteWhoseFileIsStillInICloud() throws {
        let note = seed("Downloading")
        desk.restoreActiveNotes()
        let file = try XCTUnwrap(files(in: store.activeURL).first)
        try FileManager.default.moveItem(
            at: file, to: file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).icloud")
        )
        store.handleFileSystemEvent()

        desk.reconcileOpenWindows()

        XCTAssertNotNil(desk.windowControllers[note.id], "a file that is not downloaded yet closed its window")
    }

    // MARK: A new note starts unsaved

    func testAMisfiredNewNoteTouchesNoFile() throws {
        let id = desk.makeNote()
        let controller = try XCTUnwrap(desk.windowControllers[id])
        XCTAssertTrue(try files(in: store.activeURL).isEmpty, "a blank new note was written at once")
        XCTAssertFalse(controller.hasFile)

        desk.reconcileOpenWindows()
        XCTAssertNotNil(desk.windowControllers[id], "a new note has no file yet and is not gone")

        // Focus moves away: the window sweeps up an untouched note on its own.
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: controller.window))
        waitForDeferredWork()

        XCTAssertNil(desk.windowControllers[id])
        for folder in [store.activeURL, store.archiveURL, store.trashURL] {
            XCTAssertTrue(try files(in: folder).isEmpty, "\(folder.lastPathComponent) holds a file for an untouched note")
        }
    }

    func testTheFirstEditOfANewNoteWritesIt() throws {
        let id = desk.makeNote()
        let controller = try XCTUnwrap(desk.windowControllers[id])

        type("a thought", into: controller)
        desk.reconcileOpenWindows()
        XCTAssertNotNil(desk.windowControllers[id], "reconcile closed a note being typed into before its first save")
        XCTAssertTrue(controller.flushPendingSave())

        XCTAssertEqual(store.loadNote(id: id)?.content, "a thought")
        XCTAssertTrue(controller.hasFile)
    }

    func testACapturedNoteIsWrittenAtOnceBecauseItArrivedWithContent() throws {
        let withText = desk.makeNote(text: "from the clipboard")
        let withTitle = desk.makeNote(title: "From a URL")

        for id in [withText, withTitle] {
            XCTAssertNotNil(store.loadNote(id: id))
            XCTAssertEqual(desk.windowControllers[id]?.hasFile, true)
        }
    }

    /// The blur sweep judges a note blank by its trimmed title and body, so the
    /// capture must too: colour and labels alone, or whitespace, make no file.
    func testACaptureOfNothingButWhitespaceColourOrLabelsLeavesNoFileAndNoTrash() throws {
        let ids = [
            desk.makeNote(text: " \n\t"),
            desk.makeNote(color: .blue),
            desk.makeNote(labels: ["inbox"]),
        ]
        for id in ids {
            let controller = try XCTUnwrap(desk.windowControllers[id])
            XCTAssertFalse(controller.hasFile)
            controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: controller.window))
        }
        waitForDeferredWork()

        XCTAssertTrue(desk.windowControllers.isEmpty, "an untouched capture stayed on the desk")
        for folder in [store.activeURL, store.archiveURL, store.trashURL] {
            XCTAssertTrue(try files(in: folder).isEmpty, "\(folder.lastPathComponent) holds a file for an untouched capture")
        }
    }

    func testACaptureWhoseFirstWriteFailsIsWrittenToARecoveryFileAtQuit() throws {
        try setPermissions(0o555, on: store.activeURL)

        let id = desk.makeNote(text: "clipboard text that could not be written")

        XCTAssertTrue(try files(in: store.activeURL).isEmpty)
        XCTAssertEqual(desk.windowControllers[id]?.flushPendingSave(), false, "nothing was owed, so the text would be lost at quit")
        XCTAssertEqual(desk.flushForQuit(), 0, "the text was not put anywhere")
        let recovered = try files(in: RecoveryFiles(settings: isolated.settings, store: store, clock: clock).folder)
        XCTAssertTrue(try String(contentsOf: XCTUnwrap(recovered.first)).contains("clipboard text that could not be written"))
    }

    /// The other Mac archived the note and its archive cannot be read, so nowhere
    /// can be found for the text. The person's close used to be refused for as
    /// long as that lasted.
    func testClosingANoteWhoseTextHasNowhereToGoEndsWithARecoveryFileAndNoWindow() throws {
        let note = seed("Stranded")
        desk.restoreActiveNotes()
        let controller = try XCTUnwrap(desk.windowControllers[note.id])
        type("body of Stranded and a late thought", into: controller)
        store.archive(note)
        try setPermissions(0o000, on: store.archiveURL)
        store.handleFileSystemEvent()

        controller.closeNote()

        XCTAssertNil(desk.windowControllers[note.id], "the window could not be closed")
        let recovered = try files(in: RecoveryFiles(settings: isolated.settings, store: store, clock: clock).folder)
        XCTAssertTrue(try String(contentsOf: XCTUnwrap(recovered.first)).contains("a late thought"))
        XCTAssertTrue(undo.hasPendingOffer)
    }

    /// A note renamed on the other Mac and still downloading is listed under a
    /// name that says nothing of this note's.
    func testReconcileKeepsTheWindowOfANoteThatIsDownloadingUnderANewName() throws {
        let note = seed("Renamed")
        desk.restoreActiveNotes()
        let controller = try XCTUnwrap(desk.windowControllers[note.id])
        type("body of Renamed plus typing", into: controller)
        let file = try XCTUnwrap(files(in: store.activeURL).first)
        try FileManager.default.moveItem(
            at: file, to: store.activeURL.appendingPathComponent(".Shopping list.md.icloud")
        )
        store.handleFileSystemEvent()

        desk.reconcileOpenWindows()

        XCTAssertNotNil(desk.windowControllers[note.id], "a note still downloading closed its window")
        XCTAssertTrue(store.loadTrashed().isEmpty, "a recovered copy was made of a note that exists")
    }

    // MARK: - Quitting

    func testFlushForQuitCountsNothingWhenEverythingIsOnDisk() {
        seed("Calm")
        desk.restoreActiveNotes()
        XCTAssertEqual(desk.flushForQuit(), 0)
    }
}
