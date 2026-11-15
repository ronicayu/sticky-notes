import AppKit

/// Where the notes live: the storage mode, the vault and daily-note settings,
/// the Settings window, and the iCloud prefetcher that follows the storage
/// root. Moving the storage re-points the desk's daily note with it.
@MainActor final class StorageCoordinator: NSObject, SettingsCoordinator {
    private let store: NoteStore
    private let settings: Settings
    private let desk: DeskController
    private let undo: UndoCenter?
    private var settingsController: SettingsWindowController?

    private lazy var prefetcher = ICloudPrefetcher { [weak self] urls in
        // A download that ends changes little the watcher reports, so the store is told.
        self?.store.filesDidMaterialize(urls)
    }

    init(store: NoteStore, settings: Settings, desk: DeskController, undo: UndoCenter? = nil) {
        self.store = store
        self.settings = settings
        self.desk = desk
        self.undo = undo
        super.init()
    }

    /// Start prefetching iCloud files under the current storage root.
    func startPrefetching() {
        prefetcher.start(at: store.rootURL)
    }

    @objc func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(coordinator: self, settings: settings)
        }
        settingsController?.show()
    }

    @objc func revealStorage() {
        NSWorkspace.shared.activateFileViewerSelecting([store.activeURL])
    }

    // MARK: - SettingsCoordinator

    func applyStorageMode(_ mode: SettingsWindowController.StorageMode) {
        let previousVault = settings.obsidianVaultPath

        let newRoot: URL
        switch mode {
        case .local:
            settings.obsidianVaultPath = nil
            settings.useICloud = false
            newRoot = settings.localStorageRoot
        case .iCloud:
            settings.obsidianVaultPath = nil
            guard settings.iCloudAvailable, let icloud = settings.iCloudRootURL else {
                // Caller's UI should disable this, but stay safe.
                settings.useICloud = false
                newRoot = settings.localStorageRoot
                break
            }
            settings.useICloud = true
            newRoot = icloud.appendingPathComponent("StickyNotes", isDirectory: true)
        case .vault(let path):
            settings.obsidianVaultPath = path
            newRoot = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("StickyNotes", isDirectory: true)
        }

        // Typing that is still waiting for its save would otherwise land in the
        // new root against a file the old one gave it.
        _ = desk.flushForQuit()
        let report = store.reconfigure(rootURL: newRoot)
        undo?.tellStorageMoved(report)
        startPrefetching()

        // Daily note feature requires a vault — tear down its window when
        // we leave vault mode.
        let nowVault = settings.obsidianVaultPath != nil
        if previousVault != nil && !nowVault {
            desk.tearDownDailyNote()
        } else if nowVault {
            // Entering vault mode from a non-vault one leaves no controller to
            // notify, so a daily note the user had visible stayed missing
            // until the next launch.
            if desk.dailyNote == nil {
                desk.restoreDailyNoteIfNeeded()
            } else {
                desk.dailyNotePatternDidChange()
            }
        }
    }

    func applyDailyPattern(_ pattern: String?) {
        settings.dailyNotesPattern = pattern
        if pattern == nil {
            desk.tearDownDailyNote()
        } else {
            desk.dailyNotePatternDidChange()
        }
    }

    func applyDailyTemplate(_ path: String?) {
        settings.dailyTemplatePath = path
        desk.dailyNoteTemplateDidChange()
    }

    func revealStorageFolder() {
        revealStorage()
    }

    func openTodaysDailyNote() {
        desk.openTodaysDailyNote()
    }
}
