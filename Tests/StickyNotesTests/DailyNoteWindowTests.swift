import AppKit
import XCTest
@testable import StickyNotesKit

/// End-to-end tests for the daily-note window against a temp vault: a real
/// `DailyNoteWindowController`, real files, and the same delegate callback
/// AppKit fires on a keystroke.
///
/// What these exist to pin down is *when the file gets created*. The rule:
/// a person asking for today's note creates it, the clock never does.
/// Creating it on the rollover is what let two Macs collide — that timer
/// fires at the same wall-clock second on every machine, so both wrote the
/// same new path and iCloud kept both, renaming one `<name> 2.md`.
///
/// Settings, the note store and the clock are injected, so nothing here
/// touches the real preferences, Application Support or the wall clock; the
/// window-state file (`_daily.json`) lands in a temp folder too.
final class DailyNoteWindowTests: XCTestCase {
    private var vault: URL!
    private var isolated: IsolatedSettings!
    private var store: NoteStore!
    private var clock: ManualClock!
    private var settings: Settings { isolated.settings }

    private let pattern = "Daily/{YYYY}-{MM}-{DD}.md"

    override func setUpWithError() throws {
        isolated = IsolatedSettings()
        clock = ManualClock()

        vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyNoteWindow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        store = NoteStore(rootURL: vault.appendingPathComponent("StickyNotes"), format: .markdown)

        settings.obsidianVaultPath = vault.path
        settings.dailyNotesPattern = pattern
        settings.dailyTemplatePath = nil
    }

    override func tearDownWithError() throws {
        isolated.tearDown()
        try? FileManager.default.removeItem(at: vault)
    }

    // MARK: - Harness

    private func makeController() -> DailyNoteWindowController {
        DailyNoteWindowController(settings: settings, store: store, clock: clock)
    }

    private func todaysURL() throws -> URL {
        try XCTUnwrap(DailyNote.resolvedURL(for: clock.now(), settings: settings))
    }

    private var todayExists: Bool {
        guard let url = DailyNote.resolvedURL(for: clock.now(), settings: settings) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    @discardableResult
    private func configureTemplate(_ body: String) throws -> URL {
        let url = vault.appendingPathComponent("Template.md")
        try body.write(to: url, atomically: true, encoding: .utf8)
        settings.dailyTemplatePath = url.path
        return url
    }

    /// Type the way AppKit does: set the text, fire the delegate callback a
    /// real keystroke would, then skip the debounce.
    private func type(_ text: String, into controller: DailyNoteWindowController) {
        controller.textView.string = text
        controller.textDidChange(
            Notification(name: NSText.didChangeNotification, object: controller.textView)
        )
        controller.flushPendingSave()
    }

    // MARK: - Nothing the clock does creates the file

    /// The fix for the midnight race. Resolving today's note — at launch, at
    /// the rollover, on wake — seeds the buffer and stops there. On a Mac
    /// nobody is typing at, the file never appears.
    func testResolvingTodaysNoteDoesNotCreateIt() throws {
        try configureTemplate("## Today\n\n- [ ] ")
        let controller = makeController()

        XCTAssertEqual(controller.textView.string, "## Today\n\n- [ ] ", "the template still seeds the buffer")
        XCTAssertFalse(todayExists, "the template must not reach disk before the user types")
    }

    func testResolvingTodaysNoteWithNoTemplateCreatesNothingEither() throws {
        _ = makeController()
        XCTAssertFalse(todayExists)
    }

    func testTheFirstKeystrokeCreatesTodaysFile() throws {
        try configureTemplate("## Today\n\n")
        let controller = makeController()
        type("## Today\n\nbought milk", into: controller)

        XCTAssertTrue(todayExists)
        XCTAssertEqual(
            try String(contentsOf: todaysURL(), encoding: .utf8),
            "## Today\n\nbought milk",
            "the seeded template is written along with what was typed"
        )
    }

    /// The midnight rollover flushes the outgoing day before swapping. A day
    /// the user never touched has nothing to flush, and writing the untouched
    /// template there would put the collision back — one day late, and still
    /// at the same second on both Macs.
    func testFlushingAnUntouchedTemplateWritesNothing() throws {
        try configureTemplate("## Today\n\n- [ ] ")
        let controller = makeController()

        // `patternDidChange` runs the same unconditional `saveNow()` the
        // rollover does, without needing to fake a clock.
        controller.patternDidChange()

        XCTAssertFalse(todayExists, "an untouched buffer must not create the file")
    }

    // MARK: - Existing files

    func testAnExistingFileIsLoadedRatherThanReseeded() throws {
        try configureTemplate("## Today\n\n- [ ] ")
        let url = try todaysURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "written on the other Mac".write(to: url, atomically: true, encoding: .utf8)

        let controller = makeController()

        XCTAssertEqual(controller.textView.string, "written on the other Mac")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "written on the other Mac")
    }

