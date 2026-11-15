import XCTest
@testable import StickyNotesKit

/// A note's file is archived, deleted or unreachable while its document holds
/// typing that is on no disk, and a new note that has no file yet. A real
/// `NoteDocument` over a real `NoteStore`, with time moved by hand.
final class NoteLeavesActiveFolderTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var clock: ManualClock!
    private var scheduler: TestScheduler!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeavesActive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clock = ManualClock()
        scheduler = TestScheduler(clock: clock)
        store = NoteStore(rootURL: root, clock: clock)
    }

    override func tearDownWithError() throws {
        for folder in [store.activeURL, store.archiveURL, store.trashURL] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Harness

    private func makeNote(_ content: String = "", title: String = "Note") -> Note {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200), now: clock.now())
        note.title = title
        note.content = content
        return note
    }

    /// A saved note and a document over it.
    private func open(_ content: String = "") -> NoteDocument {
        let note = makeNote(content)
        store.save(note)
        return NoteDocument(note: note, repository: store, scheduler: scheduler, clock: clock)
    }

    private func files(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
    }

    private func archivedText(_ document: NoteDocument) throws -> String {
        try XCTUnwrap(store.loadArchived().first { $0.id == document.id }, "not in the archive").content
    }

    private func setPermissions(_ mode: Int, on folder: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: folder.path)
    }

    // MARK: - A note archived, deleted or moved under typing (F5)

    /// The other Mac archives the note. The save that was armed used to find the
    /// file gone, count as done, and drop the typing.
    func testANoteArchivedElsewhereKeepsTheLastTyping() throws {
        let document = open("first")
        var kept: [NoteDocument.KeptIn] = []
        document.didKeepText = { kept.append($0) }
        document.setBody("first, and typed after it was archived")
        store.archive(document.buffer)

        XCTAssertTrue(document.flush())

        XCTAssertEqual(try archivedText(document), "first, and typed after it was archived")
        XCTAssertNil(store.loadNote(id: document.id), "the note was written back into notes/")
        XCTAssertFalse(document.hasUnsavedEdits)
        XCTAssertEqual(kept, [.archive])
        XCTAssertTrue(store.loadTrashed().isEmpty)
    }

    /// The other Mac also edited the note before it archived it: both survive.
    func testATextArchivedElsewhereAfterItsOwnEditKeepsBothEdits() throws {
        let document = open("milk")
        var other = document.buffer
        other.content = "milk\neggs"
        other.updatedAt = clock.now().addingTimeInterval(5)
        store.save(other)
        store.archive(other)
        document.setBody("milk\nbread")

        XCTAssertTrue(document.flush())

        let text = try archivedText(document)
        XCTAssertTrue(text.contains("eggs") && text.contains("bread"), text)
    }

    func testANoteDeletedFromTheArchiveToTheTrashKeepsTheLastTypingThere() throws {
        let document = open("first")
        document.setBody("first and more")
        store.archive(document.buffer)
        store.deleteForever(document.buffer)
        var kept: [NoteDocument.KeptIn] = []
        document.didKeepText = { kept.append($0) }

        XCTAssertTrue(document.flush())

        XCTAssertEqual(store.loadTrashed().first { $0.id == document.id }?.content, "first and more")
        XCTAssertEqual(kept, [.trash])
        XCTAssertNil(store.loadNote(id: document.id))
    }

    /// The file is nowhere: an agent processed it, or another app removed it. The
    /// typing goes to a copy in the trash and the note stays gone.
    func testANoteRemovedEverywhereKeepsTheLastTypingInARecoveredCopy() throws {
        let document = open("first")
        var kept: [NoteDocument.KeptIn] = []
        document.didKeepText = { kept.append($0) }
        document.setBody("first and typed after the agent removed it")
        try FileManager.default.removeItem(at: XCTUnwrap(files(in: store.activeURL).first))

        XCTAssertTrue(document.flush())

        let copy = try XCTUnwrap(store.loadTrashed().first)
        XCTAssertEqual(copy.content, "first and typed after the agent removed it")
        XCTAssertEqual(kept, [.recoveredCopy])
        XCTAssertNil(store.loadNote(id: document.id), "the note was resurrected")
        XCTAssertFalse(document.hasUnsavedEdits)
    }

    func testKeepingTheTextAgainAfterMoreTypingRewritesTheSameRecoveredCopy() throws {
        let document = open("first")
        try FileManager.default.removeItem(at: XCTUnwrap(files(in: store.activeURL).first))
        document.setBody("one")
        document.flush()
        document.setBody("one two")
        document.flush()

        let copies = store.loadTrashed()
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(copies.first?.content, "one two")
    }

    /// The window was closed after the other Mac archived the note: the close
    /// found no file to move, and archived the buffer's text nowhere. There is
    /// nothing to undo, because the note was already archived.
    func testClosingANoteThatWasArchivedElsewhereKeepsTheTyping() throws {
        let document = open("first")
        document.setBody("first and a late thought")
        store.archive(document.buffer)

        guard case let .closed(archived) = document.close(.archive) else { return XCTFail("refused") }

        XCTAssertNil(archived, "offered to undo an archive that was somebody else's")
        XCTAssertEqual(try archivedText(document), "first and a late thought")
        XCTAssertNil(store.loadNote(id: document.id))
    }

    func testClosingBecauseTheFileWentWritesTheTypingFirst() throws {
        let document = open("first")
        document.setBody("first and more")
        store.archive(document.buffer)

        guard case .closed = document.close(.externalDeletion) else { return XCTFail("refused") }

        XCTAssertEqual(try archivedText(document), "first and more")
    }

    func testClosingBecauseTheFileWentWithNothingTypedWritesNothing() throws {
        let document = open("first")
        document.adjust { $0.positionX = 99 }
        store.archive(document.buffer)
        let before = try files(in: store.archiveURL).map { try Data(contentsOf: $0) }

        guard case .closed = document.close(.externalDeletion) else { return XCTFail("refused") }

        XCTAssertEqual(try files(in: store.archiveURL).map { try Data(contentsOf: $0) }, before)
        XCTAssertTrue(store.loadTrashed().isEmpty)
    }

    /// Nowhere to put the text: the window has to stay open with it.
    func testClosingBecauseTheFileWentIsRefusedWhileTheTextCannotBeWritten() throws {
        let document = open("first")
        document.setBody("first and more")
        store.archive(document.buffer)
        try setPermissions(0o555, on: store.archiveURL)

        guard case .refused = document.close(.externalDeletion) else { return XCTFail("closed with the text nowhere") }
        XCTAssertTrue(document.hasUnsavedEdits)
        XCTAssertEqual(scheduler.pendingCount, 1, "no retry is armed")

        try setPermissions(0o755, on: store.archiveURL)
        guard case .closed = document.close(.externalDeletion) else { return XCTFail("still refused") }
        XCTAssertEqual(try archivedText(document), "first and more")
    }

    // MARK: - A folder that cannot be listed is not a deletion (R3)

    func testAFolderThatCannotBeListedKeepsTheTypingDirtyAndRetries() throws {
        let document = open("first")
        document.setBody("first and more")
        try setPermissions(0o000, on: store.activeURL)
        store.handleFileSystemEvent()

        XCTAssertFalse(document.flush(), "the text was marked saved without a write")
        XCTAssertTrue(document.hasUnsavedEdits)
        XCTAssertTrue(store.loadTrashed().isEmpty, "a recovered copy was made of a note that still exists")
        XCTAssertEqual(scheduler.pendingCount, 1, "no retry is armed")

        try setPermissions(0o755, on: store.activeURL)
        scheduler.advance(by: NoteDocument.retryDelay + 0.1)
        XCTAssertEqual(store.loadNote(id: document.id)?.content, "first and more")
        XCTAssertFalse(document.hasUnsavedEdits)
    }

    func testClosingWhileTheFolderCannotBeListedIsRefused() throws {
        let document = open("first")
        document.setBody("first and more")
        try setPermissions(0o000, on: store.activeURL)
        store.handleFileSystemEvent()

        guard case .refused = document.close(.archive) else { return XCTFail("closed with unsaved text") }
        guard case .refused = document.close(.externalDeletion) else { return XCTFail("closed with unsaved text") }
        XCTAssertEqual(document.buffer.content, "first and more")
    }

    // MARK: - A new note starts unsaved (R10)

    private func newDocument(_ content: String = "") -> NoteDocument {
        let document = NoteDocument(note: makeNote(content, title: ""), repository: store, scheduler: scheduler, clock: clock)
        document.createsFileOnFirstEdit = true
        return document
    }

    func testANewNoteHasNoFileUntilItIsTypedInto() throws {
        let document = newDocument()
        XCTAssertFalse(document.hasFile)

        document.adjust { $0.positionX = 40 }
        document.requestSave()
        scheduler.advance(by: 10)
        XCTAssertTrue(document.flush(), "nothing is owed")

        XCTAssertTrue(try files(in: store.activeURL).isEmpty, "an untouched new note was written")
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testTheFirstEditOfANewNoteWritesItWithWhereItSits() throws {
        let document = newDocument()
        document.adjust { $0.positionX = 40 }
        scheduler.advance(by: 1)
        document.setBody("x")
        XCTAssertTrue(try files(in: store.activeURL).isEmpty, "written before the debounce")

        scheduler.advance(by: 0.6)

        let written = try XCTUnwrap(store.loadNote(id: document.id))
        XCTAssertEqual(written.content, "x")
        XCTAssertEqual(written.positionX, 40)
        XCTAssertTrue(document.hasFile)
    }

    func testAbandoningANewNoteTouchesNoFile() throws {
        let document = newDocument()
        document.adjust { $0.positionX = 40 }
        XCTAssertTrue(document.isAbandonedCapture)

        guard case .closed = document.close(.discard) else { return XCTFail("refused") }

        XCTAssertTrue(try files(in: store.activeURL).isEmpty)
        XCTAssertTrue(try files(in: store.trashURL).isEmpty, "a file that never existed was trashed")
        XCTAssertTrue(store.loadArchived().isEmpty)
    }

    func testClosingANewNoteTypedIntoAndEmptiedAgainBeforeTheFirstSaveWritesNothing() throws {
        let document = newDocument()
        document.setBody("x")
        document.setBody("")

        guard case .closed = document.close(.archive) else { return XCTFail("refused") }

        XCTAssertTrue(try files(in: store.activeURL).isEmpty)
        XCTAssertTrue(try files(in: store.trashURL).isEmpty)
    }

    func testANewNoteThatWasTypedIntoIsArchivedWithItsText() throws {
        let document = newDocument()
        document.setBody("words")

        guard case let .closed(archived) = document.close(.archive) else { return XCTFail("refused") }

        XCTAssertEqual(archived?.content, "words")
        XCTAssertEqual(try archivedText(document), "words")
    }

    // MARK: - Discarding an empty note that has a file (F3)

    /// "Empty" is judged from the window, and the file may hold more than it
    /// shows, so an empty note's file is never unlinked. (Model finding F3.)
    func testDiscardingAnEmptyNoteGoesToTheTrash() throws {
        let document = open("")
        document.setBody("x")
        document.setBody("")
        document.setTitle("")

        guard case .closed = document.close(.discard) else { return XCTFail("refused") }

        XCTAssertNil(store.loadNote(id: document.id))
        XCTAssertEqual(store.loadTrashed().map(\.id), [document.id])
        XCTAssertTrue(store.loadArchived().isEmpty)
    }

    func testClosingAnEmptyNoteThatHasAFileLeavesItInTheTrashToo() throws {
        let document = open("")
        document.setBody("x")
        document.setBody("")
        document.setTitle("")

        guard case .closed = document.close(.archive) else { return XCTFail("refused") }

        XCTAssertEqual(store.loadTrashed().map(\.id), [document.id])
        XCTAssertTrue(store.loadArchived().isEmpty)
    }
}
