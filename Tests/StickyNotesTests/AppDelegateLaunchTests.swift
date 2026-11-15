import AppKit
import XCTest
@testable import StickyNotesKit

/// `AppDelegate` built the way production builds it, but over a temp store, a
/// throwaway `UserDefaults` suite and a hand-moved clock. Nothing here reads or
/// writes the user's notes, preferences or Application Support folder.
///
/// One thing is still shared: the global hotkeys read their chords from the
/// real `UserDefaults`, which is read-only library state.
final class AppDelegateLaunchTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var isolated: IsolatedSettings!
    private var clock: ManualClock!
    private var delegate: AppDelegate?

    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateLaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(rootURL: root, format: .markdown)
        isolated = IsolatedSettings()
        clock = ManualClock()
    }

    override func tearDownWithError() throws {
        delegate?.noteWindowControllers.values.forEach { $0.window?.close() }
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

        XCTAssertEqual(Set(app.noteWindowControllers.keys), [first.id, second.id])
        XCTAssertNil(app.noteWindowControllers[archived.id], "an archived note has no window")
    }

    func testLaunchOnAnEmptyStoreOpensTheWelcomeNoteOnceAndRemembersItInTheInjectedDefaults() throws {
        let app = makeDelegate()
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(app.noteWindowControllers.count, 1)
        XCTAssertEqual(store.loadActive().map(\.title), ["Welcome"])
        XCTAssertTrue(isolated.settings.defaults.bool(forKey: "didShowWelcomeNote"))
    }

    func testANewNoteUsesTheInjectedColourAndClock() throws {
        isolated.settings.defaultNoteColor = .blue
        _ = seed("Existing")
        let app = makeDelegate()
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        clock.advance(by: 3_600)
        app.newNote()

        let created = try XCTUnwrap(store.loadActive().first { $0.title != "Existing" })
        XCTAssertEqual(created.color, .blue)
        XCTAssertEqual(created.createdAt.timeIntervalSince1970,
                       clock.now().timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(app.noteWindowControllers.count, 2)
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
        let controller = try XCTUnwrap(app.noteWindowControllers[note.id])
        controller.textView.string = "typed just before quitting"
        controller.textDidChange(
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
        let files = try FileManager.default.contentsOfDirectory(at: app.recoveryFolder, includingPropertiesForKeys: nil)
        let recovered = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix(note.id.uuidString) })
        XCTAssertTrue(try String(contentsOf: recovered, encoding: .utf8).contains("typed just before quitting"))
        XCTAssertFalse(recovered.path.hasPrefix(root.path), "the recovery copy is inside the failing storage")
    }

    func testQuittingWhenTheRecoveryCopyFailsToo_KeepTryingCancelsTheQuit() throws {
        let (app, _) = try launchWithUnsavedTypingAndFailingWrites()
        try FileManager.default.createDirectory(at: app.recoveryFolder, withIntermediateDirectories: true)
        try setWritable(false, app.recoveryFolder)
        addTeardownBlock { try? self.setWritable(true, app.recoveryFolder) }
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
        controller.textDidChange(
            Notification(name: NSText.didChangeNotification, object: controller.textView)
        )
        controller.flushPendingSave()

        let saved = try XCTUnwrap(store.loadNote(id: note.id))
        XCTAssertEqual(saved.content, "edited a day later")
        XCTAssertEqual(saved.updatedAt.timeIntervalSince1970,
                       clock.now().timeIntervalSince1970, accuracy: 1)
    }
}
