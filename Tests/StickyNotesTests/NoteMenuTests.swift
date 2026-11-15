import AppKit
import KeyboardShortcuts
import XCTest
@testable import StickyNotesKit

/// The Note menu over a real note window. A window cannot become key inside the
/// test host, so the menu is given the note to act on, the way `MenuBarController`
/// gives it the desk's key note.
@MainActor final class NoteMenuTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var layout: DeviceLayoutStore!
    private var keyNote: NoteWindowController?
    private var noteMenu: NoteMenu!
    private var menu: NSMenu!
    private var savedMainMenu: NSMenu?
    private var controllers: [NoteWindowController] = []
    private var archived: [Note] = []
    private var canCycle = false
    private var cycled: [Int] = []
    private var currentEvent: NSEvent?

    override func setUp() async throws {
        _ = NSApplication.shared
        savedMainMenu = NSApp.mainMenu
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteMenu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(rootURL: root)
        layout = DeviceLayoutStore(url: root.appendingPathComponent("layout.json"))
        noteMenu = NoteMenu(
            keyNote: { [unowned self] in keyNote },
            canCycle: { [unowned self] in canCycle },
            cycle: { [unowned self] in cycled.append($0) },
            currentEvent: { [unowned self] in currentEvent }
        )
        menu = noteMenu.makeMenu()
        let top = NSMenu()
        let item = NSMenuItem()
        item.submenu = menu
        top.addItem(item)
        NSApp.mainMenu = top
    }

    override func tearDown() async throws {
        store?.stopWatching()
        controllers.forEach { $0.window?.close() }
        NSApp.mainMenu = savedMainMenu
        try? FileManager.default.removeItem(at: root)
    }

    private func openNote(title: String = "Note", content: String = "body") -> NoteWindowController {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
        note.title = title
        note.content = content
        store.save(note)
        let controller = NoteWindowController(note: note, store: store, layout: layout, onClosed: { _ in })
        controller.onArchived = { [unowned self] in archived.append($0) }
        controllers.append(controller)
        return controller
    }

    private func item(_ title: String) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.title == title }, "no Note menu item titled \(title)")
    }

    private func perform(_ title: String) throws {
        let target = try item(title)
        menu.update()
        XCTAssertTrue(target.isEnabled, "\(title) is disabled")
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex(of: target)))
    }

    private func keyEvent(
        _ key: String, _ modifiers: NSEvent.ModifierFlags, in window: NSWindow, repeating: Bool = false,
        keyCode: UInt16 = 0
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: key, charactersIgnoringModifiers: key, isARepeat: repeating, keyCode: keyCode
        ))
    }

    // MARK: - Items

    func testTheMenuListsTheStickiesShortcuts() throws {
        let expected: [(String, String, NSEvent.ModifierFlags)] = [
            ("Find in Note", "f", .command),
            ("Labels…", "l", [.command, .option]),
            ("Yellow", "1", .command), ("Pink", "2", .command), ("Orange", "3", .command),
            ("Green", "4", .command), ("Blue", "5", .command), ("Purple", "6", .command),
            ("Gray", "7", .command),
            ("Float on Top", "f", [.command, .option]),
            ("Collapse", "m", .command),
            ("Archive", "w", .command),
            ("Next Note", "`", .command),
            ("Previous Note", "~", [.command, .shift])
        ]
        for (title, key, modifiers) in expected {
            let found = try item(title)
            XCTAssertEqual(found.keyEquivalent, key, title)
            XCTAssertEqual(found.keyEquivalentModifierMask, modifiers, title)
            XCTAssertTrue(found.target === noteMenu, "\(title) does not name the Note menu as its target")
            XCTAssertNotNil(found.action, title)
        }
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.count, expected.count)
    }

    func testTheColourItemsFollowTheColourMenuOrder() {
        let titles = menu.items.filter { $0.image != nil }.map(\.title)
        XCTAssertEqual(titles, NoteColor.allCases.map(\.displayName))
    }

    // MARK: - Validation

    func testEveryItemIsDisabledWhenNoNoteIsKey() {
        keyNote = nil
        menu.update()
        for item in menu.items where !item.isSeparatorItem {
            XCTAssertFalse(item.isEnabled, "\(item.title) is enabled with no key note")
            XCTAssertEqual(item.state, .off, item.title)
        }
    }

    func testItemsAreEnabledForAKeyNoteAndCheckTheCurrentColourFloatLevelAndCollapse() throws {
        let controller = openNote()
        keyNote = controller
        canCycle = true
        menu.update()
        for item in menu.items where !item.isSeparatorItem {
            XCTAssertTrue(item.isEnabled, "\(item.title) is disabled for a key note")
        }
        XCTAssertEqual(try item("Yellow").state, .on)
        XCTAssertEqual(try item("Pink").state, .off)
        XCTAssertEqual(try item("Float on Top").state, .on)
        XCTAssertEqual(try item("Collapse").state, .off)

        controller.setColor(.green)
        controller.setFloatLevel(.desktop)
        controller.toggleCollapse()
        menu.update()

        XCTAssertEqual(try item("Yellow").state, .off)
        XCTAssertEqual(try item("Green").state, .on)
        XCTAssertEqual(try item("Float on Top").state, .off)
        XCTAssertEqual(try item("Collapse").state, .on)
    }

    func testACollapsedNoteHasNoBodyToFindInOrLabel() throws {
        let controller = openNote()
        keyNote = controller
        controller.toggleCollapse()
        menu.update()

        XCTAssertFalse(try item("Find in Note").isEnabled)
        XCTAssertFalse(try item("Labels…").isEnabled)
        XCTAssertTrue(try item("Collapse").isEnabled, "a collapsed note could not be expanded from the keyboard")
        XCTAssertTrue(try item("Archive").isEnabled)
    }

    // MARK: - Actions

    func testAColourItemChangesTheKeyNoteAndWritesItToTheFile() throws {
        let controller = openNote()
        keyNote = controller

        try perform("Blue")

        XCTAssertEqual(controller.color, .blue)
        XCTAssertTrue(controller.flushPendingSave())
        XCTAssertEqual(try XCTUnwrap(store.loadNote(id: controller.noteId)).color, .blue)
    }

    func testTheColourItemsActOnTheKeyNoteOnly() throws {
        let first = openNote(title: "First")
        let second = openNote(title: "Second")
        keyNote = second

        try perform("Purple")

        XCTAssertEqual(second.color, .purple)
        XCTAssertEqual(first.color, .yellow)
    }

    func testCollapseWritesTheLayoutAndLeavesTheNoteFileAlone() throws {
        let controller = openNote()
        keyNote = controller
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: store.activeURL, includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "md" })
        let before = try Data(contentsOf: file)

        try perform("Collapse")

        XCTAssertTrue(controller.isCollapsed)
        XCTAssertEqual(layout.layout(for: controller.noteId)?.collapsed, true)
        XCTAssertEqual(try XCTUnwrap(controller.window).frame.height, NoteWindowController.collapsedHeight)
        XCTAssertTrue(controller.flushPendingSave())
        XCTAssertEqual(try Data(contentsOf: file), before, "collapsing rewrote the note's file")

        try perform("Collapse")
        XCTAssertFalse(controller.isCollapsed)
        XCTAssertEqual(layout.layout(for: controller.noteId)?.collapsed, false)
    }

    func testArchiveGoesThroughTheClosePathAndKeepsLateText() throws {
        let controller = openNote(content: "first draft")
        keyNote = controller
        controller.textView.string = "first draft plus a late thought"
        controller.editor.textDidChange(Notification(name: NSText.didChangeNotification, object: controller.textView))

        try perform("Archive")

        XCTAssertEqual(archived.map(\.content), ["first draft plus a late thought"])
        XCTAssertEqual(try XCTUnwrap(store.loadArchived().first).content, "first draft plus a late thought")
        XCTAssertNil(store.loadNote(id: controller.noteId), "the note is still active")
    }

    func testFloatOnTopTogglesTheLevelAndTheWindow() throws {
        let controller = openNote()
        keyNote = controller
        XCTAssertEqual(try XCTUnwrap(controller.window).level, .floating)

        try perform("Float on Top")
        XCTAssertEqual(controller.floatLevel, .desktop)
        XCTAssertNotEqual(try XCTUnwrap(controller.window).level, .floating)

        try perform("Float on Top")
        XCTAssertEqual(controller.floatLevel, .floating)
        XCTAssertEqual(try XCTUnwrap(controller.window).level, .floating)
        XCTAssertTrue(controller.flushPendingSave())
        XCTAssertEqual(try XCTUnwrap(store.loadNote(id: controller.noteId)).floatLevel, .floating)
    }

    func testFindShowsTheFindBarOverTheBody() throws {
        let controller = openNote()
        keyNote = controller
        let scroll = try XCTUnwrap(controller.textView.enclosingScrollView)
        XCTAssertTrue(controller.textView.usesFindBar)
        XCTAssertFalse(scroll.isFindBarVisible)

        try perform("Find in Note")

        XCTAssertTrue(scroll.isFindBarVisible)

        // Set `SNAPSHOT_DIR` to also write a PNG of the note with its find bar.
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"],
           let view = controller.window?.contentView {
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("note-find-bar.png"))
            }
        }
    }

    func testTheDailyNoteEditorHasNoFindBar() {
        let editor = MarkdownEditorController(store: store, clock: ManualClock(), options: .daily)
        XCTAssertFalse(editor.textView.usesFindBar)
    }

    // MARK: - The key path

    func testAShortcutPressedInANoteWindowReachesTheMenu() throws {
        let controller = openNote()
        keyNote = controller
        let window = try XCTUnwrap(controller.window)

        XCTAssertTrue(window.performKeyEquivalent(with: try keyEvent("2", .command, in: window)))
        XCTAssertEqual(controller.color, .pink)

        XCTAssertTrue(window.performKeyEquivalent(with: try keyEvent("m", .command, in: window)))
        XCTAssertTrue(controller.isCollapsed)

        XCTAssertTrue(window.performKeyEquivalent(with: try keyEvent("f", [.command, .option], in: window)))
        XCTAssertEqual(controller.floatLevel, .desktop)
    }

    /// A matching item that is disabled still takes the key, so the window
    /// reports it handled; what matters is that nothing happened. A chord no
    /// item uses is left unhandled.
    func testAShortcutDoesNothingWhenNoNoteIsKey() throws {
        let controller = openNote()
        keyNote = nil
        let window = try XCTUnwrap(controller.window)

        XCTAssertTrue(window.performKeyEquivalent(with: try keyEvent("4", .command, in: window)))
        XCTAssertTrue(window.performKeyEquivalent(with: try keyEvent("w", .command, in: window)))
        XCTAssertTrue(window.performKeyEquivalent(with: try keyEvent("m", .command, in: window)))
        XCTAssertFalse(window.performKeyEquivalent(with: try keyEvent("9", .command, in: window)),
                       "a chord no item uses was reported handled")

        XCTAssertEqual(controller.color, .yellow)
        XCTAssertFalse(controller.isCollapsed)
        XCTAssertTrue(archived.isEmpty)
        XCTAssertNotNil(store.loadNote(id: controller.noteId))
    }

    // MARK: - Next and Previous Note

    func testNextAndPreviousNoteAreDisabledUntilThereIsSomewhereToGo() throws {
        keyNote = openNote()
        canCycle = false
        menu.update()
        XCTAssertFalse(try item("Next Note").isEnabled)
        XCTAssertFalse(try item("Previous Note").isEnabled)

        canCycle = true
        menu.update()
        XCTAssertTrue(try item("Next Note").isEnabled)
        XCTAssertTrue(try item("Previous Note").isEnabled)
    }

    func testNextAndPreviousNoteStayEnabledWhenOnlyTheDailyNoteIsKey() throws {
        keyNote = nil
        canCycle = true
        menu.update()
        XCTAssertTrue(try item("Next Note").isEnabled, "the daily note could not be left from the keyboard")
        XCTAssertFalse(try item("Archive").isEnabled)
    }

    func testNextAndPreviousNoteAskTheDeskToCycle() throws {
        canCycle = true
        try perform("Next Note")
        try perform("Previous Note")
        XCTAssertEqual(cycled, [1, -1])
    }

    func testShiftCommandBacktickAsTheKeyboardSendsItGoesToThePreviousNote() throws {
        canCycle = true
        menu.update()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let event = try keyEvent("~", [.command, .shift], in: window, keyCode: 50)

        XCTAssertTrue(menu.performKeyEquivalent(with: event))

        XCTAssertEqual(cycled, [-1])
    }

    func testTheDeskCyclesOldestNoteFirstSkippingHiddenOnesAndWrapping() throws {
        let isolated = IsolatedSettings()
        defer { isolated.tearDown() }
        let clock = ManualClock()
        let desk = DeskController(
            store: store, settings: isolated.settings, clock: clock, undo: UndoCenter(clock: clock),
            recovery: RecoveryFiles(settings: isolated.settings, store: store, clock: clock)
        )
        defer { desk.windowControllers.values.forEach { $0.window?.close() } }
        var ids: [UUID] = []
        for title in ["One", "Two", "Three"] {
            clock.advance(by: 60)
            desk.makeNote(title: title)
            ids.append(try XCTUnwrap(desk.windowControllers.values.first { $0.bufferedNote.title == title }).noteId)
        }
        let windows = ids.map { desk.windowControllers[$0]!.window! }

        XCTAssertEqual(desk.cyclableWindows(), windows, "not oldest first")
        XCTAssertTrue(desk.cycleTarget(by: 1, from: windows[0]) === windows[1])
        XCTAssertTrue(desk.cycleTarget(by: 1, from: windows[2]) === windows[0], "did not wrap forward")
        XCTAssertTrue(desk.cycleTarget(by: -1, from: windows[0]) === windows[2], "did not wrap back")

        windows[1].orderOut(nil)
        XCTAssertEqual(desk.cyclableWindows(), [windows[0], windows[2]])
        XCTAssertTrue(desk.cycleTarget(by: 1, from: windows[0]) === windows[2], "went to a hidden note")

        windows[2].orderOut(nil)
        XCTAssertNil(desk.cycleTarget(by: 1, from: windows[0]), "one visible note has nowhere to go")

        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        XCTAssertTrue(desk.cycleTarget(by: 1, from: other) === windows[0], "from the panel or Settings, go to the first note")
        XCTAssertTrue(desk.cycleTarget(by: -1, from: other) === windows[0])
        windows[0].orderOut(nil)
        XCTAssertNil(desk.cycleTarget(by: 1, from: other), "no visible note to go to")
        XCTAssertFalse(desk.canCycleNotes)
    }

    func testNextNoteIsAvailableFromAnotherAppWindowThatIsKey() throws {
        let isolated = IsolatedSettings()
        defer { isolated.tearDown() }
        let clock = ManualClock()
        let desk = DeskController(
            store: store, settings: isolated.settings, clock: clock, undo: UndoCenter(clock: clock),
            recovery: RecoveryFiles(settings: isolated.settings, store: store, clock: clock)
        )
        defer { desk.windowControllers.values.forEach { $0.window?.close() } }
        desk.makeNote(title: "Only")
        let note = try XCTUnwrap(desk.windowControllers.values.first?.window)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        other.makeKeyAndOrderFront(nil)
        try XCTSkipUnless(other.isKeyWindow, "this host does not give windows key status")

        XCTAssertTrue(desk.canCycleNotes)
        desk.cycleNotes(by: 1)
        XCTAssertTrue(note.isKeyWindow, "Next Note from another window did not reach the note")
    }

    // MARK: - Key repeat

    func testAHeldKeyDoesNotRepeatArchiveCollapseOrFloat() throws {
        let controller = openNote()
        keyNote = controller
        let window = try XCTUnwrap(controller.window)
        currentEvent = try keyEvent("m", .command, in: window, repeating: true)

        try perform("Collapse")
        try perform("Float on Top")
        try perform("Archive")

        XCTAssertFalse(controller.isCollapsed)
        XCTAssertEqual(controller.floatLevel, .floating)
        XCTAssertTrue(archived.isEmpty)
        XCTAssertNotNil(store.loadNote(id: controller.noteId))

        currentEvent = try keyEvent("m", .command, in: window)
        try perform("Collapse")
        XCTAssertTrue(controller.isCollapsed, "the first press was ignored")
    }

    func testAMouseEventRunningAnActionIsNotMistakenForARepeat() throws {
        let controller = openNote()
        keyNote = controller
        currentEvent = NSEvent.mouseEvent(
            with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        )

        try perform("Collapse")

        XCTAssertTrue(controller.isCollapsed)
    }

    // MARK: - Unchanged values

    func testPickingTheCurrentColourOrFloatLevelEditsNothing() throws {
        let controller = openNote()
        keyNote = controller
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: store.activeURL, includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "md" })
        let before = try Data(contentsOf: file)

        try perform("Yellow")
        try perform("Float on Top")
        try perform("Float on Top")

        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(controller.floatLevel, .floating)
    }

    func testPickingTheCurrentColourOfANoteWithNoFileMakesNoFile() throws {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
        note.color = .pink
        let controller = NoteWindowController(note: note, store: store, layout: layout, onClosed: { _ in })
        controllers.append(controller)
        keyNote = controller

        controller.setColor(.pink)
        controller.setFloatLevel(.floating)

        XCTAssertFalse(controller.hasFile, "an unchanged pick made a file")
        XCTAssertTrue(controller.isAbandonedCapture)
    }

    // MARK: - Collapse and focus

    func testCollapsingTakesFocusOutOfTheHiddenBodyAndExpandingGivesItBack() throws {
        let controller = openNote(content: "kept")
        keyNote = controller
        let window = try XCTUnwrap(controller.window)
        window.makeFirstResponder(controller.textView)
        XCTAssertTrue(window.firstResponder === controller.textView)

        try perform("Collapse")

        XCTAssertFalse(window.firstResponder === controller.textView, "focus stayed in the hidden body")
        let responder = try XCTUnwrap(window.firstResponder)
        _ = responder.tryToPerform(NSSelectorFromString("insertText:"), with: "typed")
        _ = responder.tryToPerform(NSSelectorFromString("paste:"), with: nil)
        XCTAssertFalse(responder is NSTextView, "first responder is \(responder)")
        XCTAssertEqual(controller.textView.string, "kept")
        XCTAssertEqual(controller.bufferedNote.content, "kept")

        try perform("Collapse")
        XCTAssertTrue(window.firstResponder === controller.textView, "expanding did not refocus the text")
    }

    func testCollapsingCommitsATitleEditAndLeavesFocusOutOfTheTitle() throws {
        let controller = openNote()
        keyNote = controller
        let window = try XCTUnwrap(controller.window)
        window.makeFirstResponder(controller.titleField)
        let editor = try XCTUnwrap(controller.titleField.currentEditor())
        editor.string = "Typed title"
        NotificationCenter.default.post(
            Notification(name: NSControl.textDidChangeNotification, object: controller.titleField))

        try perform("Collapse")

        XCTAssertNil(controller.titleField.currentEditor())
        XCTAssertEqual(controller.bufferedNote.title, "Typed title", "the typed title was lost")
        XCTAssertTrue(controller.flushPendingSave())
        XCTAssertEqual(store.loadNote(id: controller.noteId)?.title, "Typed title", "the typed title was not saved")
    }

    // MARK: - The editor's chords belong to the editor

    func testTheEditorChordsDoNothingToTheBodyWhenAnotherViewHasFocus() throws {
        let controller = openNote(content: "word")
        keyNote = controller
        let window = try XCTUnwrap(controller.window)
        window.makeFirstResponder(controller.titleField)
        controller.textView.setSelectedRange(NSRange(location: 0, length: 4))

        for key in ["b", "i", "e"] {
            _ = controller.textView.performKeyEquivalent(with: try keyEvent(key, .command, in: window))
        }
        _ = controller.textView.performKeyEquivalent(with: try keyEvent("\r", .command, in: window, keyCode: 36))

        XCTAssertEqual(controller.textView.string, "word")
    }

    func testTheEditorsOwnChordsStillWrapTheSelection() throws {
        let controller = openNote(content: "word")
        keyNote = controller
        let window = try XCTUnwrap(controller.window)
        window.makeFirstResponder(controller.textView)
        controller.textView.setSelectedRange(NSRange(location: 0, length: 4))

        XCTAssertTrue(window.performKeyEquivalent(with: try keyEvent("b", .command, in: window)))

        XCTAssertEqual(controller.textView.string, "**word**")
    }
}
