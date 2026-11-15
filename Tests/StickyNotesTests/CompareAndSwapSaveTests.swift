import AppKit
import XCTest
@testable import StickyNotesKit

/// `NoteStore.save(_:expecting:)`, `snapshot(id:)` and the `Change` that
/// `didChange` carries.
/// Changes seen by a notification observer, which the compiler cannot prove
/// runs on one thread.
private final class ChangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [NoteStore.Change] = []

    func append(_ change: NoteStore.Change) {
        lock.lock(); defer { lock.unlock() }
        changes.append(change)
    }

    var all: [NoteStore.Change] {
        lock.lock(); defer { lock.unlock() }
        return changes
    }
}

@MainActor final class CompareAndSwapSaveTests: XCTestCase {
    private var root: URL!
    private var lockedDirectories: [URL] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompareAndSwap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for url in lockedDirectories {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func makeNote(_ content: String = "hello") -> Note {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        note.content = content
        return note
    }

    /// Another process (Obsidian, the other Mac) rewriting the file: a second
    /// store on the same root, which this store's cache knows nothing about.
    private func outsideWrite(_ note: Note) {
        NoteStore(rootURL: root).save(note)
    }

    private func lockActiveFolder(_ store: NoteStore) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.activeURL.path)
        lockedDirectories.append(store.activeURL)
    }

    private func unlockActiveFolder(_ store: NoteStore) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.activeURL.path)
    }

    private func changes(from store: NoteStore, during body: () -> Void) -> [NoteStore.Change] {
        let seen = ChangeLog()
        let token = NotificationCenter.default.addObserver(
            forName: NoteStore.didChange, object: store, queue: nil
        ) { seen.append(NoteStore.change(in: $0)) }
        body()
        NotificationCenter.default.removeObserver(token)
        return seen.all
    }

    // MARK: - SaveResult

    func testASaveReturnsTheFingerprintOfTheFileItWrote() throws {
        let store = NoteStore(rootURL: root)
        let note = makeNote()

        guard case let .saved(fingerprint) = store.save(note, expecting: nil) else {
            return XCTFail("creating a note did not report .saved")
        }
        let snapshot = try XCTUnwrap(store.snapshot(id: note.id))
        XCTAssertEqual(snapshot.fingerprint, fingerprint)
        XCTAssertEqual(snapshot.note.content, "hello")
    }

    func testSavingAgainWithTheFingerprintItReturnedSucceeds() throws {
        let store = NoteStore(rootURL: root)
        var note = makeNote("one")
        guard case let .saved(first) = store.save(note, expecting: nil) else { return XCTFail() }

        note.content = "two"
        guard case let .saved(second) = store.save(note, expecting: first) else {
            return XCTFail("a save expecting the file it wrote last was refused")
        }
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(store.snapshot(id: note.id)?.note.content, "two")
    }

    func testAStaleFingerprintAfterAnOutsideWriteIsAConflictAndWritesNothing() throws {
        let store = NoteStore(rootURL: root)
        var note = makeNote("mine")
        guard case let .saved(seen) = store.save(note, expecting: nil) else { return XCTFail() }

        var outside = note
        outside.content = "mine\nand what Obsidian added"
        NoteStore(rootURL: root).save(outside)
        let before = try XCTUnwrap(store.snapshot(id: note.id))

        note.content = "mine, edited here"
        guard case let .conflict(onDisk, fingerprint) = store.save(note, expecting: seen) else {
            return XCTFail("a save over a file it had not seen was not refused")
        }

        XCTAssertEqual(onDisk.content, "mine\nand what Obsidian added")
        XCTAssertEqual(fingerprint, before.fingerprint)
        let after = try XCTUnwrap(store.snapshot(id: note.id))
        XCTAssertEqual(after.fingerprint, before.fingerprint, "the refused save changed the file")
        XCTAssertEqual(after.note.content, "mine\nand what Obsidian added")
    }

    func testRetryingWithTheConflictsFingerprintSaves() throws {
        let store = NoteStore(rootURL: root)
        var note = makeNote("mine")
        guard case let .saved(seen) = store.save(note, expecting: nil) else { return XCTFail() }
        var outside = note
        outside.content = "theirs"
        NoteStore(rootURL: root).save(outside)

        guard case let .conflict(onDisk, fingerprint) = store.save(note, expecting: seen) else {
            return XCTFail()
        }
        note.content = "\(onDisk.content)\nmine"

        guard case .saved = store.save(note, expecting: fingerprint) else {
            return XCTFail("the retry was refused")
        }
        XCTAssertEqual(store.snapshot(id: note.id)?.note.content, "theirs\nmine")
    }

    func testExpectingNoFileCreatesAndConflictsWhenOneExists() throws {
        let store = NoteStore(rootURL: root)
        var note = makeNote("first")
        guard case .saved = store.save(note, expecting: nil) else {
            return XCTFail("creating a note was refused")
        }

        note.content = "second"
        guard case let .conflict(onDisk, _) = store.save(note, expecting: nil) else {
            return XCTFail("a create over an existing file was not refused")
        }
        XCTAssertEqual(onDisk.content, "first")
        XCTAssertEqual(store.snapshot(id: note.id)?.note.content, "first")
    }

    func testSavingAfterTheFileWasDeletedOrArchivedIsGoneAndWritesNothing() throws {
        let store = NoteStore(rootURL: root)
        var deleted = makeNote("deleted")
        var archived = makeNote("archived")
        guard case let .saved(deletedSeen) = store.save(deleted, expecting: nil),
              case let .saved(archivedSeen) = store.save(archived, expecting: nil) else {
            return XCTFail()
        }
        store.discardActive(deleted)
        store.archive(archived)

        deleted.content = "typed after"
        archived.content = "typed after"
        for (note, seen, name) in [(deleted, deletedSeen, "deleted"), (archived, archivedSeen, "archived")] {
            guard case .gone = store.save(note, expecting: seen) else {
                return XCTFail("\(name) note was not reported gone")
            }
        }
        XCTAssertTrue(store.loadActive().isEmpty, "a gone note was written back")
    }

    func testAFileThatCannotBeReadIsNotOverwritten() throws {
        let store = NoteStore(rootURL: root)
        var note = makeNote("precious")
        guard case let .saved(seen) = store.save(note, expecting: nil) else { return XCTFail() }
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: store.activeURL, includingPropertiesForKeys: nil
        ).first)
        let garbage = Data([0xFF, 0xFE, 0x00, 0x01])
        try garbage.write(to: file)

        note.content = "replacement"
        guard case .failed = store.save(note, expecting: seen) else {
            return XCTFail("an unreadable file was not reported as failed")
        }
        XCTAssertEqual(try Data(contentsOf: file), garbage, "the unreadable file was overwritten")
    }

    func testAWriteThatCannotLandIsFailedBothBlindAndChecked() throws {
        let store = NoteStore(rootURL: root)
        var note = makeNote("one")
        guard case let .saved(seen) = store.save(note, expecting: nil) else { return XCTFail() }
        try lockActiveFolder(store)

        note.content = "two"
        guard case .failed = store.save(note) else { return XCTFail("blind save did not fail") }
        guard case .failed = store.save(note, expecting: seen) else {
            return XCTFail("checked save did not fail")
        }
        XCTAssertNotNil(store.lastFailure)

        try unlockActiveFolder(store)
        XCTAssertEqual(store.snapshot(id: note.id)?.note.content, "one")
        guard case .saved = store.save(note, expecting: seen) else {
            return XCTFail("the file changed although both saves failed")
        }
    }

    // MARK: - Change payload

    func testEachStoreOperationPostsItsOwnChange() throws {
        let store = NoteStore(rootURL: root)
        let note = makeNote()
        let id = note.id

        XCTAssertEqual(changes(from: store) { store.save(note) }, [.saved(id)])
        XCTAssertEqual(changes(from: store) { store.archive(note) }, [.moved(id, from: .active, to: .archive)])
        XCTAssertEqual(changes(from: store) { store.restore(note) }, [.moved(id, from: .archive, to: .active)])
        let discarded = makeNote()
        store.save(discarded)
        XCTAssertEqual(
            changes(from: store) { store.discardActive(discarded) },
            [.moved(discarded.id, from: .active, to: .trash)]
        )
        let neverWritten = makeNote()
        XCTAssertEqual(changes(from: store) { store.discardActive(neverWritten) }, [.removed(neverWritten.id)])

        store.archive(note)
        XCTAssertEqual(changes(from: store) { store.deleteForever(note) }, [.moved(id, from: .archive, to: .trash)])
        let trashed = try XCTUnwrap(store.loadTrashed().first { $0.id == id })
        XCTAssertEqual(changes(from: store) { store.restoreFromTrash(trashed) },
                       [.moved(id, from: .trash, to: .archive)])
    }

    func testAFileSystemEventPostsResetAndANotificationWithoutAChangeReadsAsReset() throws {
        let store = NoteStore(rootURL: root)
        XCTAssertEqual(changes(from: store) { store.handleFileSystemEvent() }, [.reset])
        XCTAssertEqual(NoteStore.change(in: Notification(name: NoteStore.didChange)), .reset)
    }

    func testASweepMergeNamesTheNotesItRewrote() throws {
        let store = NoteStore(rootURL: root)
        let note = makeNote("current text")
        store.save(note)
        let version = root.appendingPathComponent("version.md")
        try "---\nid: \(note.id.uuidString)\nupdated: 1970-01-01T00:00:01Z\n---\nfrom the other Mac\n"
            .write(to: version, atomically: true, encoding: .utf8)
        store.conflictVersionsProvider = { _ in [.init(url: version, markResolved: {})] }
        store.otherVersionsRemover = { _ in }

        XCTAssertEqual(changes(from: store) { store.resolveConflicts() }, [.external([note.id])])
    }

    // MARK: - Disk reads

    func testSavingAnotherNoteCostsAnOpenWindowNoDiskRead() throws {
        let store = NoteStore(rootURL: root)
        let shown = makeNote("on screen")
        store.save(shown)
        let controller = NoteWindowController(note: shown, store: store, onClosed: { _ in })
        _ = store.loadActive()
        _ = store.loadArchived()
        let reads = store.readCount

        store.save(makeNote("another note"))

        XCTAssertEqual(store.readCount, reads, "a window read its file because a different note was saved")
        withExtendedLifetime(controller) {}
    }

    /// Typing reads nothing. The save a pause in typing triggers reads the file
    /// once, to check it is still what the window last saw.
    func testTypingReadsNoFilesAndASaveReadsTheFileOnce() throws {
        let store = NoteStore(rootURL: root)
        let shown = makeNote("on screen")
        store.save(shown)
        let controller = NoteWindowController(note: shown, store: store, onClosed: { _ in })
        _ = store.loadActive()
        _ = store.loadArchived()
        let reads = store.readCount

        controller.textView.string = "on screen, edited"
        controller.editor.textDidChange(Notification(name: NSText.didChangeNotification, object: controller.textView))
        XCTAssertEqual(store.readCount, reads, "typing read a file")

        controller.flushPendingSave()

        XCTAssertEqual(store.loadNote(id: shown.id)?.content, "on screen, edited")
        XCTAssertEqual(store.readCount, reads + 1, "a save must read the file exactly once")
    }

    // MARK: - Duplicate ids

    /// Two files carrying one id would let a save write one of them and a
    /// reload read the other, so the extra file is given an id of its own when found.
    func testAFileCarryingAnIdAnotherFileHasGetsANewId() throws {
        let note = makeNote("first")
        NoteStore(rootURL: root).save(note)
        let active = root.appendingPathComponent("notes")
        let original = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: active, includingPropertiesForKeys: nil
        ).first)
        let copy = active.appendingPathComponent("copy.md")
        try String(contentsOf: original, encoding: .utf8)
            .replacingOccurrences(of: "first", with: "stale copy")
            .write(to: copy, atomically: true, encoding: .utf8)
        let store = NoteStore(rootURL: root)
        XCTAssertEqual(store.loadActive().count, 2)

        var edited = try XCTUnwrap(store.loadNote(id: note.id))
        XCTAssertEqual(edited.content, "first")
        edited.content = "edited"
        store.save(edited)

        XCTAssertEqual(store.loadNote(id: note.id)?.content, "edited")
        XCTAssertEqual(Set(store.loadActive().map(\.content)), ["edited", "stale copy"])
    }

    // MARK: - The sweep

    private func aConflictVersion(of note: Note, content: String) throws -> NoteStore.ConflictVersionHandle {
        let url = root.appendingPathComponent("version-\(UUID().uuidString).md")
        try "---\nid: \(note.id.uuidString)\nupdated: 1970-01-01T00:00:01Z\n---\n\(content)\n"
            .write(to: url, atomically: true, encoding: .utf8)
        return .init(url: url, markResolved: {})
    }

    func testAMergeThatCannotBeWrittenLeavesTheConflictVersionsInPlace() throws {
        let store = NoteStore(rootURL: root)
        store.offMain = .inline
        let note = makeNote("current text")
        store.save(note)
        let other = try aConflictVersion(of: note, content: "only the other Mac has this")
        var resolved = 0
        var removed = 0
        store.conflictVersionsProvider = { _ in
            [.init(url: other.url, markResolved: { resolved += 1 })]
        }
        store.otherVersionsRemover = { _ in removed += 1 }
        try lockActiveFolder(store)

        XCTAssertEqual(store.resolveConflicts(), 0)

        XCTAssertEqual(resolved, 0, "a version was resolved though its text reached no file")
        XCTAssertEqual(removed, 0)

        try unlockActiveFolder(store)
        XCTAssertEqual(store.resolveConflicts(), 1)
        XCTAssertEqual(resolved, 1)
        XCTAssertTrue(try XCTUnwrap(store.loadNote(id: note.id)).content.contains("only the other Mac has this"))
    }
}
