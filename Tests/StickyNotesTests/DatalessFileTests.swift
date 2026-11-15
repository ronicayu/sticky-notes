import AppKit
import XCTest
@testable import StickyNotesKit

/// Files that iCloud keeps in the cloud and not on disk. A real one cannot be made
/// on a test machine, so each test names the files that count as dataless through
/// the store's (or the daily note's) `isDataless` seam and watches what is read
/// and what is asked for.
@MainActor final class DatalessFileTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var clock: ManualClock!
    private var scheduler: TestScheduler!
    private var datalessNames: Set<String> = []
    private var reads: [String] = []
    private var downloads: [String] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dataless-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clock = ManualClock()
        scheduler = TestScheduler(clock: clock)
        store = NoteStore(rootURL: root, clock: clock)
        install(on: store)
    }

    override func tearDown() async throws {
        store?.stopWatching()
        try? FileManager.default.removeItem(at: root)
    }

    private func install(on store: NoteStore) {
        store.isDataless = { [unowned self] in datalessNames.contains($0.lastPathComponent) }
        store.willReadFile = { [unowned self] in reads.append($0.lastPathComponent) }
        store.startDownload = { [unowned self] in downloads.append($0.lastPathComponent) }
    }

    private func makeNote(_ content: String, labels: [String] = []) -> Note {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200), now: clock.now())
        note.title = "Note"
        note.content = content
        note.labels = labels
        return note
    }

    /// The file of a saved note.
    private func file(of note: Note, in folder: URL? = nil) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: folder ?? store.activeURL, includingPropertiesForKeys: nil)
        return try XCTUnwrap(files.first { (try? String(contentsOf: $0, encoding: .utf8))?.contains(note.id.uuidString) == true })
    }

    private func markDataless(_ url: URL) { datalessNames.insert(url.lastPathComponent) }
    private func markDownloaded(_ url: URL) { datalessNames.remove(url.lastPathComponent) }

    // MARK: - The error a refused read gives

    func testARefusedReadOfADatalessFileIsRecognisedWhateverWrapsIt() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EDEADLK))
        let wrapped = NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSUnderlyingErrorKey: posix])
        let doubly = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSUnderlyingErrorKey: wrapped])
        XCTAssertTrue(DatalessFiles.isNotMaterializedError(posix))
        XCTAssertTrue(DatalessFiles.isNotMaterializedError(wrapped))
        XCTAssertTrue(DatalessFiles.isNotMaterializedError(doubly))
        XCTAssertTrue(DatalessFiles.isNotMaterializedError(POSIXError(.EDEADLK)))
    }

    func testOtherReadErrorsAreNotTakenForADatalessFile() {
        let noSuchFile = NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))])
        XCTAssertFalse(DatalessFiles.isNotMaterializedError(noSuchFile))
        XCTAssertFalse(DatalessFiles.isNotMaterializedError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        XCTAssertFalse(DatalessFiles.isNotMaterializedError(CocoaError(.fileReadCorruptFile)))
    }

    func testRefusingMaterializationOnAThreadLeavesOrdinaryReadsAlone() throws {
        let file = root.appendingPathComponent("plain.md")
        try "text".write(to: file, atomically: true, encoding: .utf8)
        var text: String?
        // The policy belongs to the thread, so it is set on one this test can lose.
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            DatalessFiles.refuseMaterializingOnThisThread()
            text = try? String(contentsOf: file, encoding: .utf8)
            done.signal()
        }
        done.wait()
        XCTAssertEqual(text, "text")
    }

    func testAnOrdinaryFileAndAMissingFileAreNotDataless() throws {
        let file = root.appendingPathComponent("plain.md")
        try "text".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(DatalessFiles.isDataless(file))
        XCTAssertFalse(DatalessFiles.isDataless(root.appendingPathComponent("missing.md")))
    }

    // MARK: - A dataless note is never read, and is unknown, not absent

    func testADatalessNoteIsNeverReadAndItsDownloadIsAskedForOnce() throws {
        let note = makeNote("kept in the cloud")
        store.save(note)
        let url = try file(of: note)
        markDataless(url)
        reads = []

        XCTAssertNil(store.snapshot(id: note.id))
        XCTAssertNil(store.loadNote(id: note.id))
        XCTAssertEqual(store.loadActive().count, 0)
        XCTAssertNil(store.snapshot(id: note.id))

        XCTAssertEqual(reads, [], "a dataless file was read")
        XCTAssertEqual(downloads, [url.lastPathComponent], "asked for once, not on every look")
    }

    func testTheDownloadIsAskedForAgainOnlyAfterTheFirstRequestHasLapsed() throws {
        let note = makeNote("evicted twice")
        store.save(note)
        let url = try file(of: note)
        markDataless(url)

        _ = store.snapshot(id: note.id)
        clock.advance(by: DatalessGuard.requestInterval - 1)
        _ = store.snapshot(id: note.id)
        XCTAssertEqual(downloads.count, 1)
        clock.advance(by: 2)
        _ = store.snapshot(id: note.id)
        XCTAssertEqual(downloads.count, 2, "a request that never finished was not repeated")
    }

    func testAFileThatArrivedAndWasEvictedAgainIsAskedForAgain() throws {
        let note = makeNote("evicted again")
        store.save(note)
        let url = try file(of: note)
        markDataless(url)
        _ = store.snapshot(id: note.id)
        markDownloaded(url)
        XCTAssertEqual(store.snapshot(id: note.id)?.note.content, "evicted again")

        markDataless(url)
        _ = store.snapshot(id: note.id)

        XCTAssertEqual(downloads.count, 2)
    }

    func testAListingLeavesTheDatalessNoteOutAndWhereIsSaysUnknown() throws {
        let kept = makeNote("on disk")
        let away = makeNote("in the cloud")
        store.save(kept)
        store.save(away)
        markDataless(try file(of: away))
        store.handleFileSystemEvent()

        XCTAssertEqual(store.listActive()?.map(\.id), [kept.id])
        guard case .unknown = store.whereIs(id: away.id) else {
            return XCTFail("a note that is only in iCloud was reported as \(store.whereIs(id: away.id))")
        }
    }

    func testANoteRenamedOnAnotherMacAndNotDownloadedIsUnknownNotMissing() throws {
        let away = makeNote("renamed elsewhere")
        store.save(away)
        let url = try file(of: away)
        let renamed = url.deletingLastPathComponent().appendingPathComponent("a name with no id in it.md")
        try FileManager.default.moveItem(at: url, to: renamed)
        markDataless(renamed)
        store.handleFileSystemEvent()

        guard case .unknown = store.whereIs(id: UUID()) else {
            return XCTFail("a dataless file in the folder could be any note, so no note is missing")
        }
    }

    func testADatalessNoteIsFoundAgainOnceItHasDownloaded() throws {
        let note = makeNote("back from the cloud")
        store.save(note)
        let url = try file(of: note)
        markDataless(url)
        store.handleFileSystemEvent()
        XCTAssertNil(store.loadNote(id: note.id))

        markDownloaded(url)

        XCTAssertEqual(store.loadActive().map(\.id), [note.id], "the arrived file was not read")
        XCTAssertEqual(store.loadNote(id: note.id)?.content, "back from the cloud")
    }

    // MARK: - The system's refusal is an answer of the same kind

    func testARefusedReadIsNotDownloadedYetNotUnreadableOrAFailure() throws {
        var note = makeNote("refused")
        store.save(note)
        let fingerprint = try XCTUnwrap(store.snapshot(id: note.id)).fingerprint
        store.dataless.readData = { _ in
            throw NSError(
                domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EDEADLK))])
        }

        XCTAssertNil(store.snapshot(id: note.id))
        XCTAssertEqual(store.loadActive().count, 0)
        note.content = "refused and more"
        let result = store.save(note, expecting: fingerprint)

        guard case let .failed(error) = result, case .notDownloadedYet? = error as? SaveError else {
            return XCTFail("expected \"not downloaded yet\", got \(result)")
        }
        XCTAssertNil(store.lastFailure, "a refused read of a dataless file raised a storage alarm")
        XCTAssertFalse(downloads.isEmpty, "the refused file's download was not asked for")
    }

    // MARK: - A save over a dataless file waits

    func testASaveOverADatalessFileWritesNothingAndSaysItIsNotDownloadedYet() throws {
        var note = makeNote("first")
        store.save(note)
        let fingerprint = try XCTUnwrap(store.snapshot(id: note.id)).fingerprint
        let url = try file(of: note)
        let before = try Data(contentsOf: url)
        markDataless(url)
        reads = []

        note.content = "first and more"
        let result = store.save(note, expecting: fingerprint)

        guard case let .failed(error) = result, case .notDownloadedYet? = error as? SaveError else {
            return XCTFail("expected a retryable \"not downloaded yet\", got \(result)")
        }
        XCTAssertEqual(try Data(contentsOf: url), before, "the file was written over unseen")
        XCTAssertEqual(reads, [])
        XCTAssertNil(store.lastFailure, "waiting for a download is not a storage failure")
    }

    func testTypingIntoANoteWhoseFileIsDatalessStaysUnsavedAndIsWrittenOnceItArrives() throws {
        let note = makeNote("base")
        store.save(note)
        let document = NoteDocument(note: note, repository: store, scheduler: scheduler, clock: clock)
        let url = try file(of: note)
        markDataless(url)

        document.setBody("base and typed words")
        scheduler.advance(by: NoteDocument.debounce + 0.1)

        XCTAssertTrue(document.hasUnsavedEdits, "text counted as saved that is on no disk")
        XCTAssertEqual(document.buffer.content, "base and typed words")
        XCTAssertFalse(document.fileCannotBeRead, "a wait for a download is no reason to write a recovery copy")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).contains("typed words"), false)

        markDownloaded(url)
        scheduler.advance(by: NoteDocument.retryDelay + 0.1)

        XCTAssertFalse(document.hasUnsavedEdits)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("base and typed words"))
    }

    func testARetryAfterADatalessFileBacksOffAndIsBroughtForwardByTheNextFileChange() throws {
        let note = makeNote("base")
        store.save(note)
        let document = NoteDocument(note: note, repository: store, scheduler: scheduler, clock: clock)
        let url = try file(of: note)
        markDataless(url)
        document.setBody("typed")
        scheduler.advance(by: NoteDocument.debounce + 0.1)
        scheduler.advance(by: NoteDocument.retryDelay + 0.1)
        scheduler.advance(by: NoteDocument.retryDelay * 2 + 0.1)
        XCTAssertTrue(document.hasUnsavedEdits)

        markDownloaded(url)
        document.storeDidChange()
        scheduler.advance(by: NoteDocument.retryDelay + 0.1)

        XCTAssertFalse(document.hasUnsavedEdits)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("typed"))
    }

    // MARK: - The window stays open

    func testTheWindowOfADatalessNoteStaysOpenWhenTheDeskReconciles() throws {
        let note = makeNote("open on the desk")
        store.save(note)
        let clock = ManualClock()
        let settings = IsolatedSettings()
        defer { settings.tearDown() }
        let desk = DeskController(
            store: store, settings: settings.settings, clock: clock, undo: UndoCenter(clock: clock),
            recovery: RecoveryFiles(settings: settings.settings, store: store, clock: clock), scheduler: scheduler)
        desk.presentWindow(for: note, activate: false)
        defer { desk.windowControllers.values.forEach { $0.window?.close() } }
        markDataless(try file(of: note))
        store.handleFileSystemEvent()

        desk.reconcileOpenWindows()

        XCTAssertNotNil(desk.windowControllers[note.id], "the window of a note that is only in iCloud was closed")
        XCTAssertEqual(store.listActive()?.count, 0, "precondition: the listing lacks the note")
    }

    // MARK: - Labels

    func testALabelOnlyADatalessNoteHasIsLeftOutForNowAndComesBack() throws {
        let plain = makeNote("plain", labels: ["work"])
        let away = makeNote("away", labels: ["travel"])
        store.save(plain)
        store.save(away)
        XCTAssertEqual(store.allLabels(), ["travel", "work"])

        let awayFile = try file(of: away)
        markDataless(awayFile)
        store.handleFileSystemEvent()
        reads = []
        XCTAssertEqual(store.allLabels(), ["work"])
        XCTAssertEqual(store.allLabels(), ["work"])
        XCTAssertFalse(reads.contains(awayFile.lastPathComponent), "the dataless file was read to find its labels")

        markDownloaded(try file(of: away))
        XCTAssertEqual(store.allLabels(), ["travel", "work"], "the labels of the arrived note were dropped for good")
    }

    // MARK: - Converting old JSON notes

    func testADatalessJSONNoteIsWaitedForNotReportedAsAFailure() throws {
        let note = Note(
            id: UUID(), title: "Old", content: "from json", width: 300, height: 220, color: .blue,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_500))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = store.activeURL.appendingPathComponent("\(note.id.uuidString).json")
        try encoder.encode(note).write(to: json)
        markDataless(json)

        let waiting = store.migrateJSONNotes()

        XCTAssertEqual(waiting.migrated, 0)
        XCTAssertTrue(waiting.failures.isEmpty, "\(waiting.failures)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: json.path), "the JSON was set aside unread")

        markDownloaded(json)
        let done = store.migrateJSONNotes()

        XCTAssertEqual(done.migrated, 1)
        XCTAssertEqual(store.loadActive().first?.content, "from json")
    }

    func testARefusedReadOfAJSONNoteIsNotAMigrationFailure() throws {
        let note = Note(
            id: UUID(), title: "Old", content: "from json", width: 300, height: 220, color: .blue,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_500))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(note).write(to: store.activeURL.appendingPathComponent("\(note.id.uuidString).json"))
        store.dataless.readData = { _ in throw POSIXError(.EDEADLK) }

        let report = store.migrateJSONNotes()

        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertNil(store.lastFailure)
    }

    // MARK: - Switching storage waits for downloads

    func testSwitchingStorageCopiesANoteThatDownloadsWhileTheSwitchWaits() throws {
        let note = makeNote("copied after the download")
        store.save(note)
        let url = try file(of: note)
        markDataless(url)
        store.startDownload = { [unowned self] in
            downloads.append($0.lastPathComponent)
            markDownloaded($0)
        }

        let report = store.reconfigure(rootURL: root.appendingPathComponent("elsewhere", isDirectory: true))

        XCTAssertEqual(report.notReadable, 0)
        XCTAssertEqual(store.loadActive().map(\.content), ["copied after the download"])
    }

    func testSwitchingStorageCountsANoteThatNeverDownloadsAsNotReadable() throws {
        let note = makeNote("never arrives")
        store.save(note)
        markDataless(try file(of: note))
        store.downloadWait = 0.2

        let report = store.reconfigure(rootURL: root.appendingPathComponent("elsewhere", isDirectory: true))

        XCTAssertEqual(report.notReadable, 1)
    }
}

