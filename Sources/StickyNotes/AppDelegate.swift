import AppKit
import KeyboardShortcuts

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let noteStore = NoteStore()
    private var windowControllers: [UUID: NoteWindowController] = [:]
    private var notesPanelController: NotesPanelController?
    private var notesHidden = false
    private var hideAllItem: NSMenuItem!

    private var launchAtLoginItem: NSMenuItem!
    private var iCloudItem: NSMenuItem!
    private var vaultItem: NSMenuItem!
    private var clearVaultItem: NSMenuItem!
    private var storagePathItem: NSMenuItem!
    private var defaultColorItem: NSMenuItem!
    private var dailyNoteItem: NSMenuItem!
    private var dailyPatternItem: NSMenuItem!
    private var dailyClearItem: NSMenuItem!
    private var dailyTemplateItem: NSMenuItem!
    private var dailyTemplateClearItem: NSMenuItem!
    private var dailyNoteController: DailyNoteWindowController?

    private lazy var prefetcher = ICloudPrefetcher { [weak self] in
        // Manual nudge in case FSEvents missed the materialization.
        self?.handleStoreChange()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        setupMenuBar()
        registerHotkeys()
        restoreActiveNotes()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStoreChange),
            name: NoteStore.didChange,
            object: nil
        )

        prefetcher.start(at: noteStore.rootURL)
        restoreDailyNoteIfNeeded()
    }

    private func restoreDailyNoteIfNeeded() {
        guard Settings.shared.obsidianVaultPath != nil,
              Settings.shared.dailyNotesPattern != nil else { return }
        let state = DailyNote.loadState()
        guard state.visible else { return }
        if dailyNoteController == nil {
            dailyNoteController = DailyNoteWindowController()
        }
        dailyNoteController?.show()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Bring open windows in line with what's on disk. Triggered by
    /// `NoteStore.didChange`, which fires both for our own writes (no-op here)
    /// and for external file changes — Obsidian edits, files arriving via
    /// iCloud Drive, archives created on another Mac, etc.
    @objc private func handleStoreChange() {
        DispatchQueue.main.async { [weak self] in
            self?.reconcileOpenWindows()
        }
    }

    private func reconcileOpenWindows() {
        let active = noteStore.loadActive()
        let activeIds = Set(active.map { $0.id })

        // Close windows whose underlying note is no longer active (archived
        // or deleted on another machine).
        for id in Array(windowControllers.keys) where !activeIds.contains(id) {
            if let controller = windowControllers.removeValue(forKey: id) {
                controller.window?.close()
            }
        }

        // Open windows for active notes that aren't visible yet (created on
        // another machine and synced in).
        for note in active where windowControllers[note.id] == nil {
            presentWindow(for: note, activate: false)
            if notesHidden {
                windowControllers[note.id]?.window?.orderOut(nil)
            }
        }
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
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        let pastePlainItem = editMenu.addItem(
            withTitle: "Paste and Match Style",
            action: Selector(("pasteAsPlainText:")),
            keyEquivalent: "V"
        )
        pastePlainItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // Custom template image renders as the sticky-note silhouette and
            // gets tinted automatically by the system (light/dark/click).
            if let icon = NSImage(named: "MenuBarIcon") {
                icon.isTemplate = true
                button.image = icon
            } else {
                button.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Sticky Notes")
            }
        }

        let menu = NSMenu()
        menu.delegate = self

        let versionItem = NSMenuItem(
            title: "Sticky Notes \(AppDelegate.appVersionString)",
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())

        menu.addItem(withTitle: "New Note  ⌘⇧S", action: #selector(newNote), keyEquivalent: "")
        menu.addItem(withTitle: "Notes  ⌘⇧L", action: #selector(showNotesPanel), keyEquivalent: "")
        hideAllItem = NSMenuItem(title: "Hide All Notes  ⌘⇧H",
                                  action: #selector(toggleHideAll),
                                  keyEquivalent: "")
        menu.addItem(hideAllItem)
        menu.addItem(.separator())

        defaultColorItem = NSMenuItem(title: "Default Color", action: nil, keyEquivalent: "")
        defaultColorItem.submenu = makeDefaultColorSubmenu()
        menu.addItem(defaultColorItem)

        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        menu.addItem(launchAtLoginItem)

        iCloudItem = NSMenuItem(title: "Sync via iCloud Drive", action: #selector(toggleICloud), keyEquivalent: "")
        menu.addItem(iCloudItem)

        vaultItem = NSMenuItem(title: "Set Obsidian Vault…", action: #selector(chooseVault), keyEquivalent: "")
        menu.addItem(vaultItem)

        clearVaultItem = NSMenuItem(title: "Clear Obsidian Vault", action: #selector(clearVault), keyEquivalent: "")
        menu.addItem(clearVaultItem)

        dailyNoteItem = NSMenuItem(title: "Show Today's Daily Note", action: #selector(toggleDailyNote), keyEquivalent: "")
        menu.addItem(dailyNoteItem)

        dailyPatternItem = NSMenuItem(title: "Set Daily Note Pattern…", action: #selector(setDailyPattern), keyEquivalent: "")
        menu.addItem(dailyPatternItem)

        dailyClearItem = NSMenuItem(title: "Clear Daily Note Pattern", action: #selector(clearDailyPattern), keyEquivalent: "")
        menu.addItem(dailyClearItem)

        dailyTemplateItem = NSMenuItem(title: "Set Daily Note Template…", action: #selector(setDailyTemplate), keyEquivalent: "")
        menu.addItem(dailyTemplateItem)

        dailyTemplateClearItem = NSMenuItem(title: "Clear Daily Note Template", action: #selector(clearDailyTemplate), keyEquivalent: "")
        menu.addItem(dailyTemplateClearItem)

        storagePathItem = NSMenuItem(title: "Show Storage Folder", action: #selector(revealStorage), keyEquivalent: "")
        menu.addItem(storagePathItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
    }

    private func makeDefaultColorSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "Default Color")
        for color in NoteColor.allCases {
            let item = NSMenuItem(
                title: color.displayName,
                action: #selector(setDefaultColor(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = color.rawValue
            item.image = AppDelegate.colorSwatch(for: color)
            submenu.addItem(item)
        }
        return submenu
    }

    /// Version stamped into Info.plist by `scripts/build-app.sh`. Falls back
    /// to "dev" when running from `swift run` (no bundle = no Info.plist).
    private static var appVersionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        if let raw = info["CFBundleShortVersionString"] as? String,
           !raw.isEmpty,
           raw != "__APP_VERSION__" {
            return "v\(raw)"
        }
        return "dev"
    }

    private static func colorSwatch(for color: NoteColor) -> NSImage {
        return NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let path = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                xRadius: 3,
                yRadius: 3
            )
            NSColor(hex: color.bodyHex)?.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.18).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
    }

    @objc func setDefaultColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let color = NoteColor(rawValue: raw) else { return }
        Settings.shared.defaultNoteColor = color
    }

    func menuWillOpen(_ menu: NSMenu) {
        hideAllItem.title = (notesHidden ? "Show All Notes  ⌘⇧H" : "Hide All Notes  ⌘⇧H")
        hideAllItem.isEnabled = !windowControllers.isEmpty

        if let submenu = defaultColorItem.submenu {
            let current = Settings.shared.defaultNoteColor
            for item in submenu.items {
                if let raw = item.representedObject as? String,
                   let color = NoteColor(rawValue: raw) {
                    item.state = color == current ? .on : .off
                }
            }
        }

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

        let vaultActiveForDaily = Settings.shared.obsidianVaultPath != nil
        let pattern = Settings.shared.dailyNotesPattern
        dailyPatternItem.isHidden = !vaultActiveForDaily
        dailyClearItem.isHidden = !(vaultActiveForDaily && pattern != nil)
        dailyNoteItem.isHidden = !(vaultActiveForDaily && pattern != nil)

        if let pattern = pattern {
            let preview = DailyNote.render(pattern, date: Date())
            dailyPatternItem.title = "Daily Pattern: \(pattern)"
            dailyPatternItem.toolTip = "Today resolves to: \(preview)"
        } else {
            dailyPatternItem.title = "Set Daily Note Pattern…"
            dailyPatternItem.toolTip = nil
        }

        let dailyVisible = (dailyNoteController?.window?.isVisible ?? false)
        dailyNoteItem.title = dailyVisible ? "Hide Today's Daily Note" : "Show Today's Daily Note"

        let templatePath = Settings.shared.dailyTemplatePath
        dailyTemplateItem.isHidden = !(vaultActiveForDaily && pattern != nil)
        dailyTemplateClearItem.isHidden = !(vaultActiveForDaily && pattern != nil && templatePath != nil)
        if let path = templatePath {
            let display = (path as NSString).lastPathComponent
            dailyTemplateItem.title = "Daily Template: \(display)"
            dailyTemplateItem.toolTip = path
        } else {
            dailyTemplateItem.title = "Set Daily Note Template…"
            dailyTemplateItem.toolTip = nil
        }
    }

    private func registerHotkeys() {
        KeyboardShortcuts.onKeyDown(for: .newNote) { [weak self] in
            self?.newNote()
        }
        KeyboardShortcuts.onKeyDown(for: .notesPanel) { [weak self] in
            self?.showNotesPanel()
        }
        KeyboardShortcuts.onKeyDown(for: .hideAll) { [weak self] in
            self?.toggleHideAll()
        }
    }

    @objc func toggleHideAll() {
        guard !windowControllers.isEmpty else { return }
        notesHidden.toggle()
        if notesHidden {
            for controller in windowControllers.values {
                controller.window?.orderOut(nil)
            }
        } else {
            for controller in windowControllers.values {
                controller.window?.orderFront(nil)
            }
        }
    }

    private func restoreActiveNotes() {
        for note in noteStore.loadActive() {
            presentWindow(for: note)
        }
    }

    @objc func newNote() {
        // Creating a new note while everything is hidden should bring all
        // notes back so the new one isn't the only thing visible.
        if notesHidden { toggleHideAll() }
        let note = Note.makeNew()
        noteStore.save(note)
        presentWindow(for: note)
        // New notes start with the cursor in the title — that's where the
        // user should be naming the thing first.
        windowControllers[note.id]?.focusTitle()
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
        prefetcher.start(at: noteStore.rootURL)
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
            prefetcher.start(at: noteStore.rootURL)
            dailyNoteController?.patternDidChange()
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
        prefetcher.start(at: noteStore.rootURL)

        // Daily note feature requires a vault — tear down its window when
        // the vault disappears.
        dailyNoteController?.window?.orderOut(nil)
        dailyNoteController = nil
    }

    @objc func toggleDailyNote() {
        guard Settings.shared.obsidianVaultPath != nil,
              Settings.shared.dailyNotesPattern != nil else { return }
        if let controller = dailyNoteController, controller.window?.isVisible == true {
            controller.window?.orderOut(nil)
            return
        }
        if dailyNoteController == nil {
            dailyNoteController = DailyNoteWindowController()
        }
        dailyNoteController?.show()
    }

    @objc func setDailyPattern() {
        let alert = NSAlert()
        alert.messageText = "Daily note path pattern"
        alert.informativeText = """
        Path inside the vault. Tokens: {YYYY} {YY} {MM} {M} {DD} {D} {dddd} {ddd}.
        Example: Daily/{YYYY}-{MM}-{DD}.md
        """
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        input.stringValue = Settings.shared.dailyNotesPattern ?? "Daily/{YYYY}-{MM}-{DD}.md"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        if alert.runModal() == .alertFirstButtonReturn {
            let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Settings.shared.dailyNotesPattern = value.isEmpty ? nil : value
            // If a controller is already showing, point it at the new path.
            dailyNoteController?.patternDidChange()
        }
    }

    @objc func clearDailyPattern() {
        Settings.shared.dailyNotesPattern = nil
        dailyNoteController?.window?.orderOut(nil)
        dailyNoteController = nil
    }

    @objc func setDailyTemplate() {
        guard let vault = Settings.shared.obsidianVaultPath else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Daily Note Template"
        panel.message = "Pick the markdown template applied when today's daily note doesn't exist yet. Tokens {{date}}, {{date:FMT}}, {{time}}, {{title}}, {{yesterday}}, {{tomorrow}} are expanded on insert."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        panel.directoryURL = URL(fileURLWithPath: vault, isDirectory: true)
        panel.prompt = "Use This Template"
        guard let response = runOpenPanel(panel), response == .OK, let url = panel.urls.first else { return }

        // Store as a vault-relative path when possible so the setting
        // survives moving the vault to a different host folder.
        let vaultPrefix = (vault as NSString).appendingPathComponent("") + "/"
        let chosen = url.path
        let stored = chosen.hasPrefix(vaultPrefix) ? String(chosen.dropFirst(vaultPrefix.count)) : chosen
        Settings.shared.dailyTemplatePath = stored
        dailyNoteController?.templateDidChange()
    }

    @objc func clearDailyTemplate() {
        Settings.shared.dailyTemplatePath = nil
    }

    private func runOpenPanel(_ panel: NSOpenPanel) -> NSApplication.ModalResponse? {
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal()
    }

    @objc func revealStorage() {
        NSWorkspace.shared.activateFileViewerSelecting([noteStore.activeURL])
    }

    private func presentWindow(for note: Note, activate: Bool = true) {
        if let existing = windowControllers[note.id] {
            existing.showWindow(nil)
            if activate {
                existing.window?.makeKeyAndOrderFront(nil)
            } else {
                existing.window?.orderFront(nil)
            }
            return
        }
        let controller = NoteWindowController(note: note, store: noteStore) { [weak self] id in
            self?.windowControllers.removeValue(forKey: id)
        }
        windowControllers[note.id] = controller
        controller.showWindow(nil)
        if activate {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Sync-induced presentation: float the window in without yanking
            // focus from whatever the user is doing.
            controller.window?.orderFront(nil)
        }
    }

    private func presentError(_ message: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
