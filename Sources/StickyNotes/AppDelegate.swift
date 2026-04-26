import AppKit
import KeyboardShortcuts

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let noteStore = NoteStore()
    private var windowControllers: [UUID: NoteWindowController] = [:]
    private var notesPanelController: NotesPanelController?

    private var launchAtLoginItem: NSMenuItem!
    private var iCloudItem: NSMenuItem!
    private var storagePathItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        registerHotkeys()
        restoreActiveNotes()
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

        iCloudItem.state = Settings.shared.useICloud ? .on : .off
        iCloudItem.isEnabled = Settings.iCloudAvailable
        if !Settings.iCloudAvailable {
            iCloudItem.toolTip = "iCloud Drive not available on this machine"
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
        let target = !Settings.shared.useICloud
        let newRoot: URL
        if target {
            guard let icloud = Settings.iCloudRootURL else { return }
            newRoot = icloud.appendingPathComponent("StickyNotes", isDirectory: true)
        } else {
            newRoot = Settings.localRootURL.appendingPathComponent("StickyNotes", isDirectory: true)
        }
        noteStore.relocate(to: newRoot)
        Settings.shared.useICloud = target
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
