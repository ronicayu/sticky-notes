import AppKit
import XCTest
@testable import StickyNotesKit

/// The welcome note's four tasks tick themselves as the person does each thing,
/// through the open note window, and the checklist ends with one line in the note.
@MainActor final class WelcomeChecklistTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var isolated: IsolatedSettings!
    private var clock: ManualClock!
    private var scheduler: TestScheduler!
    private var desk: DeskController!
    private var welcomeID: UUID!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WelcomeChecklist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clock = ManualClock()
        scheduler = TestScheduler(clock: clock)
        store = NoteStore(rootURL: root, clock: clock)
        isolated = IsolatedSettings()
        desk = DeskController(
            store: store, settings: isolated.settings, clock: clock, undo: UndoCenter(clock: clock),
            recovery: RecoveryFiles(settings: isolated.settings, store: store, clock: clock),
            scheduler: scheduler,
            layout: DeviceLayoutStore(url: root.appendingPathComponent("layout.json"), scheduler: TestScheduler())
        )
        desk.motionDuration = { _ in 0 }
    }

    override func tearDown() async throws {
        desk.switcher?.dismiss()
        scheduler.advance(by: 1)
        store?.stopWatching()
        desk.windowControllers.values.forEach { $0.window?.close() }
        isolated.tearDown()
        try? FileManager.default.removeItem(at: root)
    }

    private var defaults: UserDefaults { isolated.settings.defaults }

    @discardableResult
    private func openWelcome() throws -> NoteWindowController {
        let note = try XCTUnwrap(WelcomeNote.makeIfNeeded(store: store, defaults: defaults, now: clock.now()))
        welcomeID = note.id
        desk.presentWindow(for: note)
        return try XCTUnwrap(desk.windowControllers[note.id])
    }

    private func checked(_ controller: NoteWindowController) -> [WelcomeNote.Step] {
        let text = controller.textView.string
        return WelcomeNote.Step.allCases.filter { WelcomeNote.taskLine(for: $0, in: text)?.isChecked == true }
    }

    private func onDisk() throws -> Note {
        try XCTUnwrap(store.loadNote(id: welcomeID))
    }

    /// Each thing a person does, as the app's own commands run it.
    private func perform(_ step: WelcomeNote.Step) throws {
        switch step {
        case .newNote: desk.newNote()
        case .findNote: desk.toggleQuickSwitcher()
        case .hideLabel: desk.toggleLabelVisibility("work")
        case .collapse: try XCTUnwrap(desk.windowControllers[welcomeID]).toggleCollapse()
        }
    }

    // MARK: - One event, one box

    private func assertOnlyTicks(_ step: WelcomeNote.Step, file: StaticString = #filePath, line: UInt = #line) throws {
        let controller = try openWelcome()
        XCTAssertEqual(checked(controller), [], file: file, line: line)

        try perform(step)

        XCTAssertEqual(checked(controller), [step], "\(step) ticked the wrong boxes", file: file, line: line)
        XCTAssertEqual(MarkdownEditing.checkboxProgress(in: controller.textView.string)?.done, 1, file: file, line: line)
    }

    func testPressingTheNewNoteChordChecksTheNewNoteBox() throws { try assertOnlyTicks(.newNote) }
    func testOpeningTheSwitcherChecksTheFindBox() throws { try assertOnlyTicks(.findNote) }
    func testHidingALabelChecksTheLabelBox() throws { try assertOnlyTicks(.hideLabel) }
    func testCollapsingTheNoteChecksTheCollapseBox() throws { try assertOnlyTicks(.collapse) }

    func testTheTickIsAnEditOfTheNoteAndIsSavedLikeOne() throws {
        let controller = try openWelcome()
        XCTAssertFalse(controller.noteDocument.hasUnsavedEdits)

        desk.toggleLabelVisibility("work")

        XCTAssertTrue(controller.noteDocument.hasUnsavedEdits)
        XCTAssertEqual(controller.bufferedNote.content, controller.textView.string)
        XCTAssertFalse(try onDisk().content.contains("- [x]"), "written before the debounce")

        scheduler.advance(by: NoteDocument.debounce)

        XCTAssertEqual(try onDisk().content, controller.textView.string)
        XCTAssertTrue(try onDisk().content.contains("- [x] Try a `#label`"))
        XCTAssertFalse(controller.noteDocument.hasUnsavedEdits)
    }

    func testTheCollapsedBarCountsTheTickFromTheCollapseItself() throws {
        let controller = try openWelcome()

        controller.toggleCollapse()

        let bar = try XCTUnwrap(controller.window?.contentView.flatMap { find(CenteredTitleLabel.self, in: $0) })
        XCTAssertEqual(bar.accessibilityLabel(), "Welcome, 1 of 4 tasks done, collapsed note, click to expand")
    }

    func testCollapsingAnyOtherNoteCountsToo() throws {
        let welcome = try openWelcome()
        var other = Note.makeNew(frame: NSRect(x: 80, y: 80, width: 240, height: 200), now: clock.now())
        other.title = "Other"
        other.content = "x"
        store.save(other)
        desk.presentWindow(for: other)

        try XCTUnwrap(desk.windowControllers[other.id]).toggleCollapse()

        XCTAssertEqual(checked(welcome), [.collapse])
    }

    func testTheQuickSwitcherCountsWhenItOpensNotWhenItCloses() throws {
        let controller = try openWelcome()
        desk.showQuickSwitcher()

        desk.toggleQuickSwitcher()

        XCTAssertEqual(checked(controller), [], "closing the switcher was counted")
        desk.toggleQuickSwitcher()
        XCTAssertEqual(checked(controller), [.findNote])
    }

    func testShowingALabelAgainDoesNotTickTheBoxButHidingDoes() throws {
        let controller = try openWelcome()
        isolated.settings.hiddenLabels = ["work"]

        desk.toggleLabelVisibility("work")
        XCTAssertEqual(checked(controller), [])

        desk.toggleLabelVisibility("work")
        XCTAssertEqual(checked(controller), [.hideLabel])
    }

    func testABoxThePersonTickedAloneStaysTickedWhenTheirEventHappens() throws {
        let controller = try openWelcome()
        let task = try XCTUnwrap(WelcomeNote.taskLine(for: .newNote, in: controller.textView.string))
        controller.replaceBody(range: task.box, with: "x")

        desk.newNote()

        XCTAssertEqual(checked(controller), [.newNote])
    }

    func testANoteWhoseLineWasEditedAwayJustMissesThatTick() throws {
        let controller = try openWelcome()
        let task = try XCTUnwrap(WelcomeNote.taskLine(for: .findNote, in: controller.textView.string))
        controller.replaceBody(range: NSRange(location: task.line.location, length: task.line.length + 1), with: "")

        desk.toggleQuickSwitcher()
        try perform(.collapse)

        XCTAssertEqual(checked(controller), [.collapse])
    }

    func testTheTaskIsFoundWhateverChordTheNoteNames() throws {
        let text = WelcomeNote.bodyText(newNote: "⌃⌥N", find: "⌃⌥F")
        for step in WelcomeNote.Step.allCases {
            XCTAssertEqual(WelcomeNote.taskLine(for: step, in: text)?.isChecked, false, "\(step)")
        }
    }

    // MARK: - Done

    private func finishAll() throws {
        for step in WelcomeNote.Step.allCases { try perform(step) }
    }

    func testWhenAllFourAreCheckedTheNoteOffersToGoAwayWithOneLineAndStops() throws {
        let controller = try openWelcome()
        XCTAssertTrue(desk.welcome.isListening)

        try finishAll()

        let text = controller.textView.string
        XCTAssertTrue(WelcomeNote.allTasksChecked(in: text))
        XCTAssertEqual(text.components(separatedBy: WelcomeNote.doneLine).count - 1, 1)
        let lines = text.components(separatedBy: "\n")
        let done = try XCTUnwrap(lines.firstIndex(of: WelcomeNote.doneLine))
        XCTAssertTrue(lines[done - 1].isEmpty && lines[done - 2].contains("[x]"), "the line is not under the tasks")
        XCTAssertFalse(desk.welcome.isListening)
        XCTAssertNil(defaults.string(forKey: WelcomeNote.noteIDKey))

        scheduler.advance(by: NoteDocument.debounce)
        XCTAssertEqual(try onDisk().content, text)
    }

    func testOnceDoneNothingIsChangedAgain() throws {
        let controller = try openWelcome()
        try finishAll()
        let task = try XCTUnwrap(WelcomeNote.taskLine(for: .newNote, in: controller.textView.string))
        controller.replaceBody(range: task.box, with: " ")
        let before = controller.textView.string

        try perform(.newNote)
        try perform(.collapse)
        try perform(.hideLabel)

        XCTAssertEqual(controller.textView.string, before)
    }

    func testTheOfferIsMadeOnceEvenIfTheLastEventComesTwice() throws {
        let controller = try openWelcome()
        try finishAll()
        desk.toggleLabelVisibility("work")
        XCTAssertEqual(controller.textView.string.components(separatedBy: WelcomeNote.doneLine).count - 1, 1)
    }

    // MARK: - The note is gone, or never was

    func testAnArchivedWelcomeNoteIsNotBroughtBackOrTicked() throws {
        let controller = try openWelcome()
        controller.closeNote()
        let archivedBefore = store.loadArchived().map(\.id)

        desk.newNote()

        XCTAssertFalse(desk.welcome.isListening)
        XCTAssertNil(defaults.string(forKey: WelcomeNote.noteIDKey))
        XCTAssertNil(store.loadNote(id: welcomeID), "the welcome note came back")
        XCTAssertEqual(store.loadArchived().map(\.id), archivedBefore)
        XCTAssertEqual(try XCTUnwrap(store.loadArchived().first).content, WelcomeNote.body, "the archived note was edited")
    }

    func testADeletedWelcomeNoteIsNotRecreatedByTheChecklist() throws {
        try openWelcome()
        let id = welcomeID!
        store.discardActive(try XCTUnwrap(store.loadNote(id: id)))
        desk.reconcileOpenWindows()
        XCTAssertNil(desk.windowControllers[id])

        try perform(.hideLabel)
        try perform(.findNote)

        XCTAssertFalse(desk.welcome.isListening)
        XCTAssertFalse(store.loadActive().contains { $0.id == id })
        XCTAssertFalse(store.loadActive().contains { $0.title == "Welcome" })
    }

    func testNothingHappensOnAnInstallThatNeverHadAWelcomeNote() throws {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200), now: clock.now())
        note.content = "- [ ] Press this to make a new note"
        store.save(note)
        desk.presentWindow(for: note)

        desk.newNote()
        desk.toggleLabelVisibility("work")

        XCTAssertFalse(desk.welcome.isListening)
        XCTAssertEqual(desk.windowControllers[note.id]?.textView.string, "- [ ] Press this to make a new note")
    }

    // MARK: - Beside an outside edit

    func testATickAfterAnOutsideEditKeepsBoth() throws {
        let controller = try openWelcome()
        var outside = try onDisk()
        outside.content += "\nAdded in Obsidian"
        outside.updatedAt = clock.now().addingTimeInterval(5)
        let other = NoteStore(rootURL: root, clock: clock)
        other.save(outside)
        defer { other.stopWatching() }
        controller.handleStoreChange()
        XCTAssertTrue(controller.textView.string.contains("Added in Obsidian"), "the outside edit was not adopted")

        desk.toggleLabelVisibility("work")
        scheduler.advance(by: NoteDocument.debounce)

        let saved = try onDisk().content
        XCTAssertTrue(saved.contains("Added in Obsidian"))
        XCTAssertTrue(saved.contains("- [x] Try a `#label`"))
    }

    func testAnOutsideEditThatArrivesAfterATickIsMergedWithIt() throws {
        let controller = try openWelcome()
        let original = try onDisk()
        desk.toggleLabelVisibility("work")
        XCTAssertTrue(controller.noteDocument.hasUnsavedEdits)

        var outside = original
        outside.content += "\nAdded in Obsidian"
        outside.updatedAt = clock.now().addingTimeInterval(5)
        let other = NoteStore(rootURL: root, clock: clock)
        other.save(outside)
        // Obsidian's write is not one of this Mac's.
        WriteLineage.reset()
        defer { other.stopWatching() }
        controller.handleStoreChange()
        scheduler.advance(by: NoteDocument.debounce * 4)

        let saved = try onDisk().content
        XCTAssertTrue(saved.contains("Added in Obsidian"), saved)
        XCTAssertTrue(saved.contains("- [x] Try a `#label`"), saved)
    }

    func testAnOutsideEditHeldBackWhileTypingIsFoldedInBeforeATickSoThereIsOneCopy() throws {
        let controller = try openWelcome()
        controller.noteDocument.isEditing = { true }
        var outside = try onDisk()
        outside.content = outside.content.replacingOccurrences(
            of: "This is a real note — edit it, or throw it away.", with: "Rewritten in Obsidian."
        )
        outside.updatedAt = clock.now().addingTimeInterval(5)
        let other = NoteStore(rootURL: root, clock: clock)
        other.save(outside)
        defer { other.stopWatching() }
        controller.handleStoreChange()
        XCTAssertNotNil(controller.noteDocument.pendingExternal, "the outside edit was not held back")

        desk.toggleLabelVisibility("work")
        scheduler.advance(by: NoteDocument.debounce * 4)

        let saved = try onDisk().content
        XCTAssertEqual(saved.components(separatedBy: "make a new note").count - 1, 1, saved)
        XCTAssertTrue(saved.contains("Rewritten in Obsidian."), saved)
        XCTAssertFalse(saved.contains("This is a real note — edit it"), saved)
        XCTAssertTrue(saved.contains("- [x] Try a `#label`"), saved)
        XCTAssertFalse(saved.localizedCaseInsensitiveContains("conflict"), saved)
        XCTAssertEqual(controller.textView.string, saved)
    }

    func testCollapsingFoldsInAnOutsideEditThatWasHeldBack() throws {
        let controller = try openWelcome()
        controller.noteDocument.isEditing = { true }
        var outside = try onDisk()
        outside.content += "\nAdded in Obsidian"
        outside.updatedAt = clock.now().addingTimeInterval(5)
        let other = NoteStore(rootURL: root, clock: clock)
        other.save(outside)
        defer { other.stopWatching() }
        controller.handleStoreChange()
        XCTAssertNotNil(controller.noteDocument.pendingExternal)

        controller.toggleCollapse()

        XCTAssertNil(controller.noteDocument.pendingExternal)
        XCTAssertTrue(controller.textView.string.contains("Added in Obsidian"))
    }

    func testHidingTheLabelTheWelcomeNoteCarriesStillTicksAndSavesItsBox() throws {
        var note = try XCTUnwrap(WelcomeNote.makeIfNeeded(store: store, defaults: defaults, now: clock.now()))
        note.labels = ["work"]
        store.save(note)
        welcomeID = note.id
        desk.presentWindow(for: note)
        let controller = try XCTUnwrap(desk.windowControllers[note.id])
        XCTAssertTrue(controller.window?.isVisible == true)

        desk.toggleLabelVisibility("work")

        XCTAssertFalse(controller.window?.isVisible == true, "the label did not hide the note")
        XCTAssertEqual(checked(controller), [.hideLabel])
        scheduler.advance(by: NoteDocument.debounce)
        XCTAssertTrue(try onDisk().content.contains("- [x] Try a `#label`"))
        XCTAssertEqual(try onDisk().labels, ["work"])
    }

    func testATickNextToTheCaretOpensNoLabelList() throws {
        let controller = try openWelcome()
        controller.editor.labelProvider = { ["work"] }
        controller.editor.replaceText("#wo\n" + controller.textView.string)
        controller.textView.setSelectedRange(NSRange(location: 3, length: 0))
        controller.editor.textDidChange(Notification(name: NSText.didChangeNotification, object: controller.textView))
        XCTAssertTrue(controller.editor.isShowingLabelCompletion, "typing #wo should open the list; the test proves nothing otherwise")
        controller.editor.dismissLabelCompletion()

        desk.toggleLabelVisibility("work")

        XCTAssertEqual(checked(controller), [.hideLabel])
        XCTAssertFalse(controller.editor.isShowingLabelCompletion)
    }

    func testTheTickIsItsOwnUndoStepApartFromTyping() throws {
        let controller = try openWelcome()
        let undoManager = try XCTUnwrap(controller.textView.undoManager)
        controller.textView.insertText("typed ", replacementRange: NSRange(location: 0, length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))

        desk.toggleLabelVisibility("work")
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(checked(controller), [.hideLabel])

        undoManager.undo()

        XCTAssertEqual(checked(controller), [], "undo did not take the tick back")
        XCTAssertTrue(controller.textView.string.hasPrefix("typed "), "undo took the typing with it")
    }

    // MARK: - Helpers

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }
}
