import AppKit
import XCTest
@testable import StickyNotesKit

/// A real `DailyNoteWindowController` against a temp vault, driven through the
/// delegate callbacks AppKit fires. The rules (when the file is created, merging,
/// rollover) are tested without a window in `DailyDocumentTests`; these prove the
/// window forwards typing to the document and draws what the document holds.
///
/// Settings, the note store, the clock and the scheduler are injected, so nothing
/// here touches the real preferences, Application Support or the wall clock.
@MainActor final class DailyNoteWindowTests: XCTestCase {
    private var vault: URL!
    private var isolated: IsolatedSettings!
    private var store: NoteStore!
    private var clock: ManualClock!
    private var scheduler: TestScheduler!
    private var settings: Settings { isolated.settings }
    private var controllers: [DailyNoteWindowController] = []

    private let pattern = "Daily/{YYYY}-{MM}-{DD}.md"

    override func setUpWithError() throws {
        isolated = IsolatedSettings()
        clock = ManualClock()
        scheduler = TestScheduler(clock: clock)
        vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyNoteWindow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        store = NoteStore(rootURL: vault.appendingPathComponent("StickyNotes"))
        settings.obsidianVaultPath = vault.path
        settings.dailyNotesPattern = pattern
        settings.dailyTemplatePath = nil
    }

    override func tearDownWithError() throws {
        controllers.forEach { $0.window?.close() }
        isolated.tearDown()
        try? FileManager.default.removeItem(at: vault)
    }

    // MARK: - Harness

    private func makeController() -> DailyNoteWindowController {
        let controller = DailyNoteWindowController(settings: settings, store: store, clock: clock, scheduler: scheduler)
        controllers.append(controller)
        return controller
    }

    private func url(daysFromNow days: Int = 0) throws -> URL {
        try XCTUnwrap(DailyNote.resolvedURL(for: clock.now().addingTimeInterval(Double(days) * 86_400), settings: settings))
    }

    private func write(_ body: String, daysFromNow days: Int = 0) throws {
        let file = try url(daysFromNow: days)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Type the way AppKit does: set the text, then fire the delegate callback a
    /// real keystroke would.
    private func type(_ text: String, into controller: DailyNoteWindowController) {
        controller.textView.string = text
        controller.editor.textDidChange(
            Notification(name: NSText.didChangeNotification, object: controller.textView)
        )
    }

    // MARK: - Wiring

    func testOpeningTheWindowShowsTheFileAndLeavesItUntouched() throws {
        try write("written on the other Mac")
        let before = try Data(contentsOf: url())
        let controller = makeController()

        XCTAssertEqual(controller.textView.string, "written on the other Mac")
        XCTAssertEqual(scheduler.pendingCount, 1, "only the midnight timer is armed")
        XCTAssertTrue(controller.flushPendingSave())
        XCTAssertEqual(try Data(contentsOf: url()), before)
    }

    func testTypingCreatesTodaysFileOnceTheDebounceFires() throws {
        let controller = makeController()
        type("bought milk", into: controller)

        XCTAssertFalse(FileManager.default.fileExists(atPath: try url().path))
        scheduler.advance(by: 0.6)
        XCTAssertEqual(try String(contentsOf: url(), encoding: .utf8), "bought milk")
    }

    func testOpeningTodaysNoteOnPurposeCreatesIt() throws {
        let controller = makeController()
        controller.createTodaysFileIfMissing()

        XCTAssertTrue(FileManager.default.fileExists(atPath: try url().path))
    }

    func testAnOutsideEditIsDrawnInAnIdleWindow() throws {
        try write("one")
        let controller = makeController()

        try write("one\ntwo")
        controller.dailyDocument.storeDidChange()

        XCTAssertEqual(controller.textView.string, "one\ntwo")
    }

    /// The window is not key, so the old code applied the file over the typing.
    func testAnOutsideEditDoesNotReplaceUnsavedTypingInAWindowThatIsNotKey() throws {
        try write("one")
        let controller = makeController()
        type("one plus mine", into: controller)

        try write("one\nfrom the other Mac")
        controller.dailyDocument.storeDidChange()

        XCTAssertEqual(controller.textView.string, "one plus mine")
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        XCTAssertTrue(controller.textView.string.contains("from the other Mac"), controller.textView.string)
        XCTAssertTrue(try String(contentsOf: url(), encoding: .utf8).contains("one plus mine"))
    }

    /// The placeholder cannot be typed into, so nothing typed can be lost when
    /// the file arrives.
    func testAWaitingNoteShowsAPlaceholderThatCannotBeTypedInto() throws {
        let file = try url()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xff, 0xfe, 0xfd]).write(to: file)

        let controller = makeController()

        XCTAssertEqual(controller.textView.string, "Waiting for today's note to download…")
        XCTAssertFalse(controller.textView.isEditable)

        try write("the real note")
        controller.dailyDocument.storeDidChange()

        XCTAssertEqual(controller.textView.string, "the real note")
        XCTAssertTrue(controller.textView.isEditable)
    }

    func testMidnightRedrawsTheWindowForTheNewDay() throws {
        try write("today's note")
        try write("tomorrow's note", daysFromNow: 1)
        let controller = makeController()

        scheduler.advance(by: 86_400)

        XCTAssertEqual(controller.textView.string, "tomorrow's note")
    }

    func testFlushingWritesTextTypedSinceTheLastPause() throws {
        let controller = makeController()
        type("half a sentence", into: controller)

        XCTAssertTrue(controller.flushPendingSave())
        XCTAssertEqual(try String(contentsOf: url(), encoding: .utf8), "half a sentence")
    }
}
