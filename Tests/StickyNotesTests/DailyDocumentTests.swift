import XCTest
@testable import StickyNotesKit

/// Today's daily note with no window: a real `DailyDocument` over real files in
/// a temp vault, with time moved by hand. Nothing here waits for a run loop or
/// for midnight.
///
/// The rule several of these pin down is *when the file gets created*: a person
/// asking for today's note creates it, the clock never does. Creating it on the
/// rollover is what let two Macs collide, since that timer fires at the same
/// wall-clock second on every machine, so both wrote the same new path and
/// iCloud kept both, renaming one `<name> 2.md`.
final class DailyDocumentTests: XCTestCase {
    private var vault: URL!
    private var isolated: IsolatedSettings!
    private var clock: ManualClock!
    private var scheduler: TestScheduler!
    private var settings: Settings { isolated.settings }

    private let pattern = "Daily/{YYYY}-{MM}-{DD}.md"
    private let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        isolated = IsolatedSettings()
        clock = ManualClock()
        scheduler = TestScheduler(clock: clock)
        vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyDocument-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        settings.obsidianVaultPath = vault.path
        settings.dailyNotesPattern = pattern
        settings.dailyTemplatePath = nil
    }

    override func tearDownWithError() throws {
        isolated.tearDown()
        try? FileManager.default.removeItem(at: vault)
    }

    // MARK: - Harness

    private func makeDocument() -> DailyDocument {
        let document = DailyDocument(settings: settings, clock: clock, scheduler: scheduler)
        document.load()
        return document
    }

    private func url(daysFromNow days: Int = 0) throws -> URL {
        try XCTUnwrap(DailyNote.resolvedURL(for: clock.now().addingTimeInterval(Double(days) * day), settings: settings))
    }

    private func exists(daysFromNow days: Int = 0) throws -> Bool {
        FileManager.default.fileExists(atPath: try url(daysFromNow: days).path)
    }

    private func text(daysFromNow days: Int = 0) throws -> String {
        try String(contentsOf: url(daysFromNow: days), encoding: .utf8)
    }

    private func write(_ body: String, daysFromNow days: Int = 0) throws {
        let file = try url(daysFromNow: days)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: file, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func configureTemplate(_ body: String) throws -> URL {
        let template = vault.appendingPathComponent("Template.md")
        try body.write(to: template, atomically: true, encoding: .utf8)
        settings.dailyTemplatePath = template.path
        return template
    }

    /// Bytes that are not UTF-8: the file exists, and cannot be read.
    private func makeUnreadable(daysFromNow days: Int = 0) throws {
        let file = try url(daysFromNow: days)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xff, 0xfe, 0xfd]).write(to: file)
    }

    private func lockDailyFolder() throws {
        let folder = try url().deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
    }

    private func unlockDailyFolder() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: try url().deletingLastPathComponent().path
        )
    }

    // MARK: - Nothing the clock does creates the file

    /// Resolving today's note, at launch, at the rollover, on wake, seeds the
    /// buffer and stops there. On a Mac nobody is typing at, the file never appears.
    /// (Regress scenario: cbbec66, the clock created the daily file on both Macs.)
    func testResolvingTodaysNoteDoesNotCreateIt() throws {
        try configureTemplate("## Today\n\n- [ ] ")
        let document = makeDocument()

        XCTAssertEqual(document.body, "## Today\n\n- [ ] ", "the template still seeds the buffer")
        XCTAssertFalse(try exists(), "the template must not reach disk before the user types")
    }

    func testResolvingTodaysNoteWithNoTemplateCreatesNothingEither() throws {
        _ = makeDocument()
        XCTAssertFalse(try exists())
    }

    /// (Regress scenario: cbbec66.) A Mac that sits through midnight with nobody
    /// typing must not write tomorrow's file, by timer or on wake.
    func testMidnightAndWakeNeverCreateTheNewDaysFile() throws {
        try configureTemplate("## Today\n\n- [ ] ")
        let document = makeDocument()
        document.startRollover()
        var fileChanges = 0
        document.onFileChanged = { fileChanges += 1 }

        scheduler.advance(by: day)

        XCTAssertEqual(document.day, Calendar.current.startOfDay(for: clock.now()), "did not roll over")
        XCTAssertEqual(document.body, "## Today\n\n- [ ] ")
        XCTAssertFalse(try exists(daysFromNow: -1), "the clock created yesterday's file")
        XCTAssertFalse(try exists(), "the clock created the new day's file")

        clock.advance(by: day)
        document.wakeDidHappen()
        XCTAssertFalse(try exists())
        XCTAssertEqual(fileChanges, 2, "the watcher was not told the file moved")
    }

    func testTheFirstKeystrokeCreatesTodaysFile() throws {
        try configureTemplate("## Today\n\n")
        let document = makeDocument()
        document.setBody("## Today\n\nbought milk")
        scheduler.advance(by: 0.6)

        XCTAssertEqual(try text(), "## Today\n\nbought milk", "the seeded template is written along with what was typed")
    }

    /// The rollover flushes the outgoing day before swapping. A day the user
    /// never touched has nothing to flush, and writing the untouched template
    /// there would put the collision back, one day late.
    func testFlushingAnUntouchedTemplateWritesNothing() throws {
        try configureTemplate("## Today\n\n- [ ] ")
        let document = makeDocument()

        XCTAssertTrue(document.flush())
        document.patternDidChange()

        XCTAssertFalse(try exists(), "an untouched buffer must not create the file")
    }

    // MARK: - Existing files

    func testAnExistingFileIsLoadedRatherThanReseeded() throws {
        try configureTemplate("## Today\n\n- [ ] ")
        try write("written on the other Mac")

        let document = makeDocument()

        XCTAssertEqual(document.body, "written on the other Mac")
        XCTAssertEqual(try text(), "written on the other Mac")
    }

    /// Reseeding from a newly configured template is a write to an established
    /// path, so it does not race, but only when the file is there.
    func testChangingTheTemplateRewritesAnExistingEmptyFileButCreatesNone() throws {
        try write("")
        let document = makeDocument()
        try configureTemplate("## Today\n\n")

        document.templateDidChange()

        XCTAssertEqual(try text(), "## Today\n\n")
    }

    func testChangingTheTemplateDoesNotCreateAMissingFile() throws {
        let document = makeDocument()
        try configureTemplate("## Today\n\n")
        document.templateDidChange()

        XCTAssertEqual(document.body, "## Today\n\n", "the buffer still picks it up")
        XCTAssertFalse(try exists())
    }

    func testAFolderOfDuplicatesIsFoldedIntoTheNoteOnLoad() throws {
        try write("first line")
        let file = try url()
        let duplicate = file.deletingLastPathComponent()
            .appendingPathComponent(file.deletingPathExtension().lastPathComponent + " 2.md")
        try "first line\nadded on the other Mac".write(to: duplicate, atomically: true, encoding: .utf8)
        // The sweep moves the duplicate to the Trash, which may not exist in a
        // sandbox; the text reaching the note is what is checked.
        let document = makeDocument()

        XCTAssertTrue(document.body.contains("added on the other Mac"), document.body)
    }

    // MARK: - Creating on an explicit open

    /// The counterpart: asking for today's note is a reason to create it, so it
    /// lands in Obsidian whether or not anything gets typed.
    func testOpeningTodaysNoteOnPurposeCreatesItFromTheTemplate() throws {
        try configureTemplate("## Today\n\n- [ ] ")
        let document = makeDocument()
        XCTAssertFalse(try exists(), "not until asked")

        document.createTodaysFileIfMissing()

        XCTAssertEqual(try text(), "## Today\n\n- [ ] ")
        XCTAssertEqual(document.body, "## Today\n\n- [ ] ")
    }

    func testOpeningTodaysNoteWithNoTemplateCreatesAnEmptyOne() throws {
        let document = makeDocument()
        document.createTodaysFileIfMissing()

        XCTAssertEqual(try text(), "")
    }

    func testOpeningTodaysNoteLeavesAnExistingOneAlone() throws {
        try configureTemplate("## Today\n\n- [ ] ")
        try write("written on the other Mac")

        let document = makeDocument()
        document.createTodaysFileIfMissing()

        XCTAssertEqual(try text(), "written on the other Mac")
    }

    /// iCloud hides an evicted note behind a `.<name>.icloud` stub, so the note
    /// is entirely real and still fails `fileExists`. Creating it here would put
    /// an empty file on top of it.
    func testOpeningTodaysNoteWaitsWhileItIsStillComingDownFromICloud() throws {
        let file = try url()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).icloud"))

        let document = makeDocument()
        document.createTodaysFileIfMissing()

        XCTAssertFalse(try exists(), "never write over a note that is only undownloaded")
    }

    func testOpeningTodaysNoteTwiceKeepsWhatWasTyped() throws {
        let document = makeDocument()
        document.createTodaysFileIfMissing()
        document.setBody("bought milk")
        document.flush()

        document.createTodaysFileIfMissing()

        XCTAssertEqual(try text(), "bought milk")
    }

    // MARK: - Rollover

    func testTheOldDayIsSavedBeforeTheNewDayIsLoaded() throws {
        let document = makeDocument()
        document.startRollover()
        document.setBody("typed just before midnight")
        try write("from the other Mac", daysFromNow: 1)

        scheduler.advance(by: day)

        XCTAssertEqual(try text(daysFromNow: -1), "typed just before midnight")
        XCTAssertEqual(document.body, "from the other Mac")
        XCTAssertFalse(document.hasUnsavedEdits)
    }

    func testAWakeAfterSleepingThroughMidnightRollsOver() throws {
        let document = makeDocument()
        let before = document.day
        clock.advance(by: day)

        document.wakeDidHappen()

        XCTAssertNotEqual(document.day, before)
    }

    func testRollingOverWithinTheSameDayChangesNothing() throws {
        let document = makeDocument()
        document.setBody("keep")
        clock.advance(by: 60)

        guard case .unchanged = document.rolloverIfNeeded(now: clock.now()) else { return XCTFail("rolled over") }
        XCTAssertEqual(document.body, "keep")
        XCTAssertTrue(document.hasUnsavedEdits)
    }

    /// A save that fails at midnight used to be followed by a reload that
    /// replaced the buffer with the new day's file, so the text existed nowhere.
    /// (Model finding R15.)
    func testAFailedSaveAtMidnightKeepsTheTextAndRetries() throws {
        let document = makeDocument()
        document.startRollover()
        document.createTodaysFileIfMissing()
        document.setBody("typed before the disk filled up")
        try lockDailyFolder()
        let oldDay = document.day

        clock.advance(by: day)
        guard case .blocked = document.rolloverIfNeeded(now: clock.now()) else { return XCTFail("rolled over anyway") }

        XCTAssertEqual(document.body, "typed before the disk filled up", "the buffer was replaced")
        XCTAssertEqual(document.day, oldDay)
        XCTAssertTrue(document.hasUnsavedEdits)

        try unlockDailyFolder()
        scheduler.advance(by: NoteDocument.retryDelay + 0.1)

        XCTAssertEqual(try text(daysFromNow: -1), "typed before the disk filled up")
        XCTAssertNotEqual(document.day, oldDay, "never rolled over once the write worked")
        XCTAssertFalse(document.hasUnsavedEdits)
    }

    func testChangingThePatternWithTextThatCannotBeSavedOffersItForRecovery() throws {
        let document = makeDocument()
        document.createTodaysFileIfMissing()
        document.setBody("cannot be written")
        try lockDailyFolder()
        var recovered: [String] = []
        document.saveRecovery = { body, _ in recovered.append(body); return true }

        settings.dailyNotesPattern = "Elsewhere/{YYYY}-{MM}-{DD}.md"
        document.patternDidChange()

        XCTAssertEqual(recovered, ["cannot be written"])
    }

    // MARK: - Outside edits

    func testAnOutsideEditReachesAnIdleDailyNote() throws {
        try write("one")
        let document = makeDocument()
        var replaced = 0
        document.onBodyReplaced = { replaced += 1 }

        try write("one\ntwo")
        document.storeDidChange()

        XCTAssertEqual(document.body, "one\ntwo")
        XCTAssertEqual(replaced, 1)
    }

    /// The daily copy used to apply the file over an unsaved buffer whenever the
    /// window was not key, so grabbing the title bar mid-sentence and a sync
    /// arriving threw the typing away. (Model finding F7; regress scenario
    /// 6cbd1f0 in the daily copy.)
    func testADailyNoteChangeDoesNotDiscardUnsavedTyping() throws {
        try write("one")
        let document = makeDocument()
        document.isEditing = { false }
        document.setBody("one plus mine")

        try write("one\nfrom the other Mac")
        document.storeDidChange()

        XCTAssertEqual(document.body, "one plus mine", "unsaved typing was replaced by the file")
        XCTAssertEqual(document.pendingExternalBody, "one\nfrom the other Mac")
        document.flush()
        let saved = try text()
        XCTAssertTrue(saved.contains("one plus mine") && saved.contains("from the other Mac"), saved)
    }

    func testAnOutsideEditIsHeldBackUnderACaretEvenWhenNothingIsUnsaved() throws {
        try write("one")
        let document = makeDocument()
        document.isEditing = { true }

        try write("one\ntwo")
        document.storeDidChange()

        XCTAssertEqual(document.body, "one")
        XCTAssertNotNil(document.pendingExternalBody)
    }

    func testTwoOutsideEditsInARowBothReachAnIdleDailyNote() throws {
        try write("one")
        let document = makeDocument()
        document.setBody("one\ntyped")
        document.flush()

        try write("one\ntyped\nfirst")
        document.storeDidChange()
        try write("one\ntyped\nfirst\nsecond")
        document.storeDidChange()

        XCTAssertEqual(document.body, "one\ntyped\nfirst\nsecond", "the second outside edit was held back")
    }

    func testTheOwnSaveEchoIsNotMergedAsAnOutsideEdit() throws {
        try write("one")
        let document = makeDocument()
        document.setBody("hello world")
        document.flush()
        document.setBody("hello wrld")
        document.storeDidChange()
        document.flush()

        XCTAssertEqual(try text(), "hello wrld")
    }

    func testLosingFocusMergesAHeldBackEditAndSavesIt() throws {
        try write("one")
        let document = makeDocument()
        document.setBody("one plus mine")
        try write("one\nfrom the other Mac")
        document.storeDidChange()

        document.blur()

        let saved = try text()
        XCTAssertTrue(saved.contains("one plus mine") && saved.contains("from the other Mac"), saved)
        XCTAssertNil(document.pendingExternalBody)
    }

    // MARK: - A note that cannot be read yet

    /// The "waiting for today's note" placeholder accepted typing, saving was
    /// suspended, and the download replaced what was typed. The document now
    /// refuses the text. (Model finding F10.)
    func testTypingWhileTodaysNoteDownloadsIsNotLost() throws {
        try makeUnreadable()
        let document = makeDocument()
        XCTAssertTrue(document.isUnavailable)

        document.setBody("typed into the placeholder")
        scheduler.advance(by: 1)

        XCTAssertEqual(document.body, "", "typing was accepted while the note could not be read")
        XCTAssertFalse(document.hasUnsavedEdits)
        XCTAssertEqual(try Data(contentsOf: url()), Data([0xff, 0xfe, 0xfd]), "the unreadable file was written over")
    }

    func testTheNoteAppearsWhenItsDownloadArrivesThroughTheWatcher() throws {
        try makeUnreadable()
        let document = makeDocument()
        var replaced = 0
        document.onBodyReplaced = { replaced += 1 }

        document.storeDidChange()
        XCTAssertTrue(document.isUnavailable, "a read that still fails must not blank the note")

        try write("the real note")
        document.storeDidChange()

        XCTAssertFalse(document.isUnavailable)
        XCTAssertEqual(document.body, "the real note")
        XCTAssertEqual(replaced, 1)
    }

    func testTheNoteIsRetriedOnItsOwnWhenNoFileEventReportsTheDownload() throws {
        try makeUnreadable()
        let document = makeDocument()
        try write("the real note")

        scheduler.advance(by: DailyDocument.unavailableRetryDelay + 0.1)

        XCTAssertFalse(document.isUnavailable)
        XCTAssertEqual(document.body, "the real note")
    }

    /// A note that is only undownloaded is not a missing one: seeding the
    /// template over it, on launch or at the rollover, would replace real text.
    /// (Regress scenario: stub-as-missing, an unreadable file seeded with the template.)
    func testAnUndownloadedNoteIsNeverSeededWithTheTemplate() throws {
        try configureTemplate("## Today\n\n")
        let file = try url()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stub = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).icloud")
        try Data().write(to: stub)

        let document = makeDocument()
        XCTAssertTrue(document.isUnavailable)
        XCTAssertEqual(document.body, "", "the template was shown in place of a note that is only undownloaded")

        document.setBody("typed anyway")
        document.createTodaysFileIfMissing()
        document.flush()
        scheduler.advance(by: 1)

        XCTAssertFalse(try exists(), "a file was written over the undownloaded note")
    }

    func testRollingOntoAnUndownloadedDayDoesNotSeedItEither() throws {
        try configureTemplate("## Today\n\n")
        let document = makeDocument()
        document.startRollover()
        let tomorrow = try url(daysFromNow: 1)
        try FileManager.default.createDirectory(at: tomorrow.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: tomorrow.deletingLastPathComponent().appendingPathComponent(".\(tomorrow.lastPathComponent).icloud"))

        scheduler.advance(by: day)

        XCTAssertTrue(document.isUnavailable)
        XCTAssertFalse(try exists())
    }

    func testNoVaultMeansNothingIsKeptAndNothingIsWritten() throws {
        settings.obsidianVaultPath = nil
        let document = makeDocument()

        document.setBody("nowhere to go")

        XCTAssertTrue(document.flush())
        XCTAssertNil(document.url)
    }

    // MARK: - Saving

    func testTypingReachesDiskOnlyOnceTheDebounceElapses() throws {
        try write("")
        let document = makeDocument()
        document.setBody("groceries")

        scheduler.advance(by: 0.49)
        XCTAssertEqual(try text(), "", "saved before the debounce elapsed")
        scheduler.advance(by: 0.02)
        XCTAssertEqual(try text(), "groceries")
    }

    func testAFailedSaveIsRetriedAndKeepsTheNoteDirty() throws {
        let document = makeDocument()
        document.createTodaysFileIfMissing()
        try lockDailyFolder()
        document.setBody("on the way to a full disk")

        XCTAssertFalse(document.flush())
        XCTAssertTrue(document.hasUnsavedEdits)

        try unlockDailyFolder()
        scheduler.advance(by: NoteDocument.retryDelay + 0.1)

        XCTAssertEqual(try text(), "on the way to a full disk")
        XCTAssertFalse(document.hasUnsavedEdits)
    }
}
