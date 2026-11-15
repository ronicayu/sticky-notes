import AppKit
import CoreServices
import XCTest
@testable import StickyNotesKit

private final class ChangeLog: @unchecked Sendable {
    private(set) var changes: [NoteStore.Change] = []
    func append(_ change: NoteStore.Change) { changes.append(change) }
}

private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    private var offMain = 0
    func record() {
        lock.lock(); defer { lock.unlock() }
        total += 1
        if !Thread.isMainThread { offMain += 1 }
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return total }
    var countOffMain: Int { lock.lock(); defer { lock.unlock() }; return offMain }
}

/// What the file watcher keeps of the events the system reports.
final class FileWatcherEventTests: XCTestCase {
    private func flags(_ values: Int...) -> UInt32 { values.reduce(0) { $0 | UInt32($1) } }

    func testOurOwnWriteIsDropped() {
        let own = flags(kFSEventStreamEventFlagOwnEvent, kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemModified)
        XCTAssertEqual(FileWatcher.verdict(path: "/n/a.md", flags: own), .ignore)
    }

    func testAnOutsideChangeOfContentNameOrExistenceIsReported() {
        for flag in [
            kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemRemoved,
            kFSEventStreamEventFlagItemRenamed, kFSEventStreamEventFlagItemModified,
        ] {
            let withAttributes = flags(flag, kFSEventStreamEventFlagItemXattrMod, kFSEventStreamEventFlagItemIsFile)
            XCTAssertEqual(FileWatcher.verdict(path: "/n/a.md", flags: withAttributes), .changed("/n/a.md"))
        }
    }

    func testAChangeOfAttributesAloneIsKeptApart() {
        for flag in [
            kFSEventStreamEventFlagItemXattrMod, kFSEventStreamEventFlagItemInodeMetaMod,
            kFSEventStreamEventFlagItemFinderInfoMod, kFSEventStreamEventFlagItemChangeOwner,
        ] {
            XCTAssertEqual(
                FileWatcher.verdict(path: "/n/a.md", flags: flags(flag, kFSEventStreamEventFlagItemIsFile)),
                .metadataOnly("/n/a.md"))
        }
    }

    func testAnEventWithNothingToReportIsDropped() {
        XCTAssertEqual(FileWatcher.verdict(path: "/n/a.md", flags: flags(kFSEventStreamEventFlagItemIsFile)), .ignore)
    }

    func testLosingTrackMeansAnythingMayHaveChangedEvenForOurOwnWrite() {
        for flag in [
            kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped,
            kFSEventStreamEventFlagRootChanged, kFSEventStreamEventFlagMount, kFSEventStreamEventFlagUnmount,
            kFSEventStreamEventFlagEventIdsWrapped,
        ] {
            XCTAssertEqual(
                FileWatcher.verdict(path: "/n", flags: flags(flag, kFSEventStreamEventFlagOwnEvent)), .everything)
        }
    }

    func testEventsMergeWithoutLosingAnything() {
        var events = FileWatcher.Events(changed: ["a"], metadataOnly: ["b"])
        events.merge(FileWatcher.Events(changed: ["c"], metadataOnly: [], everything: true))
        XCTAssertEqual(events, FileWatcher.Events(changed: ["a", "c"], metadataOnly: ["b"], everything: true))
        XCTAssertTrue(FileWatcher.Events().isEmpty)
    }
}

/// The real stream, on a real folder: this process's own writes are not reported,
/// another process's are, with their paths.
@MainActor final class FileWatcherStreamTests: XCTestCase {
    private var folder: URL!
    private var watcher: FileWatcher?

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileWatcherStream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        watcher?.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    private func writeFromAnotherProcess(_ text: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' \"$1\" > \"$2\"", "sh", text, url.path]
        try process.run()
        process.waitUntilExit()
    }

    func testOurOwnAtomicWriteIsNotReportedAndAnotherProcessesWriteIs() async throws {
        var batches: [FileWatcher.Events] = []
        let outside = expectation(description: "the other process's write was reported")
        let ours = folder.appendingPathComponent("ours.md")
        let theirs = folder.appendingPathComponent("theirs.md")
        let watcher = FileWatcher(debounce: 0.05) { events in
            batches.append(events)
            if events.changed.contains(where: { $0.hasSuffix("theirs.md") }) { outside.fulfill() }
        }
        self.watcher = watcher
        watcher.watch([folder])
        // The stream starts asynchronously; events from before it runs are not its to report.
        try await Task.sleep(nanoseconds: 300_000_000)

        try Data("ours".utf8).write(to: ours, options: .atomic)
        try await Task.sleep(nanoseconds: 400_000_000)
        try writeFromAnotherProcess("theirs", to: theirs)
        await fulfillment(of: [outside], timeout: 10)

        let reported = batches.flatMap { $0.changed.union($0.metadataOnly) }
        XCTAssertFalse(reported.contains { $0.contains("ours.md") }, "our own write came back as an event: \(reported)")
        XCTAssertTrue(reported.contains { $0.hasSuffix("theirs.md") })
    }
}

