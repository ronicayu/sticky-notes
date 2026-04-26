import AppKit
import KeyboardShortcuts

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let noteStore = NoteStore()
    private var windowControllers: [UUID: NoteWindowController] = [:]
    private var notesPanelController: NotesPanelController?

    private var launchAtLoginItem: NSMenuItem!
    private var iCloudItem: NSMenuItem!
    private var vaultItem: NSMenuItem!
    private var clearVaultItem: NSMenuItem!
    private var storagePathItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        setupMenuBar()
        registerHotkeys()
        restoreActiveNotes()
    }

    /// Even though we're an accessory (no Dock icon, no system menu bar),
    /// installing a main menu lets standard key equivalents like ⌘C / ⌘V /
    /// ⌘X / ⌘A / ⌘Z reach the focused text view via `performKeyEquivalent`.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Sticky Notes",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")),
                         keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo",
                                        action: Selector(("redo:")),
                                        keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)),
                         keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)),
                         keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)),
                         keyEquivalent: "v")
        let pastePlainItem = editMenu.addItem(withTitle: "Paste and Match Style",
                                              action: #selector(NSTextView.pasteAsPlainText(_:)),
                                              keyEquivalent: "V")
        pastePlainItem.keyEquivalentModifierMask = [.command, .shift, .option]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Sticky Notes")
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "New Note  ⌘⇧S", action: #selector(newNote), keyEquivalent: "")
        menu.addItem(withTitle: "Notes  ⌘⇧L", action: #selector(showNotesPanel), keyEquivalent: "")
        menu.addItem(.separator())

        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        menu.addItem(launchAtLoginItem)

        iCloudItem = NSMenuItem(title: "Sync via iCloud Drive", action: #selector(toggleICloud), keyEquivalent: "")
        menu.addItem(iCloudItem)

        vaultItem = NSMenuItem(title: "Set Obsidian Vault…", action: #selector(chooseVault), keyEquivalent: "")
        menu.addItem(vaultItem)

        clearVaultItem = NSMenuItem(title: "Clear Obsidian Vault", action: #selector(clearVault), keyEquivalent: "")
        menu.addItem(clearVaultItem)

        storagePathItem = NSMenuItem(title: "Show Storage Folder", action: #selector(revealStorage), keyEquivalent: "")
        menu.addItem(storagePathItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        launchAtLoginItem.state = LaunchAgent.isEnabled ? .on : .off
        launchAtLoginItem.isEnabled = LaunchAgent.isAvailable
        if !LaunchAgent.isAvailable {
            launchAtLoginItem.toolTip = "Available only when launched from the bundled .app"
        }

        let vaultActive = Settings.shared.obsidianVaultPath != nil
        iCloudItem.state = (Settings.shared.useICloud && !vaultActive) ? .on : .off
        iCloudItem.isEnabled = Settings.iCloudAvailable && !vaultActive
        if vaultActive {
            iCloudItem.toolTip = "Disabled while an Obsidian vault is configured"
        } else if !Settings.iCloudAvailable {
            iCloudItem.toolTip = "iCloud Drive not available on this machine"
        } else {
            iCloudItem.toolTip = nil
        }

        if let path = Settings.shared.obsidianVaultPath {
            let name = (path as NSString).lastPathComponent
            vaultItem.title = "Vault: \(name)"
            vaultItem.toolTip = path
            clearVaultItem.isHidden = false
        } else {
            vaultItem.title = "Set Obsidian Vault…"
            vaultItem.toolTip = nil
            clearVaultItem.isHidden = true
        }
    }

    private func registerHotkeys() {
        KeyboardShortcuts.onKeyDown(for: .newNote) { [weak self] in
            self?.newNote()
        }
        KeyboardShortcuts.onKeyDown(for: .notesPanel) { [weak self] in
            self?.showNotesPanel()
        }
    }

    private func restoreActiveNotes() {
        for note in noteStore.loadActive() {
            presentWindow(for: note)
        }
    }

    @objc func newNote() {
        let note = Note.makeNew()
        noteStore.save(note)
        presentWindow(for: note)
    }

    @objc func showNotesPanel() {
        if notesPanelController == nil {
            notesPanelController = NotesPanelController(store: noteStore, onActivate: { [weak self] id in
                self?.focusNote(id: id)
            })
        } else {
            notesPanelController?.reload()
        }
        notesPanelController?.showWindow(nil)
        notesPanelController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func focusNote(id: UUID) {
        if let controller = windowControllers[id] {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Fallback: load from disk and present (e.g. file appeared via iCloud sync).
        if let note = noteStore.loadActive().first(where: { $0.id == id }) {
            presentWindow(for: note)
        }
    }

    @objc func toggleLaunchAtLogin() {
        let target = !LaunchAgent.isEnabled
        if let error = LaunchAgent.setEnabled(target) {
            presentError("Couldn't update Launch at Login", error: error)
        }
    }

    @objc func toggleICloud() {
        guard Settings.shared.obsidianVaultPath == nil else { return }
        let target = !Settings.shared.useICloud
        let newRoot: URL
        if target {
            guard let icloud = Settings.iCloudRootURL else { return }
            newRoot = icloud.appendingPathComponent("StickyNotes", isDirectory: true)
        } else {
            newRoot = Settings.localRootURL.appendingPathComponent("StickyNotes", isDirectory: true)
        }
        Settings.shared.useICloud = target
        noteStore.reconfigure(rootURL: newRoot, format: .json)
    }

    @objc func chooseVault() {
        let panel = NSOpenPanel()
        panel.title = "Choose Obsidian Vault"
        panel.message = "Pick the root folder of your Obsidian vault. Notes will be stored as Markdown files under \"<vault>/StickyNotes/\"."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Vault"
        if let response = runOpenPanel(panel), response == .OK, let url = panel.urls.first {
            Settings.shared.obsidianVaultPath = url.path
            let newRoot = url.appendingPathComponent("StickyNotes", isDirectory: true)
            noteStore.reconfigure(rootURL: newRoot, format: .markdown)
        }
    }

    @objc func clearVault() {
        Settings.shared.obsidianVaultPath = nil
        let newRoot: URL
        if Settings.shared.useICloud, let icloud = Settings.iCloudRootURL {
            newRoot = icloud.appendingPathComponent("StickyNotes", isDirectory: true)
        } else {
            newRoot = Settings.localRootURL.appendingPathComponent("StickyNotes", isDirectory: true)
        }
        noteStore.reconfigure(rootURL: newRoot, format: .json)
    }

    private func runOpenPanel(_ panel: NSOpenPanel) -> NSApplication.ModalResponse? {
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal()
    }

    @objc func revealStorage() {
        NSWorkspace.shared.activateFileViewerSelecting([noteStore.activeURL])
    }

    private func presentWindow(for note: Note) {
        if let existing = windowControllers[note.id] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NoteWindowController(note: note, store: noteStore) { [weak self] id in
            self?.windowControllers.removeValue(forKey: id)
        }
        windowControllers[note.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.focusEditor()
    }

    private func presentError(_ message: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