/// Today's daily note when its file is in iCloud and not on this Mac.
final class DatalessDailyNoteTests: XCTestCase {
    private var vault: URL!
    private var isolated: IsolatedSettings!
    private var clock: ManualClock!
    private var scheduler: TestScheduler!
    private var datalessNames: Set<String> = []
    private var downloads: [String] = []

    override func setUpWithError() throws {
        NoteStore.systemComputerName = "This Mac"
        isolated = IsolatedSettings()
        clock = ManualClock()
        scheduler = TestScheduler(clock: clock)
        vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatalessDaily-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        isolated.settings.obsidianVaultPath = vault.path
        isolated.settings.dailyNotesPattern = "Daily/{YYYY}-{MM}-{DD}.md"
        isolated.settings.dailyTemplatePath = nil
    }

    override func tearDownWithError() throws {
        isolated.tearDown()
        try? FileManager.default.removeItem(at: vault)
    }

    private func makeDocument() -> DailyDocument {
        let document = DailyDocument(settings: isolated.settings, clock: clock, scheduler: scheduler)
        document.isDataless = { [unowned self] in datalessNames.contains($0.lastPathComponent) }
        document.startDownload = { [unowned self] in downloads.append($0.lastPathComponent) }
        return document
    }

    private func todaysFile() throws -> URL {
        try XCTUnwrap(DailyNote.resolvedURL(for: clock.now(), settings: isolated.settings))
    }

