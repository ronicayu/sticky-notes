import XCTest
@testable import StickyNotesKit

final class NoteStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StickyNotesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() -> NoteStore {
        NoteStore(rootURL: root)
    }

    private func makeNote(
        content: String = "hello",
        title: String = "",
        labels: [String] = [],
        color: NoteColor = .yellow
    ) -> Note {
        Note(
            id: UUID(),
            title: title,
            content: content,
            width: 300, height: 220,
            color: color,
            labels: labels,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
    }

    // MARK: - Round trip

    func testSavedNoteReloadsWithEveryFieldIntact() throws {
        let store = makeStore()
        let note = makeNote(
            content: "line one\nline two",
            title: "Shopping",
            labels: ["home", "errands"],
            color: .blue
        )
        store.save(note)

        let loaded = try XCTUnwrap(store.loadActive().first, "nothing loaded")
        XCTAssertEqual(loaded.id, note.id)
        XCTAssertEqual(loaded.title, note.title)
        XCTAssertEqual(loaded.content, note.content)
        XCTAssertEqual(loaded.labels, note.labels)
        XCTAssertEqual(loaded.color, note.color)
        XCTAssertEqual(loaded.width, note.width, accuracy: 0.01)
        XCTAssertEqual(loaded.height, note.height, accuracy: 0.01)
        XCTAssertEqual(loaded.createdAt.timeIntervalSince1970,
                       note.createdAt.timeIntervalSince1970, accuracy: 1.0)
    }

    func testTitleWithColonSurvivesMarkdownRoundTrip() throws {
        let store = makeStore()
        let note = makeNote(title: "Meeting: Q3 planning")
        store.save(note)
        XCTAssertEqual(try XCTUnwrap(store.loadActive().first).title, "Meeting: Q3 planning")
    }

    func testUpdatingANoteOverwritesRatherThanDuplicating() throws {
        let store = makeStore()
        var note = makeNote(content: "first")
        store.save(note)
        note.content = "second"
        store.save(note)

        let all = store.loadActive()
        XCTAssertEqual(all.count, 1, "expected one file, got \(all.count)")
        XCTAssertEqual(all.first?.content, "second")
    }

    func testMarkdownBodyIsPlainMarkdownOnDisk() throws {
        let store = makeStore()
        store.save(makeNote(content: "- [ ] buy milk", labels: ["home"]))

        let files = try FileManager.default.contentsOfDirectory(at: store.activeURL, includingPropertiesForKeys: nil)
        let md = try XCTUnwrap(files.first(where: { $0.pathExtension == "md" }))
        let raw = try String(contentsOf: md, encoding: .utf8)

        XCTAssertTrue(raw.hasPrefix("---\n"), "expected YAML frontmatter, got:\n\(raw)")
        XCTAssertTrue(raw.contains("labels: [home]"), "got:\n\(raw)")
        XCTAssertTrue(raw.hasSuffix("- [ ] buy milk"), "body should be verbatim markdown, got:\n\(raw)")
    }

    // MARK: - Lifecycle

    func testArchiveMovesNoteOutOfActive() throws {
        let store = makeStore()
        let note = makeNote()
        store.save(note)
        store.archive(note)

        XCTAssertTrue(store.loadActive().isEmpty, "note still active")
        XCTAssertEqual(store.loadArchived().map(\.id), [note.id])
    }

    func testRestoreReturnsNoteToActive() throws {
        let store = makeStore()
        let note = makeNote()
        store.save(note)
        store.archive(note)
        store.restore(note)

        let restored = try XCTUnwrap(store.loadActive().first)
        XCTAssertEqual(restored.id, note.id)
        XCTAssertTrue(store.loadArchived().isEmpty)
    }

    func testDeleteForeverRemovesArchivedNote() throws {
        let store = makeStore()
        let note = makeNote()
        store.save(note)
        store.archive(note)
        store.deleteForever(note)

        XCTAssertTrue(store.loadArchived().isEmpty)
        XCTAssertTrue(store.loadActive().isEmpty)
    }

    func testDiscardActiveRemovesNoteWithoutArchiving() throws {
        let store = makeStore()
        let note = makeNote()
        store.save(note)
        store.discardActive(note)

        XCTAssertTrue(store.loadActive().isEmpty)
        XCTAssertTrue(store.loadArchived().isEmpty, "discard must not archive")
    }

    func testLoadNoteFindsActiveAndArchivedById() throws {
        let store = makeStore()
        let note = makeNote(content: "findable")
        store.save(note)
        XCTAssertEqual(store.loadNote(id: note.id)?.content, "findable")

        store.archive(note)
        XCTAssertNil(store.loadNote(id: note.id), "archived note is not active")
        XCTAssertEqual(store.loadNote(id: note.id, archived: true)?.content, "findable")
    }

    /// `contentsOfDirectory(at:)` returns URLs with symlinks resolved, so a
    /// listed file's parent can be `/private/var/…` while the directory we
    /// asked about is `/var/…`. Comparing those as strings made archive and
    /// restore silently do nothing for any storage path behind a symlink —
    /// which includes the standard temporary directory.
    func testArchiveAndRestoreWorkWhenTheStoragePathGoesThroughASymlink() throws {
        let store = makeStore()
        let note = makeNote()
        store.save(note)

        // Reading first is what populated the index with resolved URLs.
        _ = store.loadActive()
        _ = store.loadArchived()

        store.archive(note)
        XCTAssertTrue(store.loadActive().isEmpty, "archive silently did nothing")
        XCTAssertEqual(store.loadArchived().count, 1)

        store.restore(note)
        XCTAssertEqual(store.loadActive().count, 1, "restore silently did nothing")
        XCTAssertTrue(store.loadArchived().isEmpty)
    }

    // MARK: - External deletion (regression guard for 9e14f9d)

    func testSaveDoesNotResurrectANoteDeletedOnDisk() throws {
        let store = makeStore()
        var note = makeNote()
        store.save(note)

        // Simulate another machine or an Obsidian user deleting the file.
        let files = try FileManager.default.contentsOfDirectory(at: store.activeURL, includingPropertiesForKeys: nil)
        for file in files { try FileManager.default.removeItem(at: file) }

        // A debounced save landing after the deletion must not recreate it.
        note.content = "edited after deletion"
        store.save(note)

        XCTAssertTrue(store.loadActive().isEmpty,
                      "externally deleted note was resurrected by a pending save")
    }

    func testSaveAfterArchiveDoesNotRecreateAnActiveCopy() throws {
        let store = makeStore()
        var note = makeNote()
        store.save(note)
        store.archive(note)

        note.content = "late edit"
        store.save(note)

        XCTAssertTrue(store.loadActive().isEmpty, "archived note came back as active")
        XCTAssertEqual(store.loadArchived().count, 1)
    }

    func testANoteThisStoreHasNeverSeenIsStillWritable() throws {
        // The guard keys off ids the store has seen. A genuinely new note must
        // save normally even though no file exists for it yet.
        let store = makeStore()
        store.save(makeNote(content: "brand new"))
        XCTAssertEqual(store.loadActive().first?.content, "brand new")
    }

    // MARK: - Labels

    func testAllLabelsUnionsActiveAndArchivedSorted() {
        let store = makeStore()
        let a = makeNote(labels: ["work", "urgent"])
        let b = makeNote(labels: ["home"])
        let c = makeNote(labels: ["work", "someday"])
        store.save(a)
        store.save(b)
        store.save(c)
        store.archive(c)

        XCTAssertEqual(store.allLabels(), ["home", "someday", "urgent", "work"])
    }

    func testAllLabelsIsEmptyForAnEmptyStore() {
        XCTAssertEqual(makeStore().allLabels(), [])
    }

    func testHandEditedLabelsAreNormalizedOnRead() throws {
        let store = makeStore()
        store.save(makeNote(labels: ["work"]))

        // Rewrite frontmatter the way a human would in Obsidian.
        let files = try FileManager.default.contentsOfDirectory(at: store.activeURL, includingPropertiesForKeys: nil)
        let md = try XCTUnwrap(files.first)
        var raw = try String(contentsOf: md, encoding: .utf8)
        raw = raw.replacingOccurrences(of: "labels: [work]", with: #"labels: ["Work Stuff", '#Deep Focus', ]"#)
        try raw.write(to: md, atomically: true, encoding: .utf8)

        XCTAssertEqual(store.loadActive().first?.labels, ["work-stuff", "deep-focus"],
                       "quotes, a leading #, casing, spaces, and the trailing comma should all be handled")
    }

    // MARK: - Reconfigure

    func testReconfigureCopiesNotesToTheNewRoot() throws {
        let store = makeStore()
        let active = makeNote(content: "still here", labels: ["keep"])
        let archived = makeNote(content: "archived too")
        store.save(active)
        store.save(archived)
        store.archive(archived)

        let newRoot = root.appendingPathComponent("vault", isDirectory: true)
        store.reconfigure(rootURL: newRoot)

        XCTAssertEqual(store.rootURL, newRoot)
        let migrated = try XCTUnwrap(store.loadActive().first)
        XCTAssertEqual(migrated.id, active.id)
        XCTAssertEqual(migrated.content, "still here")
        XCTAssertEqual(migrated.labels, ["keep"])
        XCTAssertEqual(store.loadArchived().map(\.content), ["archived too"])

        let files = try FileManager.default.contentsOfDirectory(at: store.activeURL, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.allSatisfy { $0.pathExtension == "md" }, "expected Markdown files")
    }

    func testReconfigureLeavesTheOldLocationIntact() throws {
        let store = makeStore()
        store.save(makeNote())
        let oldActive = store.activeURL

        store.reconfigure(rootURL: root.appendingPathComponent("vault", isDirectory: true))

        let leftBehind = try FileManager.default.contentsOfDirectory(at: oldActive, includingPropertiesForKeys: nil)
        XCTAssertEqual(leftBehind.count, 1, "reconfiguring should copy, not move — the old tree is the user's backup")
    }

    func testNotesSurviveTwoReconfigures() throws {
        let store = makeStore()
        let note = makeNote(content: "durable", title: "Title: with colon", labels: ["a", "b"], color: .purple)
        store.save(note)

        store.reconfigure(rootURL: root.appendingPathComponent("vault", isDirectory: true))
        store.reconfigure(rootURL: root.appendingPathComponent("back", isDirectory: true))

        let final = try XCTUnwrap(store.loadActive().first)
        XCTAssertEqual(final.id, note.id)
        XCTAssertEqual(final.content, "durable")
        XCTAssertEqual(final.title, "Title: with colon")
        XCTAssertEqual(final.labels, ["a", "b"])
        XCTAssertEqual(final.color, .purple)
    }

    // MARK: - Robustness

    func testUnreadableFilesAreSkippedRatherThanFailingTheWholeLoad() throws {
        let store = makeStore()
        store.save(makeNote(content: "good note"))
        try "this is not a note".write(
            to: store.activeURL.appendingPathComponent("garbage.md"),
            atomically: true, encoding: .utf8
        )
        try "ignore me".write(
            to: store.activeURL.appendingPathComponent("notes.txt"),
            atomically: true, encoding: .utf8
        )

        let loaded = store.loadActive()
        // The garbage .md still parses (frontmatter-less body), but the .txt is
        // ignored entirely and the real note is present.
        XCTAssertTrue(loaded.contains { $0.content == "good note" })
        XCTAssertFalse(loaded.contains { $0.content == "ignore me" }, "non-matching extensions must be skipped")
    }

    func testLoadingFromAStoreWithNoDirectoriesReturnsEmpty() {
        let store = NoteStore(
            rootURL: root.appendingPathComponent("never-created", isDirectory: true))
        // init creates the directories, so this is really asserting no crash
        // and an empty result on a cold store.
        XCTAssertTrue(store.loadActive().isEmpty)
        XCTAssertTrue(store.loadArchived().isEmpty)
    }

    func testArchivedNotesComeBackNewestFirst() {
        let store = makeStore()
        for offset in [0.0, 100.0, 50.0] {
            var note = makeNote(content: "n\(Int(offset))")
            note.updatedAt = Date(timeIntervalSince1970: 1_700_000_000 + offset)
            store.save(note)
            store.archive(note)
        }
        XCTAssertEqual(store.loadArchived().map(\.content), ["n100", "n50", "n0"])
    }

    /// A note written in Obsidian and dropped into the folder carries no
    /// `id:`. Minting a random one per load made every reload look like the
    /// old note vanished and a new one appeared, so its window was torn down
    /// and rebuilt on every store change.
    func testAVaultFileWithoutAnIdKeepsTheSameIdentityAcrossLoads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StableId-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = NoteStore(rootURL: root)
        try "# Hand written\n\nsome text".write(
            to: store.activeURL.appendingPathComponent("2026-08-14 120000.md"),
            atomically: true, encoding: .utf8
        )

        let first = try XCTUnwrap(store.loadActive().first)
        let second = try XCTUnwrap(NoteStore(rootURL: root).loadActive().first)
        XCTAssertEqual(first.id, second.id, "identity churned between loads")
    }

    /// An outside append leaves the lineage alone: the file still has all of our
    /// newest write, so an older save of ours that iCloud kept as a conflict
    /// version holds only text the person has since edited away.
    func testAnOutsideAppendDoesNotStopAnOlderOwnVersionFromBeingDropped() throws {
        let store = makeStore()
        var note = makeNote(content: "teh cat\nsat down")
        store.save(note)
        note.content = "the cat\nsat down"
        store.save(note)
        let older = root.appendingPathComponent("older.md")
        try "---\nid: \(note.id.uuidString)\nupdated: 1970-01-01T00:00:01Z\n---\nteh cat\nsat down\n"
            .write(to: older, atomically: true, encoding: .utf8)
        store.conflictVersionsProvider = { _ in [.init(url: older, markResolved: {})] }
        store.otherVersionsRemover = { _ in }
        _ = store.loadActive()

        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: store.activeURL, includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "md" })
        try "---\nid: \(note.id.uuidString)\ntitle: \"Note\"\nupdated: 2030-01-01T00:00:00Z\n---\nthe cat\nsat down\nfrom Obsidian"
            .write(to: file, atomically: true, encoding: .utf8)
        store.handleFileSystemEvent()

        let content = try XCTUnwrap(store.loadNote(id: note.id)).content
        XCTAssertFalse(content.contains("teh cat"), "an older save of ours came back as a conflict: \(content)")
        XCTAssertTrue(content.contains("from Obsidian"), content)
    }

    // MARK: - Two notes whose file names would be the same

    /// Two notes made in the same second whose ids start with the same six hex
    /// digits: the name a note's file is given from its creation time and those
    /// digits is the same for both.
    private func collidingNotes() -> (a: Note, b: Note) {
        var a = makeNote(content: "alpha text")
        var b = makeNote(content: "beta text")
        a = Note(
            id: UUID(uuidString: "ABCDEF01-0000-4000-8000-000000000001")!, title: "", content: a.content,
            width: 300, height: 220, color: .yellow, createdAt: a.createdAt, updatedAt: a.updatedAt
        )
        b = Note(
            id: UUID(uuidString: "ABCDEF02-0000-4000-8000-000000000002")!, title: "", content: b.content,
            width: 300, height: 220, color: .yellow, createdAt: a.createdAt, updatedAt: a.updatedAt
        )
        XCTAssertEqual(
            a.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(6),
            b.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(6)
        )
        return (a, b)
    }

    func testTwoNotesWithTheSameFileNameGetTwoFilesAndStayTwoNotes() throws {
        let store = makeStore()
        let (a, b) = collidingNotes()

        store.save(a)
        store.save(b)

        let files = try FileManager.default.contentsOfDirectory(at: store.activeURL, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        let loaded = Dictionary(uniqueKeysWithValues: store.loadActive().map { ($0.id, $0.content) })
        XCTAssertEqual(loaded, [a.id: "alpha text", b.id: "beta text"])
    }

    func testCreatingANoteWhoseNameIsTakenByAnotherNoteIsNotAConflictAndMergesNothing() throws {
        let store = makeStore()
        let (a, b) = collidingNotes()
        guard case .saved = store.save(a, expecting: nil) else { return XCTFail("first create did not land") }

        guard case .saved = store.save(b, expecting: nil) else { return XCTFail("the second note met the first one's file") }

        XCTAssertEqual(try XCTUnwrap(store.loadNote(id: a.id)).content, "alpha text")
        XCTAssertEqual(try XCTUnwrap(store.loadNote(id: b.id)).content, "beta text")
    }

    func testANoteWithTheLongerFileNameIsStillFoundSavedArchivedAndRestored() throws {
        let store = makeStore()
        let (a, b) = collidingNotes()
        store.save(a)
        store.save(b)

        var edited = b
        edited.content = "beta edited"
        store.save(edited)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: store.activeURL, includingPropertiesForKeys: nil).count, 2,
                       "saving the second note again made a third file")
        XCTAssertEqual(try XCTUnwrap(store.snapshot(id: b.id)).note.content, "beta edited")

        store.archive(a)
        store.archive(b)
        XCTAssertEqual(Set(store.loadArchived().map(\.id)), [a.id, b.id])
        store.restore(a)
        store.restore(b)

        let loaded = Dictionary(uniqueKeysWithValues: store.loadActive().map { ($0.id, $0.content) })
        XCTAssertEqual(loaded, [a.id: "alpha text", b.id: "beta edited"])
        guard case .active = store.whereIs(id: b.id) else { return XCTFail("whereIs lost the note") }

        let relaunched = NoteStore(rootURL: root)
        XCTAssertEqual(try XCTUnwrap(relaunched.snapshot(id: b.id)).note.content, "beta edited")
    }

    func testANameHeldByAnICloudPlaceholderIsTakenToo() throws {
        let store = makeStore()
        let (a, b) = collidingNotes()
        let stamp = NoteStore.filenameFormatterForTests.string(from: a.createdAt)
        let shortName = "\(stamp)-\(a.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased()).md"
        try Data().write(to: store.activeURL.appendingPathComponent(".\(shortName).icloud"))

        store.save(b)

        let files = try FileManager.default.contentsOfDirectory(at: store.activeURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        XCTAssertEqual(files.map(\.lastPathComponent), ["\(stamp)-\(b.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()).md"])
    }

    func testAnUnreadableFileNamedWithTheNumberedFormMayBeTheNotesAndIsNotCalledMissing() throws {
        let store = makeStore()
        let note = makeNote()
        let stamp = NoteStore.filenameFormatterForTests.string(from: note.createdAt)
        let hex6 = note.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased()
        try Data([0xFF, 0xFE, 0xFD]).write(to: store.activeURL.appendingPathComponent("\(stamp)-\(hex6)-2.md"))

        guard case .unknown = store.whereIs(id: note.id) else { return XCTFail("a file that may be the note's was ignored") }
    }
}