/// What the store does with the events the watcher hands it.
@MainActor final class StoreFileEventTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var clock: ManualClock!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreFileEvents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clock = ManualClock()
        store = NoteStore(rootURL: root, clock: clock)
    }

    override func tearDown() async throws {
        store?.stopWatching()
        try? FileManager.default.removeItem(at: root)
    }

    private func seed(_ content: String, labels: [String] = []) -> Note {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200), now: clock.now())
        note.content = content
        note.labels = labels
        store.save(note)
        return note
    }

    private func file(of note: Note) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: store.activeURL, includingPropertiesForKeys: nil)
        return try XCTUnwrap(files.first { (try? String(contentsOf: $0, encoding: .utf8))?.contains(note.id.uuidString) == true })
    }

    private func changes(during work: () -> Void) -> [NoteStore.Change] {
        let seen = ChangeLog()
        let token = NotificationCenter.default.addObserver(forName: NoteStore.didChange, object: store, queue: nil) {
            seen.append(NoteStore.change(in: $0))
        }
        defer { NotificationCenter.default.removeObserver(token) }
        work()
        return seen.changes
    }

    private func rewrite(_ note: Note, _ content: String) throws {
        let url = try file(of: note)
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: note.content, with: content)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testOnlyTheFilesNamedAreReadAgainAndTheRestOfTheCacheStands() throws {
        let changed = seed("before")
        let other = seed("other")
        _ = store.loadActive()
        try rewrite(changed, "after")
        // Behind the store's back: a cache that is dropped would show this note gone.
        try FileManager.default.removeItem(at: file(of: other))
        let readsBefore = store.readCount

        _ = changes { store.handleFileSystemEvent(.init(changed: [try! file(of: changed).path])) }

        XCTAssertEqual(store.readCount - readsBefore, 1, "more than the named file was read")
        XCTAssertEqual(Set(store.loadActive().map(\.content)), ["after", "other"])
    }

    func testTheChangeNamesTheNotesItTouched() throws {
        let changed = seed("before")
        _ = seed("other")
        _ = store.loadActive()
        try rewrite(changed, "after")

        let seen = changes { store.handleFileSystemEvent(.init(changed: [try! file(of: changed).path])) }

        XCTAssertEqual(seen, [.external([changed.id])])
    }

    func testANoteFileThatWasRemovedIsNamedToo() throws {
        let gone = seed("going")
        _ = seed("staying")
        _ = store.loadActive()
        let url = try file(of: gone)
        try FileManager.default.removeItem(at: url)

        let seen = changes { store.handleFileSystemEvent(.init(changed: [url.path])) }

        XCTAssertEqual(seen, [.external([gone.id])])
        XCTAssertEqual(store.loadActive().map(\.content), ["staying"])
    }

    func testANewFileIsListedAndItsNoteNamed() throws {
        _ = seed("here")
        _ = store.loadActive()
        let newcomer = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200), now: clock.now())
        let url = store.activeURL.appendingPathComponent("newcomer.md")
        try "---\nid: \(newcomer.id.uuidString)\n---\nfrom another Mac\n".write(to: url, atomically: true, encoding: .utf8)

        let seen = changes { store.handleFileSystemEvent(.init(changed: [url.path])) }

        XCTAssertEqual(seen, [.external([newcomer.id])])
        XCTAssertEqual(Set(store.loadActive().map(\.content)), ["here", "from another Mac\n"])
    }

    func testFilesThatAreNotNotesCostNothing() throws {
        _ = seed("here")
        _ = store.loadActive()
        let readsBefore = store.readCount

        let seen = changes {
            store.handleFileSystemEvent(.init(
                changed: [store.activeURL.appendingPathComponent(".DS_Store").path,
                          store.activeURL.appendingPathComponent(".x.md.icloud").path]))
        }

        XCTAssertEqual(seen, [])
        XCTAssertEqual(store.readCount, readsBefore)
    }

    func testAChangeOfAttributesAloneIsNotReadAsAChange() throws {
        let note = seed("here")
        _ = store.loadActive()
        let readsBefore = store.readCount

        let seen = changes { store.handleFileSystemEvent(.init(metadataOnly: [try! file(of: note).path])) }

        XCTAssertEqual(seen, [])
        XCTAssertEqual(store.readCount, readsBefore)
    }

    func testAChangeOfAttributesIsAChangeWhenTheFileWasNotDownloaded() throws {
        let note = seed("in the cloud")
        let url = try file(of: note)
        var dataless = true
        store.isDataless = { _ in dataless }
        store.startDownload = { _ in }
        store.handleFileSystemEvent()
        XCTAssertEqual(store.loadActive().count, 0)

        dataless = false
        let seen = changes { store.handleFileSystemEvent(.init(metadataOnly: [url.path])) }

        XCTAssertEqual(seen, [.external([note.id])], "the end of a download went unnoticed")
        XCTAssertEqual(store.loadActive().map(\.content), ["in the cloud"])
    }

    func testAFileThatWasNotCachedMakesTheChangeAnythingMayHaveChanged() throws {
        let note = seed("here")
        // Nothing has been listed, so there is no cache to correct.
        let seen = changes { store.handleFileSystemEvent(.init(changed: [try! file(of: note).path])) }

        XCTAssertEqual(seen, [.reset])
    }

    func testLosingTrackIsAReset() {
        _ = seed("here")
        XCTAssertEqual(changes { store.handleFileSystemEvent(.init(everything: true)) }, [.reset])
    }

    func testAnEventForFilesOfAnotherFolderStillCorrectsTheIndex() throws {
        let note = seed("here")
        _ = store.loadActive()
        let url = try file(of: note)
        let moved = url.deletingLastPathComponent().appendingPathComponent("renamed by Obsidian.md")
        try FileManager.default.moveItem(at: url, to: moved)

        _ = changes { store.handleFileSystemEvent(.init(changed: [url.path, moved.path])) }

        XCTAssertEqual(store.snapshot(id: note.id)?.note.content, "here", "the renamed file was not found")
    }

    func testMaterializedFilesAreReadAndAnnounced() throws {
        let note = seed("arrived")
        _ = store.loadActive()
        try rewrite(note, "arrived and changed")

        let seen = changes { store.filesDidMaterialize([try! file(of: note)]) }

        XCTAssertEqual(seen, [.external([note.id])])
        XCTAssertEqual(store.loadActive().map(\.content), ["arrived and changed"])
    }

    // MARK: - Windows

    func testAWindowDoesNotReadItsFileForAChangeToAnotherNote() throws {
        let mine = seed("mine")
        let theirs = seed("theirs")
        let settings = IsolatedSettings()
        defer { settings.tearDown() }
        let desk = DeskController(
            store: store, settings: settings.settings, clock: clock, undo: UndoCenter(clock: clock),
            recovery: RecoveryFiles(settings: settings.settings, store: store, clock: clock))
        desk.presentWindow(for: mine, activate: false)
        desk.presentWindow(for: theirs, activate: false)
        defer { desk.windowControllers.values.forEach { $0.window?.close() } }
        let windowFile = try file(of: mine)
        var reads: [String] = []
        store.willReadFile = { reads.append($0.lastPathComponent) }

        NotificationCenter.default.post(
            name: NoteStore.didChange, object: store, userInfo: [NoteStore.changeKey: NoteStore.Change.external([theirs.id])])

        XCTAssertFalse(reads.contains(windowFile.lastPathComponent), "a window read its file for a change that was not about it")
        reads = []
        NotificationCenter.default.post(
            name: NoteStore.didChange, object: store, userInfo: [NoteStore.changeKey: NoteStore.Change.external([mine.id])])
        XCTAssertTrue(reads.contains(windowFile.lastPathComponent), "the window of the changed note did not read it")
    }

    // MARK: - The conflict sweep

    private func conflictVersion(of note: Note, content: String) throws -> NoteStore.ConflictVersionHandle {
        let url = root.appendingPathComponent("version-\(UUID().uuidString).md")
        try "---\nid: \(note.id.uuidString)\nupdated: 1970-01-01T00:00:01Z\n---\n\(content)\n"
            .write(to: url, atomically: true, encoding: .utf8)
        return .init(url: url, markResolved: {})
    }

    func testTheReportedFileIsAskedAboutAndItsVersionsAreReadOffTheMainThread() async throws {
        let note = seed("shared line")
        let version = try conflictVersion(of: note, content: "shared line\nonly in the version")
        let url = try file(of: note)
        let asked = Tally()
        store.conflictVersionsProvider = { _ in
            dispatchPrecondition(condition: .notOnQueue(.main))
            asked.record()
            // A busy daemon: the main thread must not be the one that waits.
            Thread.sleep(forTimeInterval: 0.4)
            return [version]
        }
        store.otherVersionsRemover = { _ in }
        var reads: [(String, Bool)] = []
        store.dataless.readData = { requested in
            reads.append((requested.lastPathComponent, Thread.isMainThread))
            return try Data(contentsOf: requested)
        }
        let merged = expectation(forNotification: NoteStore.didChange, object: store) {
            if case .external = NoteStore.change(in: $0) { return true }
            return false
        }

        let began = CFAbsoluteTimeGetCurrent()
        store.handleFileSystemEvent(.init(changed: [url.path]))
        let returned = CFAbsoluteTimeGetCurrent() - began

        XCTAssertLessThan(returned, 0.2, "the main thread waited for the version query")
        await fulfillment(of: [merged], timeout: 10)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.countOffMain, 1)
        let versionReads = reads.filter { $0.0 == URL(fileURLWithPath: version.url.path).lastPathComponent }
        XCTAssertEqual(versionReads.map(\.1), [false], "the version file was read on the main thread: \(reads)")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("only in the version"))
    }

    func testTheWholeFolderIsSweptAtMostOnceInTheIntervalForEventsThatNameNoFile() async throws {
        _ = seed("a note")
        let asked = Tally()
        store.conflictVersionsProvider = { _ in asked.record(); return [] }
        store.dataless.readData = { try Data(contentsOf: $0) }

        store.handleFileSystemEvent(.init(everything: true))
        try await Task.sleep(nanoseconds: 300_000_000)
        let first = asked.count
        store.handleFileSystemEvent(.init(everything: true))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertGreaterThan(first, 0)
        XCTAssertEqual(asked.count, first, "swept again inside the interval")

        clock.advance(by: 31)
        store.handleFileSystemEvent(.init(everything: true))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(asked.count, first * 2)
    }
}

