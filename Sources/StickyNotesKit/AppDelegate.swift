import AppKit

/// Wires the app's pieces together and forwards the application lifecycle to
/// them. What the app does lives in the pieces: the desk, capture, the menus,
/// storage and undo.
@MainActor public final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The production wiring: the user's real storage, preferences and clock.
    /// Everything else about the app is built from the three injected pieces,
    /// so a test constructs it with a temp store, a throwaway `UserDefaults`
    /// suite and a fixed clock.
    public convenience override init() {
        let settings = Settings(defaults: .standard)
        self.init(
            store: NoteStore(rootURL: settings.preferredStorageRoot),
            settings: settings,
            clock: SystemClock()
        )
    }

    private let store: NoteStore
    private let settings: Settings
    private let clock: AppClock

    let recovery: RecoveryFiles
    let undo: UndoCenter
    let desk: DeskController
    let capture: CaptureCoordinator
    let storage: StorageCoordinator
    let menuBar: MenuBarController

    init(store: NoteStore, settings: Settings, clock: AppClock) {
        self.store = store
        self.settings = settings
        self.clock = clock
        recovery = RecoveryFiles(settings: settings, store: store, clock: clock)
        undo = UndoCenter(clock: clock)
        desk = DeskController(store: store, settings: settings, clock: clock, undo: undo, recovery: recovery)
        capture = CaptureCoordinator(desk: desk, store: store)
        storage = StorageCoordinator(store: store, settings: settings, desk: desk, undo: undo)
        menuBar = MenuBarController(
            store: store, settings: settings, desk: desk, capture: capture, storage: storage, undo: undo
        )
        super.init()
    }

    /// URL handling has to be registered before launch finishes, or a URL that
    /// launched the app is delivered before anyone is listening.
    public func applicationWillFinishLaunching(_ notification: Notification) {
        capture.registerURLHandlerAndServices()
        Appearance.startObserving()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar.install()
        capture.registerHotkeys()
        desk.restoreActiveNotes()
        desk.startObserving()
        menuBar.startObservingStorageHealth()
        // After the windows are up: asking about every file's conflict versions
        // is slow, and the notes are already on screen.
        store.resolveConflictsInBackground()

        storage.startPrefetching()
        desk.restoreDailyNoteIfNeeded()

        // A first launch showing an empty screen looks like a failed one.
        if let welcome = WelcomeNote.makeIfNeeded(store: store, defaults: settings.defaults, now: clock.now()) {
            desk.presentWindow(for: welcome)
        }
    }

    /// Quitting drains every pending save, then every buffer that could not be
    /// saved goes to a recovery file (`DeskController.flushForQuit`). Only if
    /// that fails too does the person get to choose between staying open and
    /// losing the text.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let lostCount = desk.flushForQuit()
        guard lostCount > 0 else { return .terminateNow }
        switch unsavedNotesChoice(lostCount) {
        case .keepTrying: return .terminateCancel
        case .quitAnyway: return .terminateNow
        }
    }

    /// ⌘Z in a note window is sent to the responder chain by name, and the
    /// application delegate is where that chain ends.
    @objc func undoLastAction(_ sender: Any?) {
        undo.undoLastAction(sender)
    }

    enum UnsavedNotesChoice { case keepTrying, quitAnyway }

    /// Asks what to do about notes that could be saved nowhere. A test replaces it.
    var unsavedNotesChoice: (_ count: Int) -> UnsavedNotesChoice = { count in
        let alert = NSAlert()
        alert.messageText = count == 1 ? "1 note couldn't be saved" : "\(count) notes couldn't be saved"
        alert.informativeText = "Their text is not on disk and could not be copied elsewhere. Quitting now loses it."
        alert.addButton(withTitle: "Keep Trying")
        alert.addButton(withTitle: "Quit Anyway")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? .keepTrying : .quitAnyway
    }
}