    private func writeToday(_ text: String) throws -> URL {
        let url = try todaysFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testADatalessDailyFileShowsTheWaitingStateAndIsNotReadOrReplacedByTheTemplate() throws {
        let url = try writeToday("kept in the cloud")
        let template = vault.appendingPathComponent("Template.md")
        try "## template".write(to: template, atomically: true, encoding: .utf8)
        isolated.settings.dailyTemplatePath = template.path
        datalessNames = [url.lastPathComponent]
        let document = makeDocument()

        document.load()

        XCTAssertTrue(document.isUnavailable, "the note should wait for its download")
        XCTAssertEqual(document.body, "")
        XCTAssertEqual(downloads, [url.lastPathComponent])
        document.setBody("typed over the placeholder")
        scheduler.advance(by: 1)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "kept in the cloud")
    }

    func testTheDailyNoteLoadsOnceTheFileHasDownloaded() throws {
        let url = try writeToday("from the cloud")
        datalessNames = [url.lastPathComponent]
        let document = makeDocument()
        document.load()
        XCTAssertTrue(document.isUnavailable)

        datalessNames = []
        scheduler.advance(by: DailyDocument.unavailableRetryDelay + 0.1)

        XCTAssertFalse(document.isUnavailable)
        XCTAssertEqual(document.body, "from the cloud")
    }

