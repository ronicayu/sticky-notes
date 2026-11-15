import AppKit
import XCTest
@testable import StickyNotesKit

/// `AppDelegate` built the way production builds it, but over a temp store, a
/// throwaway `UserDefaults` suite and a hand-moved clock. Nothing here reads or
/// writes the user's notes, preferences or Application Support folder.
///
/// One thing is still shared: the global hotkeys read their chords from the
/// real `UserDefaults`, which is read-only library state.
@MainActor final class AppDelegateLaunchTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var isolated: IsolatedSettings!
    private var clock: ManualClock!
    private var delegate: AppDelegate?

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateLaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(rootURL: root)
        isolated = IsolatedSettings()
        clock = ManualClock()
    }

    override func tearDown() async throws {
        store?.stopWatching()
        delegate?.desk.windowControllers.values.forEach { $0.window?.close() }
        delegate = nil
        isolated.tearDown()
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDelegate() -> AppDelegate {
        let made = AppDelegate(store: store, settings: isolated.settings, clock: clock)
        delegate = made
        return made
    }

    private func seed(_ title: String) -> Note {
        var note = Note.makeNew(
            frame: NSRect(x: 40, y: 40, width: 240, height: 200),
            now: clock.now()
        )
        note.title = title
        note.content = "body of \(title)"
        store.save(note)
        return note
    }

    func testLaunchOpensOneWindowPerActiveNote() throws {
        let first = seed("First")
        let second = seed("Second")
        let archived = seed("Archived")
        store.archive(archived)

        let app = makeDelegate()
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(Set(app.desk.windowControllers.keys), [first.id, second.id])
        XCTAssertNil(app.desk.windowControllers[archived.id], "an archived note has no window")
    }

    func testLaunchOnAnEmptyStoreOpensTheWelcomeNoteOnceAndRemembersItInTheInjectedDefaults() throws {
        let app = makeDelegate()
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(app.desk.windowControllers.count, 1)
        XCTAssertEqual(store.loadActive().map(\.title), ["Welcome"])
        XCTAssertTrue(isolated.settings.defaults.bool(forKey: "didShowWelcomeNote"))
    }

    func testANewNoteUsesTheInjectedColourAndClock() throws {
        isolated.settings.defaultNoteColor = .blue
        let existing = seed("Existing")
        let app = makeDelegate()
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        clock.advance(by: 3_600)
        app.desk.newNote()
        let controller = try XCTUnwrap(app.desk.windowControllers.values.first { $0.noteId != existing.id })
        controller.textView.string = "first words"
        controller.editor.textDidChange(Notification(name: NSText.didChangeNotification, object: controller.textView))
        XCTAssertTrue(controller.flushPendingSave())

        let created = try XCTUnwrap(store.loadActive().first { $0.title != "Existing" })
        XCTAssertEqual(created.color, .blue)
        XCTAssertEqual(created.createdAt.timeIntervalSince1970,
                       clock.now().timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(app.desk.windowControllers.count, 2)
    }

    // MARK: - Quitting while writes fail

    private func setWritable(_ writable: Bool, _ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: url.path
        )
    }

    /// A launched app with one note holding unsaved typing, and a notes folder
    /// that refuses every write.
    private func launchWithUnsavedTypingAndFailingWrites() throws -> (AppDelegate, Note) {
        let note = seed("Draft")
        let app = makeDelegate()
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let controller = try XCTUnwrap(app.desk.windowControllers[note.id])
        controller.textView.string = "typed just before quitting"
        controller.editor.textDidChange(
            Notification(name: NSText.didChangeNotification, object: controller.textView)
        )
        try setWritable(false, store.activeURL)
        addTeardownBlock { [store = store!] in try? self.setWritable(true, store.activeURL) }
        return (app, note)
    }

    func testQuittingWhileSavesFailWritesTheTextToARecoveryFileAndQuits() throws {
        let (app, note) = try launchWithUnsavedTypingAndFailingWrites()
        var asked = false
        app.unsavedNotesChoice = { _ in asked = true; return .keepTrying }

        let reply = app.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertFalse(asked, "asked the person although the text was safely copied")
        let files = try FileManager.default.contentsOfDirectory(at: app.recovery.folder, includingPropertiesForKeys: nil)
        let recovered = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix(note.id.uuidString) })
        XCTAssertTrue(try String(contentsOf: recovered, encoding: .utf8).contains("typed just before quitting"))
        XCTAssertFalse(recovered.path.hasPrefix(root.path), "the recovery copy is inside the failing storage")
    }

    func testQuittingWhenTheRecoveryCopyFailsToo_KeepTryingCancelsTheQuit() throws {
        let (app, _) = try launchWithUnsavedTypingAndFailingWrites()
        try FileManager.default.createDirectory(at: app.recovery.folder, withIntermediateDirectories: true)
        try setWritable(false, app.recovery.folder)
        addTeardownBlock { try? self.setWritable(true, app.recovery.folder) }
        var counts: [Int] = []
        app.unsavedNotesChoice = { counts.append($0); return .keepTrying }

        XCTAssertEqual(app.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(counts, [1])

        app.unsavedNotesChoice = { _ in .quitAnyway }
        XCTAssertEqual(app.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }

    func testQuittingWithEverythingSavedDoesNotAskAnything() throws {
        _ = seed("Calm")
        let app = makeDelegate()
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        app.unsavedNotesChoice = { _ in XCTFail("asked about nothing"); return .keepTrying }

        XCTAssertEqual(app.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }

    func testASavedEditIsStampedWithTheInjectedClock() throws {
        let note = seed("Stamped")
        let controller = NoteWindowController(note: note, store: store, clock: clock, onClosed: { _ in })
        defer { controller.window?.close() }

        clock.advance(by: 86_400)
        controller.textView.string = "edited a day later"
        controller.editor.textDidChange(
            Notification(name: NSText.didChangeNotification, object: controller.textView)
        )
        controller.flushPendingSave()

        let saved = try XCTUnwrap(store.loadNote(id: note.id))
        XCTAssertEqual(saved.content, "edited a day later")
        XCTAssertEqual(saved.updatedAt.timeIntervalSince1970,
                       clock.now().timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - The daily note's unsaved text

    /// A daily note window holding unsaved typing, and a daily folder that
    /// refuses writes.
    private func openDailyNoteWithUnsavedTypingAndFailingWrites(_ app: AppDelegate) throws -> URL {
        let vault = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        isolated.settings.obsidianVaultPath = vault.path
        isolated.settings.dailyNotesPattern = "Daily/{YYYY}-{MM}-{DD}.md"
        app.desk.openTodaysDailyNote()
        let daily = try XCTUnwrap(app.desk.dailyNote)
        daily.window?.orderOut(nil)
        daily.textView.string = "daily text typed just before the disk failed"
        daily.editor.textDidChange(Notification(name: NSText.didChangeNotification, object: daily.textView))
        let folder = vault.appendingPathComponent("Daily", isDirectory: true)
        try setWritable(false, folder)
        addTeardownBlock { try? self.setWritable(true, folder) }
        return folder
    }

    private func dailyRecoveryFiles(_ app: AppDelegate) throws -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: app.recovery.folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("Daily ") }
    }

    func testQuittingWhileTheDailyNoteCannotBeSavedWritesItToARecoveryFile() throws {
        let app = makeDelegate()
        _ = try openDailyNoteWithUnsavedTypingAndFailingWrites(app)
        var asked = false
        app.unsavedNotesChoice = { _ in asked = true; return .keepTrying }

        XCTAssertEqual(app.applicationShouldTerminate(NSApplication.shared), .terminateNow)

        XCTAssertFalse(asked, "asked the person although the text was safely copied")
        let recovered = try XCTUnwrap(dailyRecoveryFiles(app).first)
        XCTAssertEqual(try String(contentsOf: recovered, encoding: .utf8), "daily text typed just before the disk failed")
    }

    /// The count in the prompt is the notes whose text is nowhere: an ordinary
    /// note and the daily note, when the recovery folder fails for both.
    func testQuittingWhenTheRecoveryCopyFailsCountsTheDailyNoteWithTheOthers() throws {
        let note = seed("Draft")
        let app = makeDelegate()
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let controller = try XCTUnwrap(app.desk.windowControllers[note.id])
        controller.textView.string = "note text typed just before quitting"
        controller.editor.textDidChange(Notification(name: NSText.didChangeNotification, object: controller.textView))
        try setWritable(false, store.activeURL)
        addTeardownBlock { [store = store!] in try? self.setWritable(true, store.activeURL) }
        _ = try openDailyNoteWithUnsavedTypingAndFailingWrites(app)
        // A file where the recovery folder should be: nothing can be copied there.
        try FileManager.default.createDirectory(
            at: app.recovery.folder.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: app.recovery.folder)
        var counts: [Int] = []
        app.unsavedNotesChoice = { counts.append($0); return .keepTrying }

        XCTAssertEqual(app.applicationShouldTerminate(NSApplication.shared), .terminateCancel)

        XCTAssertEqual(counts, [2])
        app.unsavedNotesChoice = { _ in .quitAnyway }
    }

    /// Switching off the daily note ends its controller and its armed save with
    /// it, so what could not be written is copied first.
    func testClearingTheDailyPatternKeepsUnsavedTextInARecoveryFile() throws {
        let app = makeDelegate()
        _ = try openDailyNoteWithUnsavedTypingAndFailingWrites(app)

        app.storage.applyDailyPattern(nil)

        XCTAssertNil(app.desk.dailyNote)
        let recovered = try XCTUnwrap(dailyRecoveryFiles(app).first)
        XCTAssertEqual(try String(contentsOf: recovered, encoding: .utf8), "daily text typed just before the disk failed")
    }

    func testLeavingVaultModeKeepsUnsavedDailyTextInARecoveryFile() throws {
        let app = makeDelegate()
        _ = try openDailyNoteWithUnsavedTypingAndFailingWrites(app)

        app.storage.applyStorageMode(.local)

        XCTAssertNil(app.desk.dailyNote)
        XCTAssertFalse(try dailyRecoveryFiles(app).isEmpty)
    }
}
