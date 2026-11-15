import AppKit
import KeyboardShortcuts
import XCTest
@testable import StickyNotesKit

/// The menus, built over a temp store and a throwaway settings suite. The
/// status item is real, so these tests remove it when they finish.
@MainActor final class MenuBarControllerTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var isolated: IsolatedSettings!
    private var clock: ManualClock!
    private var desk: DeskController!
    private var menuBar: MenuBarController!
    private var savedMainMenu: NSMenu?

    override func setUp() async throws {
        _ = NSApplication.shared
        savedMainMenu = NSApp.mainMenu
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuBar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(rootURL: root)
        isolated = IsolatedSettings()
        clock = ManualClock()
        let undo = UndoCenter(clock: clock)
        desk = DeskController(
            store: store,
            settings: isolated.settings,
            clock: clock,
            undo: undo,
            recovery: RecoveryFiles(settings: isolated.settings, store: store, clock: clock)
        )
        menuBar = MenuBarController(
            store: store,
            settings: isolated.settings,
            desk: desk,
            capture: CaptureCoordinator(desk: desk, store: store),
            storage: StorageCoordinator(store: store, settings: isolated.settings, desk: desk),
            undo: undo
        )
        menuBar.install()
    }

    override func tearDown() async throws {
        desk.windowControllers.values.forEach { $0.window?.close() }
        menuBar = nil
        NSApp.mainMenu = savedMainMenu
        isolated.tearDown()
        try? FileManager.default.removeItem(at: root)
    }

    private func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems(in:)) ?? []) }
    }

    private func item(titled title: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(allItems(in: menu).first { $0.title == title }, "no menu item titled \(title)")
    }

    /// Without a target an action goes up the responder chain, which no longer
    /// ends at an object that implements ours. Only the standard editing
    /// actions, which text views answer, may go without.
    func testEveryItemThatIsOursNamesItsTarget() throws {
        let standard: Set<String> = ["terminate:", "redo:", "cut:", "copy:", "paste:", "pasteAsPlainText:", "selectAll:"]
        let menus = [try XCTUnwrap(NSApp.mainMenu), try XCTUnwrap(menuBar.statusMenu)]

        for menu in menus {
            for item in allItems(in: menu) {
                guard let action = item.action else { continue }
                if item.target == nil {
                    XCTAssertTrue(standard.contains(NSStringFromSelector(action)),
                                  "\(item.title) sends \(action) to the responder chain")
                }
            }
        }
    }

    func testTheMainMenuHasANoteMenuThatActsOnTheKeyNote() throws {
        let note = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.submenu?.title == "Note" }?.submenu)
        XCTAssertEqual(note.items.first { $0.title == "Archive" }?.keyEquivalent, "w")

        // No window is key here, so the menu has nothing to act on.
        note.update()
        XCTAssertTrue(note.items.filter { !$0.isSeparatorItem }.allSatisfy { !$0.isEnabled })
    }

    /// A shortcut used twice in the main menu would only ever run the first, and
    /// one that a global hotkey or the text editor also answers would run twice
    /// or never.
    func testNoShortcutIsUsedTwiceOrCollidesWithAGlobalHotkeyOrTheEditor() throws {
        func chord(_ item: NSMenuItem) -> String {
            "\(item.keyEquivalent.lowercased())+\(item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask).rawValue)"
        }
        let chorded = allItems(in: try XCTUnwrap(NSApp.mainMenu)).filter { !$0.keyEquivalent.isEmpty }
        let chords = chorded.map(chord)
        XCTAssertEqual(Set(chords).count, chords.count,
                       "duplicate chords: \(chorded.map { "\($0.title) \(chord($0))" })")

        let globals: [KeyboardShortcuts.Name] = [.newNote, .notesPanel, .hideAll, .quickSwitcher, .newFromClipboard]
        for name in globals {
            let probe = NSMenuItem()
            probe.setShortcut(for: name)
            XCTAssertFalse(chords.contains(chord(probe)), "a menu item uses the global chord \(chord(probe))")
        }

        let editor = ["b", "i", "e", "\r"].map { "\($0)+\(NSEvent.ModifierFlags.command.rawValue)" }
        XCTAssertTrue(Set(chords).isDisjoint(with: editor), "a menu item takes a chord the note editor answers")
    }

    func testTheStatusMenuHasTheCaptureAndManagementRows() throws {
        let menu = try XCTUnwrap(menuBar.statusMenu)
        for title in ["New Note", "New from Clipboard", "Find Note…", "Today's Daily Note", "Notes",
                      "All Notes…", "Hide All Notes", "Show Labels", "Arrange", "Grid", "Cascade",
                      "Show Storage Folder", "Quit"] {
            _ = try item(titled: title, in: menu)
        }
    }

    func testOpeningTheMenuReflectsWhetherNotesAreHiddenAndWhetherAnyExist() throws {
        let menu = try XCTUnwrap(menuBar.statusMenu)
        let hideAll = try item(titled: "Hide All Notes", in: menu)

        menuBar.menuWillOpen(menu)
        defer { menuBar.menuDidClose(menu) }
        XCTAssertFalse(hideAll.isEnabled, "hide-all is offered with nothing on the desk")

        desk.makeNote(title: "One")
        menuBar.menuWillOpen(menu)
        XCTAssertTrue(hideAll.isEnabled)

        desk.toggleHideAll()
        menuBar.menuWillOpen(menu)
        XCTAssertEqual(hideAll.title, "Show All Notes")
    }

    func testTheDailyNoteRowShowsOnlyWithAVaultAndAPattern() throws {
        let menu = try XCTUnwrap(menuBar.statusMenu)
        let daily = try item(titled: "Today's Daily Note", in: menu)
        defer { menuBar.menuDidClose(menu) }

        menuBar.menuWillOpen(menu)
        XCTAssertTrue(daily.isHidden)

        isolated.settings.obsidianVaultPath = root.path
        isolated.settings.dailyNotesPattern = "{YYYY}-{MM}-{DD}.md"
        menuBar.menuWillOpen(menu)
        XCTAssertFalse(daily.isHidden)
        XCTAssertEqual(daily.title, "Show Today's Daily Note")
    }

    func testTheLabelSubmenuListsKnownLabelsAndMarksHiddenOnes() throws {
        var note = Note.makeNew(frame: .zero, now: clock.now())
        note.labels = ["work", "home"]
        store.save(note)
        isolated.settings.hiddenLabels = ["home"]
        let menu = try XCTUnwrap(menuBar.statusMenu)
        menuBar.menuWillOpen(menu)
        defer { menuBar.menuDidClose(menu) }

        let labels = try item(titled: "Show Labels  (1 hidden)", in: menu)
        let entries = try XCTUnwrap(labels.submenu).items
        XCTAssertEqual(entries.first { $0.title == "#work" }?.state, .on)
        XCTAssertEqual(entries.first { $0.title == "#home" }?.state, .off)
        XCTAssertTrue(entries.contains { $0.title == "Show All Labels" })
    }
}
