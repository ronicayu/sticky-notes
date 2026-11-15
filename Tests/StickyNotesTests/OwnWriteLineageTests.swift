import XCTest
@testable import StickyNotesKit

/// What this Mac remembers of its own writes to a note's file, and what that
/// lets a merge drop: an older copy of the person's own text that Obsidian puts
/// back, or that iCloud keeps as a conflict version, is not someone else's text.
/// Text that exists nowhere else is never dropped on that evidence.
final class OwnWriteLineageTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var clock: ManualClock!
    private var scheduler: TestScheduler!
    private var lineageFile: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwnWriteLineage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        lineageFile = root.appendingPathComponent("machine/write-lineage.json")
        clock = ManualClock()
        scheduler = TestScheduler(clock: clock)
        store = NoteStore(rootURL: root.appendingPathComponent("notes"), clock: clock, scheduler: scheduler)
    }

    override func tearDownWithError() throws {
        WriteLineage.reset()
        store?.stopWatching()
        for folder in [store.activeURL] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Harness

    private func makeNote(_ content: String) -> Note {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200), now: clock.now())
        note.content = content
        return note
    }

    private func raw(_ id: UUID, _ body: String, updated: String = "2030-01-01T00:00:00Z") -> String {
        "---\nid: \(id.uuidString)\nupdated: \(updated)\n---\n\(body)\n"
    }

    private func activeFile(in store: NoteStore? = nil) throws -> URL {
        let folder = (store ?? self.store).activeURL
        return try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "md" })
    }

    /// What Obsidian does: rewrite the file behind the store's back.
    private func writeOutside(_ id: UUID, _ body: String) throws {
        try raw(id, body).write(to: activeFile(), atomically: true, encoding: .utf8)
    }

    private func version(_ id: UUID, _ body: String, resolved: @escaping () -> Void = {}) throws -> NoteStore.ConflictVersionHandle {
        let url = root.appendingPathComponent("version-\(UUID().uuidString).md")
        try raw(id, body, updated: "1970-01-01T00:00:01Z").write(to: url, atomically: true, encoding: .utf8)
        return .init(url: url, markResolved: resolved)
    }

    private func body(of note: Note) -> String {
        note.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func onDisk(_ id: UUID) throws -> String {
        body(of: try XCTUnwrap(store.snapshot(id: id)?.note))
    }

    private func open(_ note: Note) -> NoteDocument {
        store.save(note)
        return NoteDocument(note: note, repository: store, scheduler: scheduler, clock: clock)
    }

    private func count(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: - N1: Obsidian puts back an older copy of the person's own text

    func testAnOutsideRewriteBackToAnOlderOwnCopyIsNotAppendedAsAConflict() throws {
        let document = open(makeNote("first line"))
        document.edit { $0.content = "first line\nsecond line" }
        scheduler.advance(by: 1)
        document.edit { $0.content = "better first line\nsecond line" }
        try writeOutside(document.id, "first line")
        document.storeDidChange()

        scheduler.advance(by: 1)

        let saved = try onDisk(document.id)
        XCTAssertEqual(saved, "better first line\nsecond line")
        XCTAssertEqual(count(of: "Conflicted copy", in: saved), 0)
        XCTAssertEqual(body(of: document.buffer), "better first line\nsecond line")
    }

    /// A merge the store wrote holds the other Mac's text and is recorded as a
    /// write of ours. When the window then hears that file while the person has
    /// typed on, it is the file's current text, not an older copy of the person's
    /// own, so the other Mac's line must survive.
    func testTheOtherMacsTextInAMergeWeWroteIsNotTakenForAnOlderCopyOfOurOwnText() throws {
        let document = open(makeNote("shared line"))
        let other = try version(document.id, "shared line\nfrom the other Mac")
        store.conflictVersionsProvider = { _ in [other] }
        store.otherVersionsRemover = { _ in }
        document.isEditing = { true }
        XCTAssertEqual(store.resolveConflicts(), 1)
        document.storeDidChange()
        XCTAssertNotNil(document.pendingExternal, "the window was meant to hold the merged file back")
        document.edit { $0.content = "shared line\ntyped here" }

        document.blur()

        let saved = try onDisk(document.id)
        XCTAssertTrue(saved.contains("from the other Mac") && saved.contains("typed here"), saved)
    }

    func testAnOutsideRewriteWithALineNoWriteOfOursHadIsStillMerged() throws {
        let document = open(makeNote("first line"))
        document.edit { $0.content = "first line\nsecond line" }
        scheduler.advance(by: 1)
        document.edit { $0.content = "better first line\nsecond line" }
        try writeOutside(document.id, "first line\nwritten in Obsidian")
        document.storeDidChange()

        scheduler.advance(by: 1)

        let saved = try onDisk(document.id)
        XCTAssertTrue(saved.contains("written in Obsidian"), saved)
        XCTAssertTrue(saved.contains("better first line"), saved)
    }

    // MARK: - N5 and N4: the lineage survives outside writes

    private func savedWithATypoFixed() throws -> (note: Note, older: NoteStore.ConflictVersionHandle) {
        var note = makeNote("teh cat\nsat down")
        store.save(note)
        let older = try version(note.id, "teh cat\nsat down")
        note.content = "the cat\nsat down"
        store.save(note)
        return (note, older)
    }

    func testAnOlderOwnSaveIsDroppedAfterAnOutsideAppend() throws {
        let (note, older) = try savedWithATypoFixed()
        try writeOutside(note.id, "the cat\nsat down\nadded in Obsidian")
        var resolved = 0
        store.conflictVersionsProvider = { _ in [.init(url: older.url, markResolved: { resolved += 1 })] }
        store.otherVersionsRemover = { _ in }

        XCTAssertEqual(store.resolveConflicts(), 0)

        XCTAssertEqual(resolved, 1)
        let content = try onDisk(note.id)
        XCTAssertFalse(content.contains("teh cat"), content)
        XCTAssertEqual(count(of: "Conflicted copy", in: content), 0)
    }

    func testAnEarlierOwnSaveIsKeptWhenAnOutsideWriteTookItsLinesOut() throws {
        let (note, older) = try savedWithATypoFixed()
        try writeOutside(note.id, "something else entirely")
        store.conflictVersionsProvider = { _ in [older] }
        store.otherVersionsRemover = { _ in }
        _ = store.loadActive()

        XCTAssertEqual(store.resolveConflicts(), 1)

        let content = try onDisk(note.id)
        XCTAssertTrue(content.contains("teh cat") && content.contains("something else entirely"), content)
    }

    /// Obsidian put back an older copy of our own text, and iCloud kept another
    /// earlier save of ours as a conflict version. Our newest text is what the
    /// note stands for: the older save is dropped, and the newest text is written
    /// back over the stale copy, with no divider.
    func testAnOlderOwnSaveIsDroppedWhenAnEarlierOwnCopyWasPutBack() throws {
        var note = makeNote("a line")
        store.save(note)
        note.content = "a line\nsecond line"
        store.save(note)
        let older = try version(note.id, "a line\nsecond line")
        note.content = "better line\nsecond line"
        store.save(note)
        try writeOutside(note.id, "a line")
        var resolved = 0
        store.conflictVersionsProvider = { _ in [.init(url: older.url, markResolved: { resolved += 1 })] }
        store.otherVersionsRemover = { _ in }

        XCTAssertEqual(store.resolveConflicts(), 1)

        XCTAssertEqual(resolved, 1)
        XCTAssertEqual(try onDisk(note.id), "better line\nsecond line")
    }

    /// The same with the window open on the note: it holds back Obsidian's older
    /// copy while the caret is in the text, and its newest text is not on disk.
    func testTheSweepKeepsTheWindowsNewestTextWhenAnEarlierOwnCopyWasPutBack() throws {
        let document = open(makeNote("a line"))
        document.edit { $0.content = "a line\nsecond line" }
        scheduler.advance(by: 1)
        let older = try version(document.id, "a line\nsecond line")
        document.edit { $0.content = "better line\nsecond line" }
        scheduler.advance(by: 1)
        document.isEditing = { true }
        try writeOutside(document.id, "a line")
        document.storeDidChange()
        XCTAssertNotNil(document.pendingExternal)
        store.beforeResolvingConflicts = { _ in document.flush() }
        store.conflictVersionsProvider = { _ in [older] }
        store.otherVersionsRemover = { _ in }

        _ = store.resolveConflicts()
        document.storeDidChange()
        scheduler.advance(by: 1)

        let saved = try onDisk(document.id)
        XCTAssertEqual(saved, "better line\nsecond line")
        XCTAssertEqual(body(of: document.buffer), "better line\nsecond line")
    }

    func testAnOlderOwnSaveIsStillDroppedAfterAnOutsideWriteAndAfterARelaunch() throws {
        WriteLineage.useFile(lineageFile)
        let (note, older) = try savedWithATypoFixed()
        WriteLineage.saveNow()

        // Quit and relaunch: nothing in memory, and the file is what is left.
        store.stopWatching()
        WriteLineage.reset()
        WriteLineage.useFile(lineageFile)
        let relaunched = NoteStore(rootURL: root.appendingPathComponent("notes"), clock: clock, scheduler: scheduler)
        defer { relaunched.stopWatching() }
        try writeOutside(note.id, "the cat\nsat down\nadded in Obsidian")
        relaunched.conflictVersionsProvider = { _ in [older] }
        relaunched.otherVersionsRemover = { _ in }

        XCTAssertEqual(relaunched.resolveConflicts(), 0)

        let content = try XCTUnwrap(relaunched.snapshot(id: note.id)?.note.content)
        XCTAssertFalse(content.contains("teh cat"), content)
        XCTAssertTrue(content.contains("added in Obsidian"), content)
    }

    func testAnOlderOwnSaveIsMergedAfterARelaunchWhenNothingWasSaved() throws {
        let (note, older) = try savedWithATypoFixed()
        store.stopWatching()
        WriteLineage.reset()
        let relaunched = NoteStore(rootURL: root.appendingPathComponent("notes"), clock: clock, scheduler: scheduler)
        defer { relaunched.stopWatching() }
        relaunched.conflictVersionsProvider = { _ in [older] }
        relaunched.otherVersionsRemover = { _ in }

        XCTAssertEqual(relaunched.resolveConflicts(), 1)

        XCTAssertTrue(try XCTUnwrap(relaunched.snapshot(id: note.id)?.note.content).contains("teh cat"))
    }

    func testTheSavedLineageIsBoundedAndIsKeptApartFromTheStorageRoots() throws {
        WriteLineage.useFile(lineageFile)
        for file in 0..<(WriteLineage.savedFiles + 20) {
            for write in 0..<3 { WriteLineage.record(body: "file \(file) write \(write)", for: "key-\(file)") }
        }
        for write in 0..<(WriteLineage.savedWritesPerFile + 30) {
            WriteLineage.record(body: "long \(write)", for: "long-history")
        }
        WriteLineage.saveNow()

        WriteLineage.reset()
        WriteLineage.useFile(lineageFile)

        XCTAssertTrue(WriteLineage.history(for: "key-0").entries.isEmpty, "the oldest file was kept")
        let newest = WriteLineage.history(for: "long-history")
        XCTAssertEqual(newest.entries.count, WriteLineage.savedWritesPerFile)
        XCTAssertEqual(newest.newestBody, "long \(WriteLineage.savedWritesPerFile + 29)")
        let saved = try Data(contentsOf: lineageFile)
        let files = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])["files"] as? [String: Any]
        XCTAssertLessThanOrEqual(files?.count ?? 0, WriteLineage.savedFiles)

        let isolated = IsolatedSettings()
        defer { isolated.tearDown() }
        let settings = isolated.settings
        XCTAssertEqual(settings.writeLineageURL.deletingLastPathComponent(), settings.machineFilesFolder)
        settings.obsidianVaultPath = root.appendingPathComponent("vault").path
        XCTAssertNotEqual(settings.writeLineageURL.deletingLastPathComponent(), settings.preferredStorageRoot)
        XCTAssertFalse(settings.writeLineageURL.path.hasPrefix(settings.preferredStorageRoot.path))
    }

    func testAnUnreadableLineageFileIsIgnored() throws {
        try FileManager.default.createDirectory(at: lineageFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xff, 0x00, 0x7b]).write(to: lineageFile)

        WriteLineage.useFile(lineageFile)

        XCTAssertTrue(WriteLineage.history(for: "anything").entries.isEmpty)
    }

    // MARK: - Soundness: text that exists nowhere else is never dropped

    /// The other Mac replaced the file and the window took its text over, so the
    /// older own save holds a line that only it has, though a later write of ours
    /// is the file now.
    func testAnEarlierOwnSaveIsKeptWhenTheWindowTookOverTextThatLeftItsLineOut() throws {
        let note = makeNote("mine")
        store.save(note)
        let document = NoteDocument(note: note, repository: store, scheduler: scheduler, clock: clock)
        let own = try version(note.id, "mine")
        try writeOutside(note.id, "theirs")
        document.storeDidChange()
        XCTAssertEqual(body(of: document.buffer), "theirs")
        document.edit { $0.content = "theirs\nmoved on" }
        scheduler.advance(by: 1)
        store.conflictVersionsProvider = { _ in [own] }
        store.otherVersionsRemover = { _ in }

        XCTAssertEqual(store.resolveConflicts(), 1)

        let content = try onDisk(note.id)
        XCTAssertTrue(content.contains("mine") && content.contains("theirs"), content)
    }

    func testAnOlderOwnBodyAsTheFileNeverLetsANewerOwnSaveBeDropped() throws {
        var note = makeNote("A")
        store.save(note)
        note.content = "A\nnew line"
        store.save(note)
        let newer = try version(note.id, "A\nnew line")
        try writeOutside(note.id, "A")
        store.conflictVersionsProvider = { _ in [newer] }
        store.otherVersionsRemover = { _ in }

        XCTAssertEqual(store.resolveConflicts(), 1)

        XCTAssertTrue(try onDisk(note.id).contains("new line"))
    }

    // MARK: - N2: a blank file takes the conflict version

    func testABlankCurrentFileTakesAConflictVersionWithoutADivider() throws {
        let note = makeNote("")
        store.save(note)
        store.conflictVersionsProvider = { [self] _ in [try! version(note.id, "from the other Mac\nsecond line")] }
        store.otherVersionsRemover = { _ in }

        XCTAssertEqual(store.resolveConflicts(), 1)

        XCTAssertEqual(try onDisk(note.id), "from the other Mac\nsecond line")
    }

    // MARK: - N6: a merge that could not be written is tried again

    func testAConflictMergeThatCouldNotBeWrittenIsRetried() throws {
        let note = makeNote("this Mac")
        store.save(note)
        var resolved = 0
        let other = try version(note.id, "the other Mac") { resolved += 1 }
        store.conflictVersionsProvider = { _ in resolved == 0 ? [other] : [] }
        store.otherVersionsRemover = { _ in }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.activeURL.path)

        XCTAssertEqual(store.resolveConflicts(), 0, "the write was meant to fail")
        XCTAssertEqual(resolved, 0, "the version was resolved though its text was not written")

        scheduler.advance(by: NoteDocument.retryDelay)
        XCTAssertEqual(resolved, 0, "the retry cannot succeed while the disk refuses")
        scheduler.advance(by: NoteDocument.retryDelay)
        XCTAssertEqual(resolved, 0, "the second retry came after the first delay, not after a doubled one")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.activeURL.path)
        scheduler.advance(by: NoteDocument.retryDelay * 2)

        XCTAssertEqual(resolved, 1)
        let content = try onDisk(note.id)
        XCTAssertTrue(content.contains("this Mac") && content.contains("the other Mac"), content)
    }

    func testAConflictMergeThatWaitedOnAWindowsTextIsRetried() throws {
        let note = makeNote("this Mac")
        store.save(note)
        var resolved = 0
        let other = try version(note.id, "the other Mac") { resolved += 1 }
        store.conflictVersionsProvider = { _ in resolved == 0 ? [other] : [] }
        store.otherVersionsRemover = { _ in }
        var windowCanWrite = false
        store.beforeResolvingConflicts = { _ in windowCanWrite }

        XCTAssertEqual(store.resolveConflicts(), 0)
        windowCanWrite = true
        scheduler.advance(by: NoteDocument.retryDelay)

        XCTAssertEqual(resolved, 1)
    }
}
