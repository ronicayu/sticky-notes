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
        WriteLineage.useFile(settings.writeLineageURL)
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
    private var sleepObserver: NSObjectProtocol?

    init(store: NoteStore, settings: Settings, clock: AppClock) {
        self.store = store
        self.settings = settings
        self.clock = clock
        settings.migrateMachineFiles()
        store.switchRecordsURL = settings.switchRecordsURL
        recovery = RecoveryFiles(settings: settings, store: store, clock: clock)
        undo = UndoCenter(clock: clock)
        desk = DeskController(store: store, settings: settings, clock: clock, undo: undo, recovery: recovery)
        capture = CaptureCoordinator(desk: desk, store: store)
        storage = StorageCoordinator(store: store, settings: settings, desk: desk, undo: undo)
        menuBar = MenuBarController(
            store: store, settings: settings, desk: desk, capture: capture, storage: storage, undo: undo
        )
        super.init()
        desk.menuBarIconFrame = { [weak menuBar] in menuBar?.iconFrame }
    }

    /// URL handling has to be registered before launch finishes, or a URL that
    /// launched the app is delivered before anyone is listening.
    public func applicationWillFinishLaunching(_ notification: Notification) {
        // A read of a file that is only in iCloud then fails at once instead of
        // freezing the app until it has downloaded; every reader treats that as
        // "not here yet".
        DatalessFiles.refuseMaterializingOnThisThread()
        capture.registerURLHandlerAndServices()
        Appearance.startObserving()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar.install()
        saveLineageBeforeSleep()
        capture.registerHotkeys()
        desk.restoreActiveNotes()
        desk.pruneLayout()
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

    public func applicationWillTerminate(_ notification: Notification) {
        WriteLineage.saveNow()
    }

    /// The lineage is saved on a long delay, so a sleep saves it at once: the Mac
    /// may not wake with the app still running.
    private func saveLineageBeforeSleep() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in WriteLineage.saveNow() }
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
