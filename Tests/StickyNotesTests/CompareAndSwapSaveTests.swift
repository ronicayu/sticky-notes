import AppKit
import XCTest
@testable import StickyNotesKit

/// `NoteStore.save(_:expecting:)`, `snapshot(id:)` and the `Change` that
/// `didChange` carries.
final class CompareAndSwapSaveTests: XCTestCase {
    private var root: URL!
    private var lockedDirectories: [URL] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompareAndSwap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for url in lockedDirectories {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try? FileManager.default.removeItem(at: root)
    }

    private let bothFormats: [StorageFormat] = [.json, .markdown]

    private func makeNote(_ content: String = "hello") -> Note {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        note.content = content
        return note
    }

    /// Another process (Obsidian, the other Mac) rewriting the file: a second
    /// store on the same folder, which this store's cache knows nothing about.
    private func outsideWrite(_ note: Note, format: StorageFormat) {
        NoteStore(rootURL: root, format: format).save(note)
    }

    private func lockActiveFolder(_ store: NoteStore) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.activeURL.path)
        lockedDirectories.append(store.activeURL)
    }

    private func unlockActiveFolder(_ store: NoteStore) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.activeURL.path)
    }

    private func changes(from store: NoteStore, during body: () -> Void) -> [NoteStore.Change] {
        var seen: [NoteStore.Change] = []
        let token = NotificationCenter.default.addObserver(
            forName: NoteStore.didChange, object: store, queue: nil
        ) { seen.append(NoteStore.change(in: $0)) }
        body()
        NotificationCenter.default.removeObserver(token)
        return seen
    }

    // MARK: - SaveResult

    func testASaveReturnsTheFingerprintOfTheFileItWrote() throws {
        for format in bothFormats {
            let store = NoteStore(rootURL: root.appendingPathComponent("\(format)"), format: format)
            let note = makeNote()

            guard case let .saved(fingerprint) = store.save(note, expecting: nil) else {
                return XCTFail("\(format): creating a note did not report .saved")
            }
            let snapshot = try XCTUnwrap(store.snapshot(id: note.id), "\(format)")
            XCTAssertEqual(snapshot.fingerprint, fingerprint, "\(format)")
            XCTAssertEqual(snapshot.note.content, "hello", "\(format)")
        }
    }

    func testSavingAgainWithTheFingerprintItReturnedSucceeds() throws {
        for format in bothFormats {
            let store = NoteStore(rootURL: root.appendingPathComponent("\(format)"), format: format)
            var note = makeNote("one")
            guard case let .saved(first) = store.save(note, expecting: nil) else { return XCTFail("\(format)") }

            note.content = "two"
            guard case let .saved(second) = store.save(note, expecting: first) else {
                return XCTFail("\(format): a save expecting the file it wrote last was refused")
            }
            XCTAssertNotEqual(first, second, "\(format)")
            XCTAssertEqual(store.snapshot(id: note.id)?.note.content, "two", "\(format)")
        }
    }

    func testAStaleFingerprintAfterAnOutsideWriteIsAConflictAndWritesNothing() throws {
        for format in bothFormats {
            let folder = root.appendingPathComponent("\(format)")
            let store = NoteStore(rootURL: folder, format: format)
            var note = makeNote("mine")
            guard case let .saved(seen) = store.save(note, expecting: nil) else { return XCTFail("\(format)") }

            var outside = note
            outside.content = "mine\nand what Obsidian added"
            NoteStore(rootURL: folder, format: format).save(outside)
            let before = try XCTUnwrap(store.snapshot(id: note.id))

            note.content = "mine, edited here"
            guard case let .conflict(onDisk, fingerprint) = store.save(note, expecting: seen) else {
                return XCTFail("\(format): a save over a file it had not seen was not refused")
            }

            XCTAssertEqual(onDisk.content, "mine\nand what Obsidian added", "\(format)")
            XCTAssertEqual(fingerprint, before.fingerprint, "\(format)")
            let after = try XCTUnwrap(store.snapshot(id: note.id))
            XCTAssertEqual(after.fingerprint, before.fingerprint, "\(format): the refused save changed the file")
            XCTAssertEqual(after.note.content, "mine\nand what Obsidian added", "\(format)")
        }
    }

    func testRetryingWithTheConflictsFingerprintSaves() throws {
        for format in bothFormats {
            let folder = root.appendingPathComponent("\(format)")
            let store = NoteStore(rootURL: folder, format: format)
            var note = makeNote("mine")
            guard case let .saved(seen) = store.save(note, expecting: nil) else { return XCTFail("\(format)") }
            var outside = note
            outside.content = "theirs"
            NoteStore(rootURL: folder, format: format).save(outside)

            guard case let .conflict(onDisk, fingerprint) = store.save(note, expecting: seen) else {
                return XCTFail("\(format)")
            }
            note.content = "\(onDisk.content)\nmine"

            guard case .saved = store.save(note, expecting: fingerprint) else {
                return XCTFail("\(format): the retry was refused")
            }
            XCTAssertEqual(store.snapshot(id: note.id)?.note.content, "theirs\nmine", "\(format)")
        }
    }

    func testExpectingNoFileCreatesAndConflictsWhenOneExists() throws {
        for format in bothFormats {
            let store = NoteStore(rootURL: root.appendingPathComponent("\(format)"), format: format)
            var note = makeNote("first")
            guard case .saved = store.save(note, expecting: nil) else {
                return XCTFail("\(format): creating a note was refused")
            }

            note.content = "second"
            guard case let .conflict(onDisk, _) = store.save(note, expecting: nil) else {
                return XCTFail("\(format): a create over an existing file was not refused")
            }
            XCTAssertEqual(onDisk.content, "first", "\(format)")
            XCTAssertEqual(store.snapshot(id: note.id)?.note.content, "first", "\(format)")
        }
    }

    func testSavingAfterTheFileWasDeletedOrArchivedIsGoneAndWritesNothing() throws {
        for format in bothFormats {
            let store = NoteStore(rootURL: root.appendingPathComponent("\(format)"), format: format)
            var deleted = makeNote("deleted")
            var archived = makeNote("archived")
            guard case let .saved(deletedSeen) = store.save(deleted, expecting: nil),
                  case let .saved(archivedSeen) = store.save(archived, expecting: nil) else {
                return XCTFail("\(format)")
            }
            store.discardActive(deleted)
            store.archive(archived)

            deleted.content = "typed after"
            archived.content = "typed after"
            for (note, seen, name) in [(deleted, deletedSeen, "deleted"), (archived, archivedSeen, "archived")] {
                guard case .gone = store.save(note, expecting: seen) else {
                    return XCTFail("\(format): \(name) note was not reported gone")
                }
            }
            XCTAssertTrue(store.loadActive().isEmpty, "\(format): a gone note was written back")
        }
    }

    func testAFileThatCannotBeReadIsNotOverwritten() throws {
        for format in bothFormats {
            let store = NoteStore(rootURL: root.appendingPathComponent("\(format)"), format: format)
            var note = makeNote("precious")
            guard case let .saved(seen) = store.save(note, expecting: nil) else { return XCTFail("\(format)") }
            let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
                at: store.activeURL, includingPropertiesForKeys: nil
            ).first)
            let garbage = Data([0xFF, 0xFE, 0x00, 0x01])
            try garbage.write(to: file)

            note.content = "replacement"
            guard case .failed = store.save(note, expecting: seen) else {
                return XCTFail("\(format): an unreadable file was not reported as failed")
            }
            XCTAssertEqual(try Data(contentsOf: file), garbage, "\(format): the unreadable file was overwritten")
        }
    }

    func testAWriteThatCannotLandIsFailedBothBlindAndChecked() throws {
        for format in bothFormats {
            let store = NoteStore(rootURL: root.appendingPathComponent("\(format)"), format: format)
            var note = makeNote("one")
            guard case let .saved(seen) = store.save(note, expecting: nil) else { return XCTFail("\(format)") }
            try lockActiveFolder(store)

            note.content = "two"
            guard case .failed = store.save(note) else { return XCTFail("\(format): blind save did not fail") }
            guard case .failed = store.save(note, expecting: seen) else {
                return XCTFail("\(format): checked save did not fail")
            }
            XCTAssertNotNil(store.lastFailure, "\(format)")

            try unlockActiveFolder(store)
            XCTAssertEqual(store.snapshot(id: note.id)?.note.content, "one", "\(format)")
            guard case .saved = store.save(note, expecting: seen) else {
                return XCTFail("\(format): the file changed although both saves failed")
            }
        }
    }

    // MARK: - Change payload

    func testEachStoreOperationPostsItsOwnChange() throws {
        let store = NoteStore(rootURL: root, format: .markdown)
        let note = makeNote()
        let id = note.id

        XCTAssertEqual(changes(from: store) { store.save(note) }, [.saved(id)])
        XCTAssertEqual(changes(from: store) { store.archive(note) }, [.moved(id, from: .active, to: .archive)])
        XCTAssertEqual(changes(from: store) { store.restore(note) }, [.moved(id, from: .archive, to: .active)])
        XCTAssertEqual(changes(from: store) { store.discardActive(note) }, [.removed(id)])

        store.save(note)
        store.archive(note)
        XCTAssertEqual(changes(from: store) { store.deleteForever(note) }, [.moved(id, from: .archive, to: .trash)])
        let trashed = try XCTUnwrap(store.loadTrashed().first)
        XCTAssertEqual(changes(from: store) { store.restoreFromTrash(trashed) },
                       [.moved(id, from: .trash, to: .archive)])
    }

    func testAFileSystemEventPostsResetAndANotificationWithoutAChangeReadsAsReset() throws {
        let store = NoteStore(rootURL: root, format: .markdown)
        XCTAssertEqual(changes(from: store) { store.handleFileSystemEvent() }, [.reset])
        XCTAssertEqual(NoteStore.change(in: Notification(name: NoteStore.didChange)), .reset)
    }

    func testASweepMergeNamesTheNotesItRewrote() throws {
        let store = NoteStore(rootURL: root, format: .markdown)
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
        let store = NoteStore(rootURL: root, format: .markdown)
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

    /// Covers the synchronous part only: the watcher's echo of the save is a
    /// `.reset`, which drops the cache and makes every window read again.
    func testTheSynchronousPartOfAWindowsSaveReadsNoFiles() throws {
        let store = NoteStore(rootURL: root, format: .markdown)
        let shown = makeNote("on screen")
        store.save(shown)
        let controller = NoteWindowController(note: shown, store: store, onClosed: { _ in })
        _ = store.loadActive()
        _ = store.loadArchived()
        let reads = store.readCount

        controller.textView.string = "on screen, edited"
        controller.editor.textDidChange(Notification(name: NSText.didChangeNotification, object: controller.textView))
        controller.flushPendingSave()

        XCTAssertEqual(store.loadNote(id: shown.id)?.content, "on screen, edited")
        XCTAssertEqual(store.readCount, reads, "saving a window's own note read files")
    }

    // MARK: - Duplicate ids

    /// Two files carrying one id: a directory scan lets the last win the path
    /// index, so that is the file a save writes and the entry `loadNote` returns.
    func testASaveReplacesTheSameCacheEntryLoadNoteAnswersWith() throws {
        let note = makeNote("first")
        NoteStore(rootURL: root, format: .markdown).save(note)
        let active = root.appendingPathComponent("notes")
        let original = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: active, includingPropertiesForKeys: nil
        ).first)
        let copy = active.appendingPathComponent("copy.md")
        try String(contentsOf: original, encoding: .utf8)
            .replacingOccurrences(of: "first", with: "stale copy")
            .write(to: copy, atomically: true, encoding: .utf8)
        let store = NoteStore(rootURL: root, format: .markdown)
        XCTAssertEqual(store.loadActive().count, 2)

        var edited = note
        edited.content = "edited"
        store.save(edited)

        XCTAssertEqual(store.loadNote(id: note.id)?.content, "edited")
    }

    // MARK: - The sweep

    private func aConflictVersion(of note: Note, content: String) throws -> NoteStore.ConflictVersionHandle {
        let url = root.appendingPathComponent("version-\(UUID().uuidString).md")
        try "---\nid: \(note.id.uuidString)\nupdated: 1970-01-01T00:00:01Z\n---\n\(content)\n"
            .write(to: url, atomically: true, encoding: .utf8)
        return .init(url: url, markResolved: {})
    }

    func testAMergeThatCannotBeWrittenLeavesTheConflictVersionsInPlace() throws {
        let store = NoteStore(rootURL: root, format: .markdown)
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