/// The daily note's watcher and its conflict check.
@MainActor final class DailyNoteWatchTests: XCTestCase {
    private var vault: URL!
    private var isolated: IsolatedSettings!
    private var clock: ManualClock!
    private var scheduler: TestScheduler!

    override func setUp() async throws {
        NoteStore.systemComputerName = "This Mac"
        isolated = IsolatedSettings()
        clock = ManualClock()
        scheduler = TestScheduler(clock: clock)
        vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyWatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        isolated.settings.obsidianVaultPath = vault.path
        isolated.settings.dailyNotesPattern = "{YYYY}-{MM}-{DD}.md"
        isolated.settings.dailyTemplatePath = nil
    }

    override func tearDown() async throws {
        isolated.tearDown()
        try? FileManager.default.removeItem(at: vault)
    }

    // MARK: - Which events it hears

    func testOnlyTodaysFileItsPlaceholderAndItsNumberedCopiesAreHeard() {
        let today = vault.appendingPathComponent("2026-11-15.md")
        let accepts = DailyNote.watchFilter(for: today)

        XCTAssertTrue(accepts(today.path))
        XCTAssertTrue(accepts(vault.appendingPathComponent("2026-11-15 2.md").path))
        XCTAssertTrue(accepts(vault.appendingPathComponent(".2026-11-15.md.icloud").path))
        XCTAssertFalse(accepts(vault.appendingPathComponent("2026-11-14.md").path), "yesterday's note")
        XCTAssertFalse(accepts(vault.appendingPathComponent("2026-11-15 1.md").path), "a name somebody chose")
        XCTAssertFalse(accepts(vault.appendingPathComponent("Groceries.md").path))
        XCTAssertFalse(accepts(vault.appendingPathComponent("2026-11-15 2.png").path))
    }

