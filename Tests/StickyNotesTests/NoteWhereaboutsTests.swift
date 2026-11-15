import XCTest
@testable import StickyNotesKit

/// What the store can and cannot say about a note whose file is not where it was
/// last seen: gone, moved to another folder, or only unreachable right now.
final class NoteWhereaboutsTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var clock: ManualClock!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Whereabouts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clock = ManualClock()
        store = NoteStore(rootURL: root, clock: clock)
    }

    override func tearDownWithError() throws {
        store?.stopWatching()
        for folder in [store.activeURL, store.archiveURL, store.trashURL] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func makeNote(_ content: String) -> Note {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200), now: clock.now())
        note.content = content
        return note
    }

    private func files(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
    }

    // MARK: - Listing

    func testAnEmptyFolderIsListedAsEmptyAndAnUnreadableOneIsNot() throws {
        store.save(makeNote("one"))
        XCTAssertEqual(store.listActive()?.count, 1)
        for file in try files(in: store.activeURL) { try FileManager.default.removeItem(at: file) }
        store.handleFileSystemEvent()
        XCTAssertEqual(store.listActive()?.count, 0, "an empty folder is a listing")

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.activeURL.path)
        store.handleFileSystemEvent()
        XCTAssertNil(store.listActive(), "a folder that cannot be read was reported as empty")
        XCTAssertEqual(store.loadActive().count, 0)
    }

    // MARK: - Saving

    /// (Model finding F5: a listing that fails is not a deletion.)
    func testASaveThatCannotListTheFolderIsNotGone() throws {
        let note = makeNote("on disk")
        let fingerprint = try savedFingerprint(of: note)
        let file = try XCTUnwrap(files(in: store.activeURL).first)
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("hidden.md"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.activeURL.path)
        store.handleFileSystemEvent()

        switch store.save(note, expecting: fingerprint) {
        case .failed: break
        default: XCTFail("a folder that could not be read was taken as the note being deleted")
        }
    }

    func testASaveOfANoteWhoseFileIsReallyGoneIsGone() throws {
        let note = makeNote("on disk")
        let fingerprint = try savedFingerprint(of: note)
        try FileManager.default.removeItem(at: XCTUnwrap(files(in: store.activeURL).first))
        store.handleFileSystemEvent()

        guard case .gone = store.save(note, expecting: fingerprint) else { return XCTFail("not gone") }
    }

    func testANoteWaitingInICloudIsNotGone() throws {
        let note = makeNote("on disk")
        let fingerprint = try savedFingerprint(of: note)
        let file = try XCTUnwrap(files(in: store.activeURL).first)
        let placeholder = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).icloud")
        try FileManager.default.moveItem(at: file, to: placeholder)
        store.handleFileSystemEvent()

        switch store.save(note, expecting: fingerprint) {
        case .failed: break
        default: XCTFail("a file still in iCloud was taken as deleted")
        }
        guard case .unknown = store.whereIs(id: note.id) else { return XCTFail("expected unknown") }
    }

    private func savedFingerprint(of note: Note) throws -> Fingerprint {
        guard case let .saved(fingerprint) = store.save(note, expecting: nil) else {
            throw XCTSkip("the note was not written")
        }
        return fingerprint
    }

    // MARK: - Where a note went

    func testALookupFindsTheFolderAMovedNoteIsIn() throws {
        let archived = makeNote("archived"), trashed = makeNote("trashed"), active = makeNote("active")
        for note in [archived, trashed, active] { store.save(note) }
        store.archive(archived)
        store.archive(trashed)
        store.deleteForever(trashed)

        guard case let .archived(a) = store.whereIs(id: archived.id) else { return XCTFail("not in the archive") }
        XCTAssertEqual(a.note.content, "archived")
        guard case let .trashed(t) = store.whereIs(id: trashed.id) else { return XCTFail("not in the trash") }
        XCTAssertEqual(t.note.content, "trashed")
        guard case .active = store.whereIs(id: active.id) else { return XCTFail("not active") }
        guard case .missing = store.whereIs(id: UUID()) else { return XCTFail("an unknown id was not missing") }
    }

    func testTextIsSavedIntoTheArchiveOnlyOverTheFileItWasReadFrom() throws {
        let note = makeNote("first")
        store.save(note)
        store.archive(note)
        guard case let .archived(snapshot) = store.whereIs(id: note.id) else { return XCTFail("not archived") }

        var typed = note
        typed.content = "first, then typing"
        guard case .saved = store.save(typed, in: .archive, expecting: snapshot.fingerprint) else {
            return XCTFail("not saved")
        }
        XCTAssertEqual(store.loadArchived().first?.content, "first, then typing")

        var again = note
        again.content = "written over an unseen version"
        guard case .conflict = store.save(again, in: .archive, expecting: snapshot.fingerprint) else {
            return XCTFail("overwrote a file it had not read")
        }
        XCTAssertEqual(store.loadArchived().first?.content, "first, then typing")
        XCTAssertTrue(store.loadActive().isEmpty, "saving into the archive resurrected the note")
    }

    func testARecoveredCopyIsWrittenToTheTrashUnderANewIdAndRewrittenInPlace() throws {
        var note = makeNote("typed after it vanished")
        note.title = "Shopping"

        XCTAssertTrue(store.saveRecoveredCopy(of: note))
        note.content += " and more"
        XCTAssertTrue(store.saveRecoveredCopy(of: note))

        let trashed = store.loadTrashed()
        XCTAssertEqual(trashed.count, 1, "a second recovery made a second file")
        XCTAssertEqual(trashed.first?.content, "typed after it vanished and more")
        XCTAssertEqual(trashed.first?.title, "Shopping")
        XCTAssertNotEqual(trashed.first?.id, note.id)
        XCTAssertTrue(try files(in: store.trashURL).first?.lastPathComponent.hasPrefix("recovered-\(note.id.uuidString)") == true)
        XCTAssertTrue(store.loadActive().isEmpty)
    }

    /// Retention runs from the deletion date, and a write into a trashed file is
    /// the person's latest touch of it: it must not depend on what an atomic
    /// replace does to the file's "date added".
    func testTheTrashKeepsANoteFor30DaysFromTheLastWriteIntoIt() throws {
        let note = makeNote("first")
        store.save(note)
        store.archive(note)
        store.deleteForever(note)
        clock.advance(by: 20 * 24 * 3600)
        guard case let .trashed(snapshot) = store.whereIs(id: note.id) else { return XCTFail("not trashed") }
        var typed = note
        typed.content = "first and a late thought"
        guard case .saved = store.save(typed, in: .trash, expecting: snapshot.fingerprint) else {
            return XCTFail("not saved")
        }
        let written = clock.now()

        XCTAssertEqual(store.purgeExpiredTrash(now: written.addingTimeInterval(NoteStore.trashRetention - 60)), 0)
        XCTAssertEqual(store.loadTrashed().first?.content, "first and a late thought")
        XCTAssertEqual(store.purgeExpiredTrash(now: written.addingTimeInterval(NoteStore.trashRetention + 60)), 1)
    }

    // MARK: - Discarding

    func testDiscardingANoteMovesItsFileToTheTrash() throws {
        let note = makeNote("")
        store.save(note)

        store.discardActive(note)

        XCTAssertNil(store.loadNote(id: note.id))
        XCTAssertEqual(store.loadTrashed().map(\.id), [note.id], "the file was unlinked, not moved to the trash")
        XCTAssertTrue(store.loadArchived().isEmpty)
    }

    func testDiscardingANoteWithNoFileLeavesTheTrashAlone() throws {
        store.discardActive(makeNote(""))
        XCTAssertTrue(store.loadTrashed().isEmpty)
    }
}
