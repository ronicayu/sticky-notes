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

    override func setUp() async throws {
        _ = NSApplication.shared
        savedMainMenu = NSApp.mainMenu
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteMenu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(rootURL: root)
        layout = DeviceLayoutStore(url: root.appendingPathComponent("layout.json"))
        noteMenu = NoteMenu(keyNote: { [unowned self] in keyNote })
        menu = noteMenu.makeMenu()
        let top = NSMenu()
        let item = NSMenuItem()
        item.submenu = menu
        top.addItem(item)
        NSApp.mainMenu = top
    }

    override func tearDown() async throws {
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

    private func keyEvent(_ key: String, _ modifiers: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
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
            ("Archive", "w", .command)
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

    func testAShortcutDoesNothingWhenNoNoteIsKey() throws {
        let controller = openNote()
        keyNote = nil
        let window = try XCTUnwrap(controller.window)

        _ = window.performKeyEquivalent(with: try keyEvent("4", .command, in: window))
        _ = window.performKeyEquivalent(with: try keyEvent("w", .command, in: window))
        _ = window.performKeyEquivalent(with: try keyEvent("m", .command, in: window))

        XCTAssertEqual(controller.color, .yellow)
        XCTAssertFalse(controller.isCollapsed)
        XCTAssertTrue(archived.isEmpty)
        XCTAssertNotNil(store.loadNote(id: controller.noteId))
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
