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
/// Two things to know before adding tests here. `Settings.shared` is
/// `UserDefaults.standard`, so the keys these touch are saved and put back in
/// `tearDown`. And the window is never shown, moved, or resized: those are
/// what write `_daily.json`, which lives in the *real* Application Support
/// folder rather than the temp vault.
final class DailyNoteWindowTests: XCTestCase {
    private var vault: URL!
    private var savedVault: String?
    private var savedPattern: String?
    private var savedTemplate: String?

    private let pattern = "Daily/{YYYY}-{MM}-{DD}.md"

    override func setUpWithError() throws {
        savedVault = Settings.shared.obsidianVaultPath
        savedPattern = Settings.shared.dailyNotesPattern
        savedTemplate = Settings.shared.dailyTemplatePath

        vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyNoteWindow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        Settings.shared.obsidianVaultPath = vault.path
        Settings.shared.dailyNotesPattern = pattern
        Settings.shared.dailyTemplatePath = nil
    }

    override func tearDownWithError() throws {
        Settings.shared.obsidianVaultPath = savedVault
        Settings.shared.dailyNotesPattern = savedPattern
        Settings.shared.dailyTemplatePath = savedTemplate
        try? FileManager.default.removeItem(at: vault)
    }

    // MARK: - Harness

    private func todaysURL() throws -> URL {
        try XCTUnwrap(DailyNote.resolvedURL())
    }

    private var todayExists: Bool {
        guard let url = DailyNote.resolvedURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    @discardableResult
    private func configureTemplate(_ body: String) throws -> URL {
        let url = vault.appendingPathComponent("Template.md")
        try body.write(to: url, atomically: true, encoding: .utf8)
        Settings.shared.dailyTemplatePath = url.path
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
        let controller = DailyNoteWindowController()

        XCTAssertEqual(controller.textView.string, "## Today\n\n- [ ] ", "the template still seeds the buffer")
        XCTAssertFalse(todayExists, "the template must not reach disk before the user types")
    }

    func testResolvingTodaysNoteWithNoTemplateCreatesNothingEither() throws {
        _ = DailyNoteWindowController()
        XCTAssertFalse(todayExists)
    }

    func testTheFirstKeystrokeCreatesTodaysFile() throws {
        try configureTemplate("## Today\n\n")
        let controller = DailyNoteWindowController()
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
        let controller = DailyNoteWindowController()

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

        let controller = DailyNoteWindowController()

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

        let controller = DailyNoteWindowController()
        try configureTemplate("## Today\n\n")
        controller.templateDidChange()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "## Today\n\n")
    }

    func testChangingTheTemplateDoesNotCreateAMissingFile() throws {
        let controller = DailyNoteWindowController()
        try configureTemplate("## Today\n\n")
        controller.templateDidChange()

        XCTAssertEqual(controller.textView.string, "## Today\n\n", "the buffer still picks it up")
        XCTAssertFalse(todayExists)
    }

    // MARK: - Creating on an explicit open

    /// The counterpart: asking for today's note *is* a reason to create it,
    /// so it lands in Obsidian whether or not anything gets typed. `show()`
    /// calls this for the menu bar and the hotkey; the test drives the file
    /// half directly, because showing a real window would also write the
    /// window-state file in the real Application Support folder.
    func testOpeningTodaysNoteOnPurposeCreatesItFromTheTemplate() throws {
        try configureTemplate("## Today\n\n- [ ] ")
        let controller = DailyNoteWindowController()
        XCTAssertFalse(todayExists, "not until asked")

        controller.createTodaysFileIfMissing()

        XCTAssertEqual(try String(contentsOf: todaysURL(), encoding: .utf8), "## Today\n\n- [ ] ")
        XCTAssertEqual(controller.textView.string, "## Today\n\n- [ ] ")
    }

    func testOpeningTodaysNoteWithNoTemplateCreatesAnEmptyOne() throws {
        let controller = DailyNoteWindowController()
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

        let controller = DailyNoteWindowController()
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

        let controller = DailyNoteWindowController()
        controller.createTodaysFileIfMissing()

        XCTAssertFalse(todayExists, "never write over a note that is only undownloaded")
    }

    /// Opening it a second time must not blank out what was typed in between.
    func testOpeningTodaysNoteTwiceKeepsWhatWasTyped() throws {
        let controller = DailyNoteWindowController()
        controller.createTodaysFileIfMissing()
        type("bought milk", into: controller)

        controller.createTodaysFileIfMissing()

        XCTAssertEqual(try String(contentsOf: todaysURL(), encoding: .utf8), "bought milk")
    }
}