    /// Reseeding from a newly configured template is a write to an
    /// established path, so it doesn't race — but only when the file is
    /// actually there.
    func testChangingTheTemplateRewritesAnExistingEmptyFileButCreatesNone() throws {
        let url = try todaysURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "".write(to: url, atomically: true, encoding: .utf8)

        let controller = makeController()
        try configureTemplate("## Today\n\n")
        controller.templateDidChange()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "## Today\n\n")
    }

    func testChangingTheTemplateDoesNotCreateAMissingFile() throws {
        let controller = makeController()
        try configureTemplate("## Today\n\n")
        controller.templateDidChange()

        XCTAssertEqual(controller.textView.string, "## Today\n\n", "the buffer still picks it up")
        XCTAssertFalse(todayExists)
    }

    // MARK: - Creating on an explicit open

    /// The counterpart: asking for today's note *is* a reason to create it,
    /// so it lands in Obsidian whether or not anything gets typed. `show()`
    /// calls this for the menu bar and the hotkey; the test drives the file
    /// half directly, because showing a real window needs a screen.
    func testOpeningTodaysNoteOnPurposeCreatesItFromTheTemplate() throws {
        try configureTemplate("## Today\n\n- [ ] ")
        let controller = makeController()
        XCTAssertFalse(todayExists, "not until asked")

        controller.createTodaysFileIfMissing()

        XCTAssertEqual(try String(contentsOf: todaysURL(), encoding: .utf8), "## Today\n\n- [ ] ")
        XCTAssertEqual(controller.textView.string, "## Today\n\n- [ ] ")
    }

    func testOpeningTodaysNoteWithNoTemplateCreatesAnEmptyOne() throws {
        let controller = makeController()
        controller.createTodaysFileIfMissing()

        XCTAssertTrue(todayExists)
        XCTAssertEqual(try String(contentsOf: todaysURL(), encoding: .utf8), "")
    }

    func testOpeningTodaysNoteLeavesAnExistingOneAlone() throws {
        try configureTemplate("## Today\n\n- [ ] ")
        let url = try todaysURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "written on the other Mac".write(to: url, atomically: true, encoding: .utf8)

        let controller = makeController()
        controller.createTodaysFileIfMissing()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "written on the other Mac")
    }

    /// The one that would cost real text: iCloud hides an evicted note behind
    /// a `.<name>.icloud` stub, so the note is entirely real and still fails
    /// `fileExists`. Creating it here would put an empty file on top of it.
    func testOpeningTodaysNoteWaitsWhileItIsStillComingDownFromICloud() throws {
        let url = try todaysURL()
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stub = folder.appendingPathComponent(".\(url.lastPathComponent).icloud")
        try Data().write(to: stub)

        let controller = makeController()
        controller.createTodaysFileIfMissing()

        XCTAssertFalse(todayExists, "never write over a note that is only undownloaded")
    }

    /// Opening it a second time must not blank out what was typed in between.
    func testOpeningTodaysNoteTwiceKeepsWhatWasTyped() throws {
        let controller = makeController()
        controller.createTodaysFileIfMissing()
        type("bought milk", into: controller)

        controller.createTodaysFileIfMissing()

        XCTAssertEqual(try String(contentsOf: todaysURL(), encoding: .utf8), "bought milk")
    }
}
