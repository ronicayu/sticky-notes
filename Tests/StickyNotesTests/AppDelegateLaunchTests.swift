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