    func testNothingBelowTheFolderIsHeardEvenWithTheSameName() {
        let today = vault.appendingPathComponent("2026-11-15.md")
        let accepts = DailyNote.watchFilter(for: today)

        XCTAssertFalse(accepts(vault.appendingPathComponent("StickyNotes/notes/2026-11-15.md").path))
        XCTAssertFalse(accepts(vault.appendingPathComponent(".obsidian/workspace.json").path))
        XCTAssertFalse(accepts(vault.appendingPathComponent("StickyNotes/notes/2026-11-15 2.md").path))
    }

    func testAPathThroughASymbolicLinkIsTheSameFolder() throws {
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("DailyWatchLink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: vault)
        defer { try? FileManager.default.removeItem(at: link) }
        let accepts = DailyNote.watchFilter(for: link.appendingPathComponent("2026-11-15.md"))

        XCTAssertTrue(accepts(vault.appendingPathComponent("2026-11-15.md").resolvingSymlinksInPath().path))
    }

    // MARK: - The conflict check

    private func makeDocument(provider: @escaping (URL) -> [NoteStore.ConflictVersionHandle]) -> DailyDocument {
        let document = DailyDocument(settings: isolated.settings, clock: clock, scheduler: scheduler)
        document.offMain = .inline
        document.conflictVersionsProvider = provider
        document.otherVersionsRemover = { _ in }
        return document
    }

    private func writeToday(_ text: String) throws {
        let url = try XCTUnwrap(DailyNote.resolvedURL(for: clock.now(), settings: isolated.settings))
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testTheConflictCheckIsAskedOncePerIntervalAndTheLaterChangeIsCheckedWhenItIsUp() throws {
        try writeToday("text")
        let asked = Tally()
        let document = makeDocument { _ in asked.record(); return [] }
        document.load()
        XCTAssertEqual(asked.count, 1, "the load checks")

        document.storeDidChange()
        document.storeDidChange()
        XCTAssertEqual(asked.count, 1, "asked again inside the interval")

        scheduler.advance(by: DailyDocument.conflictCheckInterval + 0.1)
        XCTAssertEqual(asked.count, 2, "the change that came inside the interval was never checked")
        XCTAssertEqual(asked.count, 2)
        scheduler.advance(by: DailyDocument.conflictCheckInterval * 3)
        XCTAssertEqual(asked.count, 2, "a check was armed with nothing waiting for it")
    }

    func testTheMainThreadDoesNotWaitForASlowConflictQuery() async throws {
        try writeToday("text")
        let asked = Tally()
        let document = DailyDocument(settings: isolated.settings, clock: clock, scheduler: scheduler)
        document.conflictVersionsProvider = { _ in
            dispatchPrecondition(condition: .notOnQueue(.main))
            asked.record()
            Thread.sleep(forTimeInterval: 0.4)
            return []
        }

        let began = CFAbsoluteTimeGetCurrent()
        document.load()
        document.storeDidChange()
        let returned = CFAbsoluteTimeGetCurrent() - began

        XCTAssertLessThan(returned, 0.2, "the main thread waited for the conflict query")
        XCTAssertEqual(document.body, "text")
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.countOffMain, 1)
    }
}

/// What the prefetcher asks for, and what it reports.
final class ICloudPrefetchTrackerTests: XCTestCase {
    private let root = "/Users/me/Library/Mobile Documents/vault/StickyNotes"

