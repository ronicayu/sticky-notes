import AppKit
import KeyboardShortcuts

/// The app's menus: the status-bar menu, the hidden main menu that gives text
/// views their standard shortcuts, and the storage warning in the menu bar
/// icon. Every item names its target, so none depends on the responder chain
/// finding the app delegate.
@MainActor final class MenuBarController: NSObject, NSMenuDelegate {
    private let store: NoteStore
    private let settings: Settings
    private let desk: DeskController
    private let capture: CaptureCoordinator
    private let storage: StorageCoordinator
    private let undo: UndoCenter
    /// Holds the Note menu's actions: its items do not retain their target.
    private let noteMenu: NoteMenu

    // `deinit` is not main-actor isolated, and it is the only code that reads
    // this off the actor.
    nonisolated(unsafe) private var statusItem: NSStatusItem!
    private var hideAllItem: NSMenuItem!
    private var dailyNoteItem: NSMenuItem!
    private var storageWarningItem: NSMenuItem!
    private var showLabelsItem: NSMenuItem!

    init(
        store: NoteStore,
        settings: Settings,
        desk: DeskController,
        capture: CaptureCoordinator,
        storage: StorageCoordinator,
        undo: UndoCenter
    ) {
        self.store = store
        self.settings = settings
        self.desk = desk
        self.capture = capture
        self.storage = storage
        self.undo = undo
        self.noteMenu = NoteMenu(
            keyNote: { [weak desk] in desk?.focusedController() },
            canCycle: { [weak desk] in desk?.canCycleNotes ?? false },
            cycle: { [weak desk] step in desk?.cycleNotes(by: step) }
        )
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    /// The icon's place on screen, for a note that fades toward it.
    var iconFrame: NSRect? { statusItem?.button?.window?.frame }

    /// The status-bar menu, once `install()` has built it.
    var statusMenu: NSMenu? { statusItem?.menu }

    func install() {
        installMainMenu()
        setupMenuBar()
    }

    /// Follow the store's health so a failing write shows in the menu bar icon.
    func startObservingStorageHealth() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshStorageHealth),
            name: NoteStore.healthDidChange,
            object: nil
        )
    }

    /// Even though we're an accessory (no Dock icon, no system menu bar),
    /// installing a main menu lets standard key equivalents like ⌘C / ⌘V /
    /// ⌘X / ⌘A / ⌘Z reach the focused text view via `performKeyEquivalent`.
    /// It also gives us a home for ⌘, → Settings and for the Note menu's
    /// keyboard shortcuts.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        add("Settings…", #selector(StorageCoordinator.openSettings), target: storage, key: ",", to: appMenu)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sticky Notes",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        add("Undo", #selector(UndoCenter.undoLastAction(_:)), target: undo, key: "z", to: editMenu)
        let redoItem = editMenu.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: NSSelectorFromString("cut:"), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: NSSelectorFromString("paste:"), keyEquivalent: "v")
        let pastePlainItem = editMenu.addItem(
            withTitle: "Paste and Match Style",
            action: NSSelectorFromString("pasteAsPlainText:"),
            keyEquivalent: "V"
        )
        pastePlainItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let noteMenuItem = NSMenuItem()
        noteMenuItem.submenu = noteMenu.makeMenu()
        mainMenu.addItem(noteMenuItem)

        // Text size follows the platform convention rather than hiding in
        // Settings — it is the shortcut people already know.
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        add("Bigger Text", #selector(DeskController.increaseTextSize), target: desk, key: "+", to: viewMenu)
        add("Smaller Text", #selector(DeskController.decreaseTextSize), target: desk, key: "-", to: viewMenu)
        add("Actual Size", #selector(DeskController.resetTextSize), target: desk, key: "0", to: viewMenu)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, target: AnyObject, key: String = "", to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            applyNormalMenuBarIcon(to: button)
        }

        let menu = NSMenu()
        menu.delegate = self

        let versionItem = NSMenuItem(
            title: "Sticky Notes \(AppVersion.displayString(info: Bundle.main.infoDictionary ?? [:]))",
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        // Hidden unless a write has actually failed; see refreshStorageHealth.
        storageWarningItem = NSMenuItem(title: "",
                                        action: #selector(showStorageFailure),
                                        keyEquivalent: "")
        storageWarningItem.target = self
        storageWarningItem.isHidden = true
        menu.addItem(storageWarningItem)

        menu.addItem(.separator())

        // Capture first — the things you actually do. Everything that
        // manages notes rather than making them goes in one submenu, which
        // keeps the top level at a glanceable seven rows.
        // Titles carry no chord text: the shortcuts are user-rebindable, and
        // `setShortcut(for:)` renders whatever is currently bound and keeps
        // it up to date. Spelling them out left the menu advertising chords
        // that no longer worked.
        showChord(.newNote,
                  on: add("New Note", #selector(DeskController.newNote), target: desk, to: menu))
        showChord(.newFromClipboard,
                  on: add("New from Clipboard", #selector(CaptureCoordinator.newNoteFromClipboard), target: capture, to: menu))
        showChord(.quickSwitcher,
                  on: add("Find Note…", #selector(DeskController.toggleQuickSwitcher), target: desk, to: menu))

        dailyNoteItem = add("Today's Daily Note", #selector(DeskController.toggleDailyNote), target: desk, to: menu)

        menu.addItem(.separator())

        let notesItem = NSMenuItem(title: "Notes", action: nil, keyEquivalent: "")
        let notesMenu = NSMenu(title: "Notes")
        showChord(.notesPanel,
                  on: add("All Notes…", #selector(DeskController.showNotesPanel), target: desk, to: notesMenu))

        hideAllItem = add("Hide All Notes", #selector(DeskController.toggleHideAll), target: desk, to: notesMenu)
        showChord(.hideAll, on: hideAllItem)

        showLabelsItem = NSMenuItem(title: "Show Labels", action: nil, keyEquivalent: "")
        notesMenu.addItem(showLabelsItem)

        let arrangeItem = NSMenuItem(title: "Arrange", action: nil, keyEquivalent: "")
        let arrangeMenu = NSMenu()
        add("Grid", #selector(DeskController.arrangeGrid), target: desk, to: arrangeMenu)
        add("Cascade", #selector(DeskController.arrangeCascade), target: desk, to: arrangeMenu)
        arrangeItem.submenu = arrangeMenu
        notesMenu.addItem(arrangeItem)

        notesItem.submenu = notesMenu
        menu.addItem(notesItem)

        menu.addItem(.separator())
        add("Settings…", #selector(StorageCoordinator.openSettings), target: storage, key: ",", to: menu)
        add("Show Storage Folder", #selector(StorageCoordinator.revealStorage), target: storage, to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
    }

    /// Menu construction runs on the main thread; the library's helper is
    /// main-actor isolated and can't see that from here.
    private func showChord(_ name: KeyboardShortcuts.Name, on item: NSMenuItem) {
        MainActor.assumeIsolated { item.setShortcut(for: name) }
    }

    // MARK: - NSMenuDelegate

    /// Every menu item that shows a chord is also a global hotkey. While a
    /// menu is open AppKit puts the thread in tracking mode, which buffers the
    /// global hotkey and fires it once the menu closes — so the action would
    /// run twice. Suspend them for as long as the menu is up.
    private static let menuShortcuts: [KeyboardShortcuts.Name] =
        [.newNote, .newFromClipboard, .quickSwitcher, .notesPanel, .hideAll]

    func menuDidClose(_ menu: NSMenu) {
        KeyboardShortcuts.enable(MenuBarController.menuShortcuts)
    }

    func menuWillOpen(_ menu: NSMenu) {
        KeyboardShortcuts.disable(MenuBarController.menuShortcuts)
        hideAllItem.title = desk.notesHidden ? "Show All Notes" : "Hide All Notes"
        hideAllItem.isEnabled = desk.hasWindows

        // Rebuilt on open so newly added labels appear without a relaunch.
        showLabelsItem.submenu = makeLabelVisibilityMenu()
        let hiddenCount = settings.hiddenLabels.count
        showLabelsItem.title = hiddenCount == 0 ? "Show Labels" : "Show Labels  (\(hiddenCount) hidden)"

        let canShowDaily = desk.canShowDailyNote
        dailyNoteItem.isHidden = !canShowDaily
        if canShowDaily {
            dailyNoteItem.title = desk.isDailyNoteVisible ? "Hide Today's Daily Note" : "Show Today's Daily Note"
        }
    }

    // MARK: - Labels

    private func makeLabelVisibilityMenu() -> NSMenu {
        let menu = NSMenu(title: "Show Labels")
        let labels = store.allLabels()
        guard !labels.isEmpty else {
            let empty = NSMenuItem(title: "No labels yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        let hidden = settings.hiddenLabels
        for label in labels {
            let item = NSMenuItem(title: "#\(label)",
                                  action: #selector(toggleLabelVisibility(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = label
            item.state = hidden.contains(label) ? .off : .on
            menu.addItem(item)
        }

        if !hidden.isEmpty {
            menu.addItem(.separator())
            let showAll = NSMenuItem(title: "Show All Labels",
                                     action: #selector(showAllLabels),
                                     keyEquivalent: "")
            showAll.target = self
            menu.addItem(showAll)
        }
        return menu
    }

    @objc private func toggleLabelVisibility(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String else { return }
        desk.toggleLabelVisibility(label)
    }

    @objc private func showAllLabels() {
        desk.showAllLabels()
    }

    // MARK: - Storage health

    /// Swap the menu-bar icon for a warning and expose the failing file while
    /// notes aren't reaching disk. A silently failed save looks identical to a
    /// successful one, so this is the only signal the user gets.
    @objc private func refreshStorageHealth() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem?.button else { return }
            if let failure = self.store.lastFailure {
                button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                       accessibilityDescription: "Sticky Notes — can't save")
                button.image?.isTemplate = true
                button.toolTip = failure.menuToolTip
                self.storageWarningItem.title = "⚠︎ " + failure.menuTitle
                self.storageWarningItem.isHidden = false
            } else {
                self.applyNormalMenuBarIcon(to: button)
                button.toolTip = nil
                self.storageWarningItem.isHidden = true
            }
        }
    }

    /// Custom template image renders as the sticky-note silhouette and gets
    /// tinted automatically by the system (light/dark/click).
    private func applyNormalMenuBarIcon(to button: NSStatusBarButton) {
        if let icon = NSImage(named: "MenuBarIcon") {
            icon.isTemplate = true
            button.image = icon
        } else {
            button.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Sticky Notes")
        }
    }

    @objc private func showStorageFailure() {
        guard let failure = store.lastFailure else { return }
        let alert = NSAlert()
        switch failure.kind {
        case .write:
            alert.messageText = "Couldn't save \(failure.fileName)"
            alert.informativeText = """
            \(failure.error.localizedDescription)

            The note is still open and its text is safe — it just isn't on disk \
            yet. Sticky Notes keeps retrying as you edit. Check that the storage \
            folder exists and the disk isn't full.

            Location: \(failure.url.deletingLastPathComponent().path)
            """
        case .migration:
            alert.messageText = "Couldn't convert \(failure.fileName)"
            alert.informativeText = """
            \(failure.error.localizedDescription)

            Sticky Notes now stores notes as Markdown files. This older note file \
            is untouched and its text is safe, but the note will not appear \
            until the file is repaired or removed. Sticky Notes tries again at \
            every launch.

            Location: \(failure.url.deletingLastPathComponent().path)
            """
        case .olderVersion:
            alert.messageText = "Notes from an older version are waiting"
            alert.informativeText = """
            Another Mac that shares this folder is still running an older \
            version of Sticky Notes and has written notes the new version has \
            not converted. Nothing is lost. Update Sticky Notes on your other \
            Macs, then relaunch this one and the notes will appear.

            Location: \(failure.url.deletingLastPathComponent().path)
            """
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Show Storage Folder")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            storage.revealStorage()
        }
    }
}

extension StorageFailure {
    /// The warning line in the menu bar menu, without the leading symbol.
    var menuTitle: String {
        switch kind {
        case .write: return "Couldn't save \(fileName)"
        case .migration: return "Couldn't convert \(fileName)"
        case .olderVersion: return "Notes from an older version are waiting"
        }
    }

    var menuToolTip: String {
        switch kind {
        case .write: return "Sticky Notes can't save to \(fileName)"
        case .migration: return "Sticky Notes can't convert \(fileName)"
        case .olderVersion:
            return "Notes from an older version are waiting — update your other Macs, then relaunch"
        }
    }
}
