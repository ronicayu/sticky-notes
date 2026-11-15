import XCTest
@testable import StickyNotesKit

/// Notes used to be stored as `<uuid>.json` outside a vault. They are Markdown
/// now, and the store converts what an older version left behind.
final class JSONMigrationTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("JSONMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: - Helpers

    private func makeNote(
        _ content: String = "hello",
        title: String = "",
        labels: [String] = [],
        id: UUID = UUID()
    ) -> Note {
        Note(
            id: id, title: title, content: content,
            width: 300, height: 220, color: .blue, labels: labels,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
    }

    private func legacyJSON(_ note: Note) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(note)
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeLegacy(_ note: Note, in name: String, as fileName: String? = nil) throws -> URL {
        let url = try folder(name).appendingPathComponent(fileName ?? "\(note.id.uuidString).json")
        try legacyJSON(note).write(to: url)
        return url
    }

    private func files(_ name: String, ext: String) throws -> [URL] {
        try fm.contentsOfDirectory(at: root.appendingPathComponent(name, isDirectory: true), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == ext }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Every file under `dir` with its bytes, by path relative to it.
    private func snapshot(of dir: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let base = dir.resolvingSymlinksInPath().path
        let enumerator = try XCTUnwrap(fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(base.count))
            result[relative] = try Data(contentsOf: url)
        }
        return result
    }

    // MARK: - The conversion

    func testFiftyJSONNotesWithOneMalformedConvertsFortyNineAndReportsTheOther() throws {
        var notes: [Note] = []
        for index in 0..<49 {
            let note = makeNote("note \(index)", title: "Title \(index)")
            notes.append(note)
            try writeLegacy(note, in: "notes")
        }
        let malformed = try folder("notes").appendingPathComponent("\(UUID().uuidString).json")
        try Data("{ this is not a note".utf8).write(to: malformed)

        let store = NoteStore(rootURL: root)

        store.offMain = .inline

        XCTAssertEqual(store.lastMigration.migrated, 49)
        XCTAssertEqual(store.lastMigration.failures.map(\.url.lastPathComponent), [malformed.lastPathComponent])
        XCTAssertEqual(Set(store.loadActive().map(\.id)), Set(notes.map(\.id)))
        XCTAssertEqual(try files("notes", ext: "md").count, 49)
        XCTAssertEqual(try files("notes", ext: "json").map(\.lastPathComponent), [malformed.lastPathComponent],
                       "only the malformed file is left, untouched")
        XCTAssertEqual(try Data(contentsOf: malformed), Data("{ this is not a note".utf8))
        XCTAssertEqual(store.lastFailure?.fileName, malformed.lastPathComponent)
        XCTAssertEqual(store.lastFailure?.kind, .migration)

        let before = try snapshot(of: root)
        let relaunched = NoteStore(rootURL: root)

        XCTAssertEqual(relaunched.lastMigration.migrated, 0, "a relaunch converts nothing more")
        XCTAssertEqual(relaunched.lastMigration.failures.map(\.url.lastPathComponent), [malformed.lastPathComponent],
                       "and reports the file that is still wrong")
        XCTAssertEqual(try snapshot(of: root), before, "a relaunch changes no file")
        XCTAssertEqual(relaunched.loadActive().count, 49)
    }

    func testEveryFieldSurvivesTheConversion() throws {
        var note = makeNote("first line\nsecond: line\n- [ ] task", title: "A \"quoted\": title", labels: ["home", "to-do"])
        note.legacyPlacement = LegacyPlacement(x: 123.456, y: -40, collapsed: true)
        note.floatLevel = .desktop
        note.color = .purple
        try writeLegacy(note, in: "notes")

        let store = NoteStore(rootURL: root)

        store.offMain = .inline

        let loaded = try XCTUnwrap(store.loadActive().first)
        XCTAssertEqual(loaded.id, note.id)
        XCTAssertEqual(loaded.title, note.title)
        XCTAssertEqual(loaded.content, note.content)
        XCTAssertEqual(loaded.labels, note.labels)
        XCTAssertEqual(loaded.color, .purple)
        XCTAssertEqual(loaded.floatLevel, .desktop)
        let placement = try XCTUnwrap(loaded.legacyPlacement, "the converted note lost where it sat")
        XCTAssertEqual(placement.x, 123.456, accuracy: 0.01)
        XCTAssertEqual(placement.y, -40, accuracy: 0.01)
        XCTAssertTrue(placement.collapsed)
        XCTAssertEqual(loaded.width, 300, accuracy: 0.01)
        XCTAssertEqual(loaded.createdAt, note.createdAt)
        XCTAssertEqual(loaded.updatedAt, note.updatedAt)
    }

    func testAnOldNoteWithoutTheNewerFieldsStillConverts() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "content": "from long ago", "positionX": 10, "positionY": 20,
         "width": 240, "height": 200, "createdAt": "2024-01-02T03:04:05Z", "updatedAt": "2024-01-02T03:04:06Z"}
        """
        let notes = try folder("notes")
        try Data(json.utf8).write(to: notes.appendingPathComponent("old.json"))

        let store = NoteStore(rootURL: root)

        store.offMain = .inline

        XCTAssertEqual(store.lastMigration.migrated, 1)
        let loaded = try XCTUnwrap(store.loadActive().first)
        XCTAssertEqual(loaded.content, "from long ago")
        XCTAssertEqual(loaded.color, .yellow)
        XCTAssertEqual(loaded.floatLevel, .floating)
        XCTAssertEqual(loaded.title, "")
    }

    func testArchivedNotesStayArchivedAndRestoreAfterTheConversion() throws {
        let archived = makeNote("archived text")
        let active = makeNote("active text")
        try writeLegacy(archived, in: "archive")
        try writeLegacy(active, in: "notes")

        let store = NoteStore(rootURL: root)

        store.offMain = .inline

        XCTAssertEqual(store.loadActive().map(\.id), [active.id])
        XCTAssertEqual(store.loadArchived().map(\.id), [archived.id])
        XCTAssertEqual(try files("archive", ext: "json").count, 0)
        XCTAssertEqual(try files("archive", ext: "md").count, 1)

        store.restore(archived)
        XCTAssertEqual(Set(store.loadActive().map(\.id)), [active.id, archived.id])
        XCTAssertTrue(store.loadArchived().isEmpty)
    }

    func testATrashedNoteIsNeverPurgedSoonerBecauseOfTheConversion() throws {
        let note = makeNote("deleted twenty days ago")
        let url = try writeLegacy(note, in: ".trash")
        let deletion = Date().addingTimeInterval(-20 * 24 * 60 * 60)
        try fm.setAttributes([.modificationDate: deletion], ofItemAtPath: url.path)

        let store = NoteStore(rootURL: root)

        store.offMain = .inline

        XCTAssertEqual(store.loadTrashed().map(\.id), [note.id])
        XCTAssertEqual(try files(".trash", ext: "json").count, 0)
        XCTAssertEqual(store.purgeExpiredTrash(), 0)
        XCTAssertEqual(store.loadTrashed().count, 1)

        // Converting rewrote the file, which restarts the folder's record of when
        // it arrived, so the note keeps its place for at most thirty days more.
        let later = Date().addingTimeInterval(NoteStore.trashRetention + 3600)
        XCTAssertEqual(store.purgeExpiredTrash(now: later), 1)
        XCTAssertTrue(store.loadTrashed().isEmpty)
    }

    func testAnExpiredTrashedJSONNoteIsDeletedNotConverted() throws {
        try writeLegacy(makeNote("long gone"), in: ".trash")
        let afterRetention = ManualClock(Date().addingTimeInterval(NoteStore.trashRetention + 86_400))

        let store = NoteStore(rootURL: root, clock: afterRetention)

        XCTAssertEqual(store.lastMigration.migrated, 0)
        XCTAssertTrue(store.loadTrashed().isEmpty)
        XCTAssertEqual(try files(".trash", ext: "md").count, 0)
        XCTAssertEqual(try files(".trash", ext: "json").count, 0)
    }

    func testATrashedNoteDeletedTodayIsNotPurgedEvenIfEditedLongAgo() throws {
        let store = NoteStore(rootURL: root)
        store.offMain = .inline
        let note = makeNote("old edit")
        store.save(note)
        store.archive(note)
        let archived = try XCTUnwrap(files("archive", ext: "md").first)
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-(NoteStore.trashRetention + 86_400))],
            ofItemAtPath: archived.path
        )
        store.deleteForever(note)

        XCTAssertEqual(store.purgeExpiredTrash(), 0)
        XCTAssertEqual(store.loadTrashed().count, 1)
    }

    func testTrashedNotesSurviveARelaunchAfterTheConversion() throws {
        let note = makeNote("trashed")
        try writeLegacy(note, in: ".trash")
        _ = NoteStore(rootURL: root)

        let relaunched = NoteStore(rootURL: root)

        XCTAssertEqual(relaunched.loadTrashed().map(\.id), [note.id])
        relaunched.restoreFromTrash(note)
        XCTAssertEqual(relaunched.loadArchived().map(\.id), [note.id])
    }

    // MARK: - Collisions

    func testAJSONFileWhoseMarkdownTwinHoldsTheSameTextIsJustRemoved() throws {
        let note = makeNote("same text")
        _ = NoteStore(rootURL: root).save(note)
        let markdown = try XCTUnwrap(files("notes", ext: "md").first)
        let bytes = try Data(contentsOf: markdown)
        let json = try writeLegacy(note, in: "notes")

        let store = NoteStore(rootURL: root)

        store.offMain = .inline

        XCTAssertEqual(store.lastMigration.migrated, 1)
        XCTAssertFalse(fm.fileExists(atPath: json.path))
        XCTAssertEqual(try files("notes", ext: "md"), [markdown])
        XCTAssertEqual(try Data(contentsOf: markdown), bytes, "an identical twin is not rewritten")
    }

    func testAJSONFileWhoseIdAlreadyHasMarkdownMergesInsteadOfOverwriting() throws {
        let id = UUID()
        var edited = makeNote("shared line\nonly in markdown", id: id)
        edited.updatedAt = Date(timeIntervalSince1970: 1_700_000_900)
        _ = NoteStore(rootURL: root).save(edited)
        let json = try writeLegacy(makeNote("shared line\nonly in json", id: id), in: "notes")

        let store = NoteStore(rootURL: root)

        store.offMain = .inline

        XCTAssertTrue(store.lastMigration.failures.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: json.path))
        XCTAssertEqual(try files("notes", ext: "md").count, 1, "one note, one file")
        let merged = try XCTUnwrap(store.loadActive().first).content
        XCTAssertTrue(merged.contains("only in markdown"), "the newer text was overwritten: \(merged)")
        XCTAssertTrue(merged.contains("only in json"), "the older text was dropped: \(merged)")
        XCTAssertTrue(merged.contains("shared line"))
    }

    func testAJSONFileThatIsNewerThanItsMarkdownTwinStillKeepsBothTexts() throws {
        let id = UUID()
        _ = NoteStore(rootURL: root).save(makeNote("old markdown text", id: id))
        var newer = makeNote("newer json text", id: id)
        newer.updatedAt = Date(timeIntervalSince1970: 1_700_009_000)
        try writeLegacy(newer, in: "notes")

        let store = NoteStore(rootURL: root)

        store.offMain = .inline

        let merged = try XCTUnwrap(store.loadActive().first).content
        XCTAssertTrue(merged.contains("old markdown text"))
        XCTAssertTrue(merged.contains("newer json text"))
        XCTAssertEqual(try files("notes", ext: "json").count, 0)
    }

    func testTwoJSONFilesWithOneIdMakeOneNote() throws {
        let id = UUID()
        try writeLegacy(makeNote("first copy", id: id), in: "notes")
        try writeLegacy(makeNote("second copy", id: id), in: "notes", as: "\(id.uuidString) 2.json")

        let store = NoteStore(rootURL: root)

        store.offMain = .inline

        XCTAssertEqual(try files("notes", ext: "md").count, 1)
        XCTAssertEqual(try files("notes", ext: "json").count, 0)
        let content = try XCTUnwrap(store.loadActive().first).content
        XCTAssertTrue(content.contains("first copy"))
        XCTAssertTrue(content.contains("second copy"))
    }

    func testAnInterruptedConversionResumesWithoutLosingAnything() throws {
        // A first run wrote the Markdown and stopped before it deleted the JSON.
        let note = makeNote("half done")
        try writeLegacy(note, in: "notes")
        let first = NoteStore(rootURL: root)
        let markdown = try XCTUnwrap(files("notes", ext: "md").first)
        XCTAssertEqual(first.lastMigration.migrated, 1)
        try writeLegacy(note, in: "notes")

        let store = NoteStore(rootURL: root)

        store.offMain = .inline

        XCTAssertEqual(try files("notes", ext: "md"), [markdown])
        XCTAssertEqual(try files("notes", ext: "json").count, 0)
        XCTAssertEqual(store.loadActive().map(\.content), ["half done"])
    }

    // MARK: - Files that must be left alone

    func testAMalformedFileIsLeftInPlaceInEveryFolderAndReported() throws {
        for name in ["notes", "archive", ".trash"] {
            try Data("not json".utf8).write(to: folder(name).appendingPathComponent("bad.json"))
        }

        let store = NoteStore(rootURL: root)

        store.offMain = .inline

        XCTAssertEqual(store.lastMigration.migrated, 0)
        XCTAssertEqual(store.lastMigration.failures.count, 3)
        for name in ["notes", "archive", ".trash"] {
            XCTAssertEqual(try files(name, ext: "json").count, 1, name)
            XCTAssertEqual(try files(name, ext: "md").count, 0, name)
        }
    }

    func testAMigrationFailureStaysReportedAfterLaterSavesSucceed() throws {
        let bad = try folder("notes").appendingPathComponent("bad.json")
        try Data("nope".utf8).write(to: bad)
        let store = NoteStore(rootURL: root)
        store.offMain = .inline
        XCTAssertEqual(store.lastFailure?.kind, .migration)

        store.save(makeNote("a later, ordinary save"))

        XCTAssertEqual(store.lastFailure?.fileName, "bad.json",
                       "saving another note does not repair this file")

        try fm.removeItem(at: bad)
        store.migrateJSONNotes()
        XCTAssertNil(store.lastFailure, "a run that finds nothing wrong clears it")
    }

    func testANoteThatDoesNotReadBackTheSameIsKeptAsJSON() throws {
        // A comma splits one label into two on the way back, so the Markdown
        // file would not be the note it was made from.
        let note = makeNote("careful", labels: ["a,b"])
        let json = try writeLegacy(note, in: "notes")

        let store = NoteStore(rootURL: root)

        store.offMain = .inline

        XCTAssertEqual(store.lastMigration.migrated, 0)
        XCTAssertEqual(store.lastMigration.failures.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: json.path))
        XCTAssertEqual(try files("notes", ext: "md").count, 0, "the file that failed verification is removed")
    }

    func testAVaultRootIsLeftExactlyAsItIs() throws {
        let vault = root.appendingPathComponent("vault/StickyNotes", isDirectory: true)
        let store = NoteStore(rootURL: vault)
        store.save(makeNote("in the vault", title: "Vault note"))
        let archived = makeNote("archived in the vault")
        store.save(archived)
        store.archive(archived)
        let state = vault.appendingPathComponent("_daily.json")
        try Data(#"{"date": "2026-01-01"}"#.utf8).write(to: state)
        let before = try snapshot(of: vault)

        let relaunched = NoteStore(rootURL: vault)

        XCTAssertEqual(relaunched.lastMigration.migrated, 0)
        XCTAssertTrue(relaunched.lastMigration.failures.isEmpty)
        XCTAssertNil(relaunched.lastFailure)
        XCTAssertEqual(try snapshot(of: vault), before)
        XCTAssertEqual(relaunched.loadActive().count, 1)
    }

    // MARK: - Fingerprints, lineage and the conflict sweep

    func testAFingerprintTakenAfterTheConversionIsAcceptedByASave() throws {
        let note = makeNote("converted")
        try writeLegacy(note, in: "notes")
        let store = NoteStore(rootURL: root)
        store.offMain = .inline

        let snapshot = try XCTUnwrap(store.snapshot(id: note.id))
        var edited = snapshot.note
        edited.content = "converted and edited"

        guard case .saved = store.save(edited, expecting: snapshot.fingerprint) else {
            return XCTFail("a fingerprint read after the conversion was refused")
        }
    }

    func testAFingerprintOfTheOldJSONBytesIsAConflictThatTheNextSaveRecoversFrom() throws {
        let note = makeNote("converted")
        let json = try writeLegacy(note, in: "notes")
        let stale = Fingerprint(of: try Data(contentsOf: json))
        let store = NoteStore(rootURL: root)
        store.offMain = .inline

        guard case let .conflict(onDisk, fresh) = store.save(note, expecting: stale) else {
            return XCTFail("a fingerprint of a file that no longer exists must not be taken for a match")
        }
        XCTAssertEqual(onDisk.content, "converted")
        guard case .saved = store.save(note, expecting: fresh) else {
            return XCTFail("the fingerprint in the conflict did not unlock the next save")
        }
    }

    func testTextFromAnotherMacIsStillMergedIntoAConvertedNote() throws {
        let note = makeNote("converted here")
        try writeLegacy(note, in: "notes")
        let store = NoteStore(rootURL: root)
        store.offMain = .inline

        var other = note
        other.content = "converted here\nwritten on the other Mac"
        other.updatedAt = Date(timeIntervalSince1970: 1_700_000_900)
        let copy = root.appendingPathComponent("other-mac.md")
        try store.recoveryText(for: other).write(to: copy, atomically: true, encoding: .utf8)
        var resolved = false
        store.conflictVersionsProvider = { _ in
            [NoteStore.ConflictVersionHandle(url: copy, markResolved: { resolved = true })]
        }

        XCTAssertEqual(store.resolveConflicts(), 1)

        XCTAssertTrue(resolved)
        XCTAssertTrue(try XCTUnwrap(store.loadActive().first).content.contains("written on the other Mac"))
    }

    func testAConflictVersionOfAJSONNoteIsMergedBeforeTheJSONIsDeleted() throws {
        let store = NoteStore(rootURL: root)
        store.offMain = .inline
        let note = makeNote("on this Mac")
        let json = try writeLegacy(note, in: "notes")
        var other = note
        other.content = "on this Mac\nonly on the other Mac"
        other.updatedAt = Date(timeIntervalSince1970: 1_700_000_900)
        let copy = root.appendingPathComponent("conflict.json")
        try legacyJSON(other).write(to: copy)
        var resolved = false
        store.conflictVersionsProvider = { url in
            url.resolvingSymlinksInPath() == json.resolvingSymlinksInPath() ? [NoteStore.ConflictVersionHandle(url: copy, markResolved: { resolved = true })] : []
        }

        let report = store.migrateJSONNotes()

        XCTAssertEqual(report.migrated, 1)
        XCTAssertTrue(resolved)
        XCTAssertFalse(fm.fileExists(atPath: json.path))
        let content = try XCTUnwrap(store.loadActive().first).content
        XCTAssertTrue(content.contains("only on the other Mac"))
        XCTAssertTrue(content.contains("on this Mac"))
    }

    func testAConflictVersionThatNeverDownloadsDoesNotHideTheNote() throws {
        let store = NoteStore(rootURL: root)
        store.offMain = .inline
        let note = makeNote("waiting")
        let json = try writeLegacy(note, in: "notes")
        let missing = root.appendingPathComponent("not-downloaded.json")
        store.conflictVersionsProvider = { _ in
            [NoteStore.ConflictVersionHandle(url: missing, markResolved: {})]
        }

        let report = store.migrateJSONNotes()

        XCTAssertEqual(report.migrated, 1)
        XCTAssertEqual(report.failures.count, 1, "the missing copy is still reported")
        XCTAssertEqual(store.loadActive().map(\.content), ["waiting"], "the note shows")
        XCTAssertFalse(fm.fileExists(atPath: json.path))
        let aside = root.appendingPathComponent(".converted-json/notes", isDirectory: true)
        let kept = try fm.contentsOfDirectory(atPath: aside.path).sorted()
        XCTAssertEqual(kept, [json.lastPathComponent, json.lastPathComponent + ".unread-conflict-copies.txt"])
        let listing = try String(contentsOf: aside.appendingPathComponent(kept[1]), encoding: .utf8)
        XCTAssertTrue(listing.contains("not-downloaded.json"))
    }

    // MARK: - The original is kept

    func testAConvertedJSONIsMovedOutOfTheNoteFoldersNotDeleted() throws {
        let note = makeNote("keep a copy")
        let archived = makeNote("archived copy")
        let trashed = makeNote("trashed copy")
        let jsonURLs = [
            try writeLegacy(note, in: "notes"),
            try writeLegacy(archived, in: "archive"),
            try writeLegacy(trashed, in: ".trash"),
        ]
        let originals = try jsonURLs.map { try Data(contentsOf: $0) }

        _ = NoteStore(rootURL: root)

        for (index, folder) in ["notes", "archive", ".trash"].enumerated() {
            let aside = root.appendingPathComponent(".converted-json/\(folder)/\(jsonURLs[index].lastPathComponent)")
            XCTAssertEqual(try Data(contentsOf: aside), originals[index], folder)
            XCTAssertEqual(try files(folder, ext: "json").count, 0, folder)
        }
    }

    func testAJSONWhoseNameIsAlreadyTakenInTheSetAsideFolderKeepsBoth() throws {
        let note = makeNote("again")
        let aside = try folder(".converted-json/notes")
        try Data("earlier".utf8).write(to: aside.appendingPathComponent("\(note.id.uuidString).json"))
        try writeLegacy(note, in: "notes")

        _ = NoteStore(rootURL: root)

        XCTAssertEqual(try fm.contentsOfDirectory(atPath: aside.path).count, 2)
    }

    func testASetAsideFolderIsNotLoadedAsNotes() throws {
        let note = makeNote("only once")
        try writeLegacy(note, in: "notes")

        let store = NoteStore(rootURL: root)

        store.offMain = .inline

        XCTAssertEqual(store.loadActive().count, 1)
        XCTAssertTrue(store.loadArchived().isEmpty)
        XCTAssertTrue(store.loadTrashed().isEmpty)
    }

    // MARK: - Titles

    func testWhenOnlyTheTitleDiffersTheNewerVersionWinsWhicheverFileItIsIn() throws {
        let id = UUID()
        var markdownNote = makeNote("same", title: "Old title", id: id)
        markdownNote.updatedAt = Date(timeIntervalSince1970: 1_700_000_100)
        _ = NoteStore(rootURL: root).save(markdownNote)
        var renamedOnTheOldMac = makeNote("same", title: "Renamed on the old Mac", id: id)
        renamedOnTheOldMac.updatedAt = Date(timeIntervalSince1970: 1_700_000_900)
        try writeLegacy(renamedOnTheOldMac, in: "notes")

        let store = NoteStore(rootURL: root)

        store.offMain = .inline

        XCTAssertEqual(try XCTUnwrap(store.loadActive().first).title, "Renamed on the old Mac")
        XCTAssertEqual(try XCTUnwrap(store.loadActive().first).content, "same")
    }

    func testANewerMarkdownTitleSurvivesAnOlderJSONWithTheSameText() throws {
        let id = UUID()
        var markdownNote = makeNote("same", title: "Newer title", id: id)
        markdownNote.updatedAt = Date(timeIntervalSince1970: 1_700_000_900)
        _ = NoteStore(rootURL: root).save(markdownNote)
        try writeLegacy(makeNote("same", title: "Older title", id: id), in: "notes")

        let store = NoteStore(rootURL: root)

        store.offMain = .inline

        XCTAssertEqual(try XCTUnwrap(store.loadActive().first).title, "Newer title")
    }

    func testATitleThatLosesAMergeIsKeptInTheNote() throws {
        let id = UUID()
        var markdownNote = makeNote("shared\nonly markdown", title: "Markdown title", id: id)
        markdownNote.updatedAt = Date(timeIntervalSince1970: 1_700_000_900)
        _ = NoteStore(rootURL: root).save(markdownNote)
        try writeLegacy(makeNote("shared\nonly json", title: "JSON title", id: id), in: "notes")

        let loaded = try XCTUnwrap(NoteStore(rootURL: root).loadActive().first)

        XCTAssertEqual(loaded.title, "Markdown title")
        XCTAssertTrue(loaded.content.contains("only json"))
        XCTAssertTrue(loaded.content.contains("Also titled: JSON title"), loaded.content)
    }

    // MARK: - Two files with one id

    func testTwoFilesWithOneIdBecomeTwoNotesAtLaunchAndOnlyTheIdLineChanges() throws {
        let id = UUID()
        let store = NoteStore(rootURL: root)
        store.offMain = .inline
        store.save(makeNote("the original", id: id))
        let original = try XCTUnwrap(files("notes", ext: "md").first)
        let originalBytes = try Data(contentsOf: original)
        // Obsidian's "Make a copy": the same file, edited, with the same frontmatter id.
        let copy = original.deletingLastPathComponent().appendingPathComponent("Copy of note.md")
        let copyText = try String(contentsOf: original, encoding: .utf8)
            .replacingOccurrences(of: "the original", with: "the copy, edited")
        try copyText.write(to: copy, atomically: true, encoding: .utf8)

        let relaunched = NoteStore(rootURL: root)

        XCTAssertEqual(relaunched.lastMigration.reassignedDuplicateIds, 1)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes, "the file with a fresh save's name is untouched")
        XCTAssertEqual(try files("notes", ext: "md").count, 2, "nothing is merged or moved")
        let notes = relaunched.loadActive()
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(Set(notes.map(\.id)).count, 2)
        XCTAssertEqual(Set(notes.map(\.content)), ["the original", "the copy, edited"])
        XCTAssertEqual(notes.first { $0.content == "the original" }?.id, id)

        let newId = try XCTUnwrap(notes.first { $0.content != "the original" }?.id)
        let expected = copyText.replacingOccurrences(of: id.uuidString, with: newId.uuidString)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), expected, "only the id line changed")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(".converted-json").path))

        let again = NoteStore(rootURL: root)
        XCTAssertEqual(again.lastMigration.reassignedDuplicateIds, 0, "a relaunch changes nothing")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), expected)
        XCTAssertEqual(again.loadActive().count, 2)
    }

    func testThePreservedIdGoesToTheOldestFileWhenNoNameMatches() throws {
        let id = UUID()
        let notes = try folder("notes")
        let note = makeNote("same", id: id)
        let store = NoteStore(rootURL: root.appendingPathComponent("scratch"))
        let older = notes.appendingPathComponent("z older.md")
        let newer = notes.appendingPathComponent("a newer.md")
        try store.recoveryText(for: note).write(to: older, atomically: true, encoding: .utf8)
        try store.recoveryText(for: note).write(to: newer, atomically: true, encoding: .utf8)
        try fm.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: older.path)
        try fm.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: newer.path)

        let loaded = NoteStore(rootURL: root).loadActive()

        XCTAssertEqual(Set(loaded.map(\.id)).count, 2)
        XCTAssertTrue(try String(contentsOf: older, encoding: .utf8).contains(id.uuidString))
        XCTAssertFalse(try String(contentsOf: newer, encoding: .utf8).contains(id.uuidString))
    }

    func testAReassignedIdIsOurOwnWriteForTheConflictSweep() throws {
        let id = UUID()
        let store = NoteStore(rootURL: root)
        store.offMain = .inline
        store.save(makeNote("the original", id: id))
        let original = try XCTUnwrap(files("notes", ext: "md").first)
        let copy = original.deletingLastPathComponent().appendingPathComponent("copy.md")
        try String(contentsOf: original, encoding: .utf8).write(to: copy, atomically: true, encoding: .utf8)
        let relaunched = NoteStore(rootURL: root)
        let copied = try XCTUnwrap(relaunched.loadActive().first { $0.id != id })

        // An earlier save of this very file, kept by iCloud as a conflict version.
        let version = root.appendingPathComponent("earlier.md")
        try relaunched.recoveryText(for: copied).write(to: version, atomically: true, encoding: .utf8)
        relaunched.conflictVersionsProvider = { url in
            url.resolvingSymlinksInPath() == copy.resolvingSymlinksInPath()
                ? [NoteStore.ConflictVersionHandle(url: version, markResolved: {})] : []
        }

        XCTAssertEqual(relaunched.resolveConflicts(), 0, "our own write is not a conflict")
        XCTAssertEqual(relaunched.loadNote(id: copied.id)?.content, "the original")
    }

    func testDuplicatesThatAppearWhileTheAppRunsGetANewIdWhenTheFolderIsRead() throws {
        let id = UUID()
        let store = NoteStore(rootURL: root)
        store.offMain = .inline
        store.save(makeNote("one", id: id))
        XCTAssertEqual(store.loadActive().count, 1)
        let original = try XCTUnwrap(files("notes", ext: "md").first)
        let twin = original.deletingLastPathComponent().appendingPathComponent("elsewhere.md")
        try store.recoveryText(for: makeNote("two", id: id)).write(to: twin, atomically: true, encoding: .utf8)
        store.handleFileSystemEvent()

        let loaded = store.loadActive()

        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(Set(loaded.map(\.id)).count, 2)
        XCTAssertEqual(Set(loaded.map(\.content)), ["one", "two"])
        XCTAssertEqual(loaded.first { $0.content == "one" }?.id, id)
        XCTAssertEqual(try files("notes", ext: "md").count, 2)
    }

    // MARK: - Reporting

    func testTheConversionWarningSurvivesAWriteFailureAndTheNextSuccess() throws {
        try Data("nope".utf8).write(to: folder("notes").appendingPathComponent("bad.json"))
        let store = NoteStore(rootURL: root)
        store.offMain = .inline
        XCTAssertEqual(store.lastFailure?.kind, .migration)
        let notes = root.appendingPathComponent("notes")
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: notes.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notes.path) }

        store.save(makeNote("cannot be written"))
        XCTAssertEqual(store.lastFailure?.kind, .write)

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notes.path)
        store.save(makeNote("can be written"))

        XCTAssertEqual(store.lastFailure?.kind, .migration)
        XCTAssertEqual(store.lastFailure?.fileName, "bad.json")
    }

    func testAJSONFileThatArrivesAfterLaunchIsReportedAndLeftAlone() throws {
        let store = NoteStore(rootURL: root)
        store.offMain = .inline
        XCTAssertNil(store.lastFailure)
        let posted = PostCount()
        let observer = NotificationCenter.default.addObserver(
            forName: NoteStore.healthDidChange, object: store, queue: nil
        ) { _ in posted.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let late = try writeLegacy(makeNote("from the old Mac"), in: "notes")
        let bytes = try Data(contentsOf: late)

        store.handleFileSystemEvent()

        XCTAssertEqual(store.lastFailure?.kind, .olderVersion)
        XCTAssertEqual(store.lastFailure?.fileName, late.lastPathComponent)
        XCTAssertEqual(store.lastFailure?.menuTitle, "Notes from an older version are waiting")
        XCTAssertEqual(posted.value, 1)
        XCTAssertEqual(try Data(contentsOf: late), bytes, "the file is not touched")
        XCTAssertEqual(try files("notes", ext: "md").count, 0, "and not converted while the other Mac may be editing it")

        store.handleFileSystemEvent()
        XCTAssertEqual(posted.value, 1, "the same notice is not posted again")

        try fm.removeItem(at: late)
        store.handleFileSystemEvent()
        XCTAssertNil(store.lastFailure)
    }

    func testTheOlderVersionNoticeDoesNotReplaceAWriteFailure() throws {
        let store = NoteStore(rootURL: root)
        store.offMain = .inline
        let notes = root.appendingPathComponent("notes")
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: notes.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notes.path) }
        store.save(makeNote("fails"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notes.path)
        try writeLegacy(makeNote("late"), in: "archive")

        store.handleFileSystemEvent()

        XCTAssertEqual(store.lastFailure?.kind, .write)
    }

    // MARK: - Storage switching

    func testSwitchingToARootThatStillHoldsJSONConvertsItAndKeepsTheCurrentNotes() throws {
        let store = NoteStore(rootURL: root.appendingPathComponent("local", isDirectory: true))
        let mine = makeNote("from the local root")
        store.save(mine)

        let icloud = root.appendingPathComponent("icloud", isDirectory: true)
        let theirs = makeNote("left by an older version")
        let theirsArchived = makeNote("archived by an older version")
        let notes = icloud.appendingPathComponent("notes", isDirectory: true)
        let archive = icloud.appendingPathComponent("archive", isDirectory: true)
        try fm.createDirectory(at: notes, withIntermediateDirectories: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        try legacyJSON(theirs).write(to: notes.appendingPathComponent("\(theirs.id.uuidString).json"))
        try legacyJSON(theirsArchived).write(to: archive.appendingPathComponent("\(theirsArchived.id.uuidString).json"))

        store.reconfigure(rootURL: icloud)

        XCTAssertEqual(Set(store.loadActive().map(\.id)), [mine.id, theirs.id])
        XCTAssertEqual(store.loadArchived().map(\.id), [theirsArchived.id])
        XCTAssertEqual(store.lastMigration.migrated, 2)
        let leftovers = try fm.contentsOfDirectory(at: notes, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.allSatisfy { $0.pathExtension == "md" })
    }

    func testSwitchingFromAConvertedRootToAVaultAndBackKeepsEveryNote() throws {
        let note = makeNote("travels", title: "Trip", labels: ["x"])
        try writeLegacy(note, in: "local/notes")
        let store = NoteStore(rootURL: root.appendingPathComponent("local", isDirectory: true))

        store.reconfigure(rootURL: root.appendingPathComponent("vault/StickyNotes", isDirectory: true))
        store.reconfigure(rootURL: root.appendingPathComponent("local", isDirectory: true))

        let loaded = try XCTUnwrap(store.loadActive().first)
        XCTAssertEqual(loaded.id, note.id)
        XCTAssertEqual(loaded.content, "travels")
        XCTAssertEqual(loaded.title, "Trip")
        XCTAssertEqual(loaded.labels, ["x"])
    }

    func testSwitchingToARootThatHasTheSameNoteMergesInsteadOfOverwriting() throws {
        let id = UUID()
        let store = NoteStore(rootURL: root.appendingPathComponent("local", isDirectory: true))
        store.save(makeNote("shared\nonly in the local copy", id: id))
        let icloud = NoteStore(rootURL: root.appendingPathComponent("icloud", isDirectory: true))
        var theirs = makeNote("shared\nonly in the iCloud copy", id: id)
        theirs.updatedAt = Date(timeIntervalSince1970: 1_700_000_900)
        icloud.save(theirs)

        store.reconfigure(rootURL: root.appendingPathComponent("icloud", isDirectory: true))

        XCTAssertEqual(try files("icloud/notes", ext: "md").count, 1)
        let content = try XCTUnwrap(store.loadActive().first).content
        XCTAssertTrue(content.contains("only in the local copy"), content)
        XCTAssertTrue(content.contains("only in the iCloud copy"), content)
    }

    func testSwitchingToARootWhoseCopyHasAConflictVersionKeepsAllThreeTexts() throws {
        let id = UUID()
        let store = NoteStore(rootURL: root.appendingPathComponent("local", isDirectory: true), offMain: .inline)
        store.save(makeNote("shared\nonly in the local copy", id: id))
        let icloudRoot = root.appendingPathComponent("icloud", isDirectory: true)
        let icloud = NoteStore(rootURL: icloudRoot)
        var theirs = makeNote("shared\nonly in the iCloud copy", id: id)
        theirs.updatedAt = Date(timeIntervalSince1970: 1_700_000_900)
        icloud.save(theirs)
        let destination = try XCTUnwrap(files("icloud/notes", ext: "md").first)
        var conflict = theirs
        conflict.content = "shared\nonly in the conflict version"
        conflict.updatedAt = Date(timeIntervalSince1970: 1_700_000_950)
        let copy = root.appendingPathComponent("conflict.md")
        try store.recoveryText(for: conflict).write(to: copy, atomically: true, encoding: .utf8)
        var resolved = false
        store.conflictVersionsProvider = { url in
            url.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath()
                ? [NoteStore.ConflictVersionHandle(url: copy, markResolved: { resolved = true })] : []
        }

        store.reconfigure(rootURL: icloudRoot)

        let content = try XCTUnwrap(store.loadActive().first).content
        XCTAssertTrue(content.contains("only in the local copy"), content)
        XCTAssertTrue(content.contains("only in the iCloud copy"), content)
        XCTAssertTrue(content.contains("only in the conflict version"), content)
        XCTAssertTrue(resolved)
        XCTAssertEqual(try files("icloud/notes", ext: "md").count, 1)
    }

    func testSwitchingBackToARootVisitedBeforeStillFindsItsNotes() throws {
        let id = UUID()
        let localRoot = root.appendingPathComponent("local", isDirectory: true)
        let store = NoteStore(rootURL: localRoot)
        store.save(makeNote("v1", id: id))
        _ = store.loadActive()
        store.reconfigure(rootURL: root.appendingPathComponent("other", isDirectory: true))
        _ = store.loadActive()

        var changed = try XCTUnwrap(store.loadNote(id: id))
        changed.content = "v1\nplus more"
        changed.updatedAt = Date(timeIntervalSince1970: 1_700_009_000)
        store.save(changed)
        store.reconfigure(rootURL: localRoot)

        XCTAssertEqual(try files("local/notes", ext: "md").count, 1, "no second file for one note")
        XCTAssertEqual(store.loadActive().map(\.content), ["v1\nplus more"])
    }
}

private final class PostCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