    private func url(_ relative: String) -> URL { URL(fileURLWithPath: root + "/" + relative) }

    func testEachFileIsAskedForOnce() {
        let tracker = ICloudPrefetcher.Tracker()
        let items = [(url: url("notes/a.md"), isCurrent: false)]

        XCTAssertEqual(tracker.look(at: items, under: root).toRequest, [url("notes/a.md")])
        XCTAssertEqual(tracker.look(at: items, under: root).toRequest, [], "asked for again while the download runs")
    }

    func testAFileIsReportedOnlyWhenItsDownloadHasFinished() {
        let tracker = ICloudPrefetcher.Tracker()
        let file = url("notes/a.md")

        XCTAssertEqual(tracker.look(at: [(file, false)], under: root).arrived, [])
        XCTAssertEqual(tracker.look(at: [(file, true)], under: root).arrived, [file])
        XCTAssertEqual(tracker.look(at: [(file, true)], under: root).arrived, [], "reported twice")
    }

    func testAFileThatWasAlreadyHereIsNeverReported() {
        let tracker = ICloudPrefetcher.Tracker()
        XCTAssertEqual(tracker.look(at: [(url("notes/a.md"), true)], under: root), .init())
    }

    func testAFileThatLeavesAndComesBackIsAskedForAgain() {
        let tracker = ICloudPrefetcher.Tracker()
        let file = url("notes/a.md")
        _ = tracker.look(at: [(file, false)], under: root)
        _ = tracker.look(at: [(file, true)], under: root)

        XCTAssertEqual(tracker.look(at: [(file, false)], under: root).toRequest, [file])
    }

    func testTheTrashAndTheAttachmentsAreLeftAlone() {
        let tracker = ICloudPrefetcher.Tracker()
        let items = [
            (url: url(".trash/old.md"), isCurrent: false),
            (url: url("\(Attachments.directoryName)/photo.png"), isCurrent: false),
            (url: url("archive/kept.md"), isCurrent: false),
        ]

        XCTAssertEqual(tracker.look(at: items, under: root).toRequest, [url("archive/kept.md")])
    }
}
