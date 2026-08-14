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

    private func makeStore(_ format: StorageFormat) -> NoteStore {
        NoteStore(rootURL: root, format: format)
    }

    private func makeNote(
        content: String = "hello",
        title: String = "",
        labels: [String] = [],
        collapsed: Bool = false,
        color: NoteColor = .yellow
    ) -> Note {
        Note(
            id: UUID(),
            title: title,
            content: content,
            positionX: 120, positionY: 240,
            width: 300, height: 220,
            collapsed: collapsed,
            color: color,
            labels: labels,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
    }

    private let bothFormats: [StorageFormat] = [.json, .markdown]

    // MARK: - Round trip

    func testSavedNoteReloadsWithEveryFieldIntact() throws {
        for format in bothFormats {
            let store = makeStore(format)
            let note = makeNote(
                content: "line one\nline two",
                title: "Shopping",
                labels: ["home", "errands"],
                collapsed: true,
                color: .blue
            )
            store.save(note)

            let loaded = try XCTUnwrap(store.loadActive().first, "\(format): nothing loaded")
            XCTAssertEqual(loaded.id, note.id, "\(format)")
            XCTAssertEqual(loaded.title, note.title, "\(format)")
            XCTAssertEqual(loaded.content, note.content, "\(format)")
            XCTAssertEqual(loaded.labels, note.labels, "\(format)")
            XCTAssertEqual(loaded.color, note.color, "\(format)")
            XCTAssertEqual(loaded.collapsed, note.collapsed, "\(format)")
            XCTAssertEqual(loaded.positionX, note.positionX, accuracy: 0.01, "\(format)")
            XCTAssertEqual(loaded.height, note.height, accuracy: 0.01, "\(format)")
            XCTAssertEqual(loaded.createdAt.timeIntervalSince1970,
                           note.createdAt.timeIntervalSince1970, accuracy: 1.0, "\(format)")
        }
    }

    func testTitleWithColonSurvivesMarkdownRoundTrip() throws {
        let store = makeStore(.markdown)
        let note = makeNote(title: "Meeting: Q3 planning")
        store.save(note)
        XCTAssertEqual(try XCTUnwrap(store.loadActive().first).title, "Meeting: Q3 planning")
    }

    func testUpdatingANoteOverwritesRatherThanDuplicating() throws {
        for format in bothFormats {
            let store = makeStore(format)
            var note = makeNote(content: "first")
            store.save(note)
            note.content = "second"
            store.save(note)

            let all = store.loadActive()
            XCTAssertEqual(all.count, 1, "\(format): expected one file, got \(all.count)")
            XCTAssertEqual(all.first?.content, "second", "\(format)")
        }
    }

    func testMarkdownBodyIsPlainMarkdownOnDisk() throws {
        let store = makeStore(.markdown)
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
        for format in bothFormats {
            let store = makeStore(format)
            let note = makeNote()
            store.save(note)
            store.archive(note)

            XCTAssertTrue(store.loadActive().isEmpty, "\(format): note still active")
            XCTAssertEqual(store.loadArchived().map(\.id), [note.id], "\(format)")
        }
    }

    func testRestoreReturnsNoteToActiveAndForcesItExpanded() throws {
        for format in bothFormats {
            let store = makeStore(format)
            let note = makeNote(collapsed: true)
            store.save(note)
            store.archive(note)
            store.restore(note)

            let restored = try XCTUnwrap(store.loadActive().first, "\(format)")
            XCTAssertEqual(restored.id, note.id, "\(format)")
            XCTAssertFalse(restored.collapsed, "\(format): restore should expand so content is visible")
            XCTAssertTrue(store.loadArchived().isEmpty, "\(format)")
        }
    }

    func testDeleteForeverRemovesArchivedNote() throws {
        for format in bothFormats {
            let store = makeStore(format)
            let note = makeNote()
            store.save(note)
            store.archive(note)
            store.deleteForever(note)

            XCTAssertTrue(store.loadArchived().isEmpty, "\(format)")
            XCTAssertTrue(store.loadActive().isEmpty, "\(format)")
        }
    }

    func testDiscardActiveRemovesNoteWithoutArchiving() throws {
        for format in bothFormats {
            let store = makeStore(format)
            let note = makeNote()
            store.save(note)
            store.discardActive(note)

            XCTAssertTrue(store.loadActive().isEmpty, "\(format)")
            XCTAssertTrue(store.loadArchived().isEmpty, "\(format): discard must not archive")
        }
    }

    func testLoadNoteFindsActiveAndArchivedById() throws {
        for format in bothFormats {
            let store = makeStore(format)
            let note = makeNote(content: "findable")
            store.save(note)
            XCTAssertEqual(store.loadNote(id: note.id)?.content, "findable", "\(format)")

            store.archive(note)
            XCTAssertNil(store.loadNote(id: note.id), "\(format): archived note is not active")
            XCTAssertEqual(store.loadNote(id: note.id, archived: true)?.content, "findable", "\(format)")
        }
    }

    /// `contentsOfDirectory(at:)` returns URLs with symlinks resolved, so a
    /// listed file's parent can be `/private/var/…` while the directory we
    /// asked about is `/var/…`. Comparing those as strings made archive and
    /// restore silently do nothing for any storage path behind a symlink —
    /// which includes the standard temporary directory.
    func testArchiveAndRestoreWorkWhenTheStoragePathGoesThroughASymlink() throws {
        for format in bothFormats {
            let store = makeStore(format)
            let note = makeNote()
            store.save(note)

            // Reading first is what populated the index with resolved URLs.
            _ = store.loadActive()
            _ = store.loadArchived()

            store.archive(note)
            XCTAssertTrue(store.loadActive().isEmpty, "\(format): archive silently did nothing")
            XCTAssertEqual(store.loadArchived().count, 1, "\(format)")

            store.restore(note)
            XCTAssertEqual(store.loadActive().count, 1, "\(format): restore silently did nothing")
            XCTAssertTrue(store.loadArchived().isEmpty, "\(format)")
        }
    }

    // MARK: - External deletion (regression guard for 9e14f9d)

    func testSaveDoesNotResurrectANoteDeletedOnDisk() throws {
        for format in bothFormats {
            let store = makeStore(format)
            var note = makeNote()
            store.save(note)

            // Simulate another machine or an Obsidian user deleting the file.
            let files = try FileManager.default.contentsOfDirectory(at: store.activeURL, includingPropertiesForKeys: nil)
            for file in files { try FileManager.default.removeItem(at: file) }

            // A debounced save landing after the deletion must not recreate it.
            note.content = "edited after deletion"
            store.save(note)

            XCTAssertTrue(store.loadActive().isEmpty,
                          "\(format): externally deleted note was resurrected by a pending save")
        }
    }

    func testSaveAfterArchiveDoesNotRecreateAnActiveCopy() throws {
        for format in bothFormats {
            let store = makeStore(format)
            var note = makeNote()
            store.save(note)
            store.archive(note)

            note.content = "late edit"
            store.save(note)

            XCTAssertTrue(store.loadActive().isEmpty, "\(format): archived note came back as active")
            XCTAssertEqual(store.loadArchived().count, 1, "\(format)")
        }
    }

    func testANoteThisStoreHasNeverSeenIsStillWritable() throws {
        // The guard keys off ids the store has seen. A genuinely new note must
        // save normally even though no file exists for it yet.
        for format in bothFormats {
            let store = makeStore(format)
            store.save(makeNote(content: "brand new"))
            XCTAssertEqual(store.loadActive().first?.content, "brand new", "\(format)")
        }
    }

    // MARK: - Labels

    func testAllLabelsUnionsActiveAndArchivedSorted() {
        let store = makeStore(.markdown)
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
        XCTAssertEqual(makeStore(.json).allLabels(), [])
    }

    func testHandEditedLabelsAreNormalizedOnRead() throws {
        let store = makeStore(.markdown)
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

    func testReconfigureMigratesNotesToTheNewRootAndFormat() throws {
        let store = makeStore(.json)
        let active = makeNote(content: "still here", labels: ["keep"])
        let archived = makeNote(content: "archived too")
        store.save(active)
        store.save(archived)
        store.archive(archived)

        let newRoot = root.appendingPathComponent("vault", isDirectory: true)
        store.reconfigure(rootURL: newRoot, format: .markdown)

        XCTAssertEqual(store.rootURL, newRoot)
        let migrated = try XCTUnwrap(store.loadActive().first)
        XCTAssertEqual(migrated.id, active.id)
        XCTAssertEqual(migrated.content, "still here")
        XCTAssertEqual(migrated.labels, ["keep"])
        XCTAssertEqual(store.loadArchived().map(\.content), ["archived too"])

        let files = try FileManager.default.contentsOfDirectory(at: store.activeURL, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.allSatisfy { $0.pathExtension == "md" }, "expected markdown after migration")
    }

    func testReconfigureLeavesTheOldLocationIntact() throws {
        let store = makeStore(.json)
        store.save(makeNote())
        let oldActive = store.activeURL

        store.reconfigure(rootURL: root.appendingPathComponent("vault", isDirectory: true), format: .markdown)

        let leftBehind = try FileManager.default.contentsOfDirectory(at: oldActive, includingPropertiesForKeys: nil)
        XCTAssertEqual(leftBehind.count, 1, "migration should copy, not move — the old tree is the user's backup")
    }

    func testNotesSurviveAReconfigureRoundTripBackToJSON() throws {
        let store = makeStore(.json)
        let note = makeNote(content: "durable", title: "Title: with colon", labels: ["a", "b"], color: .purple)
        store.save(note)

        store.reconfigure(rootURL: root.appendingPathComponent("vault", isDirectory: true), format: .markdown)
        store.reconfigure(rootURL: root.appendingPathComponent("back", isDirectory: true), format: .json)

        let final = try XCTUnwrap(store.loadActive().first)
        XCTAssertEqual(final.id, note.id)
        XCTAssertEqual(final.content, "durable")
        XCTAssertEqual(final.title, "Title: with colon")
        XCTAssertEqual(final.labels, ["a", "b"])
        XCTAssertEqual(final.color, .purple)
    }

    // MARK: - Robustness

    func testUnreadableFilesAreSkippedRatherThanFailingTheWholeLoad() throws {
        let store = makeStore(.markdown)
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
            rootURL: root.appendingPathComponent("never-created", isDirectory: true),
            format: .json
        )
        // init creates the directories, so this is really asserting no crash
        // and an empty result on a cold store.
        XCTAssertTrue(store.loadActive().isEmpty)
        XCTAssertTrue(store.loadArchived().isEmpty)
    }

    func testArchivedNotesComeBackNewestFirst() {
        let store = makeStore(.json)
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

        let store = NoteStore(rootURL: root, format: .markdown)
        try "# Hand written\n\nsome text".write(
            to: store.activeURL.appendingPathComponent("2026-08-14 120000.md"),
            atomically: true, encoding: .utf8
        )

        let first = try XCTUnwrap(store.loadActive().first)
        let second = try XCTUnwrap(NoteStore(rootURL: root, format: .markdown).loadActive().first)
        XCTAssertEqual(first.id, second.id, "identity churned between loads")
    }

}