    func testTheWatcherPicksUpTheDownloadWithoutWaitingForTheRetry() throws {
        let url = try writeToday("from the cloud")
        datalessNames = [url.lastPathComponent]
        let document = makeDocument()
        document.load()

        datalessNames = []
        document.storeDidChange()

        XCTAssertFalse(document.isUnavailable)
        XCTAssertEqual(document.body, "from the cloud")
    }

    func testASaveOverADailyFileThatWentDatalessWaitsAndKeepsTheText() throws {
        let url = try writeToday("first")
        let document = makeDocument()
        document.load()
        document.setBody("first and typed")
        datalessNames = [url.lastPathComponent]

        scheduler.advance(by: NoteDocument.debounce + 0.1)

        XCTAssertTrue(document.hasUnsavedEdits)
        XCTAssertEqual(document.body, "first and typed")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "first")

        datalessNames = []
        scheduler.advance(by: NoteDocument.retryDelay + 0.1)

        XCTAssertFalse(document.hasUnsavedEdits)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "first and typed")
    }

    func testADatalessTemplateIsNotReadAndTheDailyNoteStartsBlank() throws {
        let template = vault.appendingPathComponent("Template.md")
        try "## template".write(to: template, atomically: true, encoding: .utf8)
        isolated.settings.dailyTemplatePath = template.path
        datalessNames = [template.lastPathComponent]
        let guardrail = DatalessGuard()
        guardrail.isDataless = { [unowned self] in datalessNames.contains($0.lastPathComponent) }
        guardrail.startDownload = { [unowned self] in downloads.append($0.lastPathComponent) }

        let text = DailyNote.renderedTemplate(
            for: clock.now(), fileURL: try todaysFile(), settings: isolated.settings, dataless: guardrail)

        XCTAssertNil(text)
        XCTAssertEqual(downloads, [template.lastPathComponent])
    }

    func testADuplicateThatIsNotDownloadedIsLeftWhereItIs() throws {
        let original = vault.appendingPathComponent("2026-01-01.md")
        let duplicate = vault.appendingPathComponent("2026-01-01 2.md")
        try "original".write(to: original, atomically: true, encoding: .utf8)
        try "duplicate".write(to: duplicate, atomically: true, encoding: .utf8)
        let guardrail = DatalessGuard()
        guardrail.isDataless = { $0.lastPathComponent == "2026-01-01 2.md" }
        guardrail.startDownload = { _ in }

        let healed = DailyNote.healDuplicates(in: vault, dataless: guardrail)

        XCTAssertEqual(healed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicate.path))
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
    }
}
