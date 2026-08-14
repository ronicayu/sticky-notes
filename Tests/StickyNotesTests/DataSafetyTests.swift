import XCTest
@testable import StickyNotesKit

final class ConflictResolverTests: XCTestCase {

    private func note(
        _ content: String,
        labels: [String] = [],
        updated: TimeInterval,
        id: UUID = UUID()
    ) -> Note {
        Note(
            id: id, title: "T", content: content,
            positionX: 0, positionY: 0, width: 240, height: 200,
            collapsed: false, color: .yellow, labels: labels,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + updated)
        )
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testASingleVersionIsReturnedUnchanged() throws {
        let only = note("just me", updated: 0)
        XCTAssertEqual(ConflictResolver.merge([only])?.content, "just me")
    }

    func testNoVersionsMergeToNothing() {
        XCTAssertNil(ConflictResolver.merge([]))
    }

    // MARK: - Body merge (editor buffer vs. an external write)

    /// The case that used to lose text: the user is typing, another app writes
    /// the same file, and one of the two versions gets overwritten.
    func testBodyMergeKeepsBothSides() {
        let merged = ConflictResolver.mergeBodies(
            local: "typed here", external: "written by Obsidian",
            externalDate: Date(timeIntervalSince1970: 1_700_000_000), now: now
        )
        XCTAssertTrue(merged.contains("typed here"))
        XCTAssertTrue(merged.contains("written by Obsidian"))
    }

    func testBodyMergeLeavesTheLocalTextOnTop() {
        let merged = ConflictResolver.mergeBodies(
            local: "mine", external: "theirs",
            externalDate: Date(timeIntervalSince1970: 1_700_000_000), now: now
        )
        XCTAssertTrue(merged.hasPrefix("mine"))
    }

    func testIdenticalBodiesDoNotProduceADivider() {
        let merged = ConflictResolver.mergeBodies(
            local: "same text", external: "same text",
            externalDate: Date(), now: now
        )
        XCTAssertEqual(merged, "same text")
    }

    /// An external write the local buffer already contains added nothing —
    /// appending it would duplicate the user's own text back at them.
    func testASupersededExternalBodyIsNotAppended() {
        let merged = ConflictResolver.mergeBodies(
            local: "shopping list\n- milk", external: "shopping list",
            externalDate: Date(), now: now
        )
        XCTAssertEqual(merged, "shopping list\n- milk")
    }

    /// The mirror case: the external version is the one that grew, e.g. the
    /// file synced in from a phone while the Mac buffer sat untouched.
    func testAnExternalBodyThatContainsTheLocalOneWins() {
        let merged = ConflictResolver.mergeBodies(
            local: "shopping list", external: "shopping list\n- milk",
            externalDate: Date(), now: now
        )
        XCTAssertEqual(merged, "shopping list\n- milk")
    }

    func testAnEmptyExternalBodyNeverClobbersLocalText() {
        let merged = ConflictResolver.mergeBodies(
            local: "still here", external: "", externalDate: Date(), now: now
        )
        XCTAssertEqual(merged, "still here")
    }

    /// The whole point: a merge must never lose what the other Mac wrote.
    func testBothVersionsTextSurvives() throws {
        let mine = note("written on the laptop", updated: 100)
        let theirs = note("written on the desktop", updated: 200)

        let merged = try XCTUnwrap(ConflictResolver.merge([mine, theirs], now: now))
        XCTAssertTrue(merged.content.contains("written on the laptop"))
        XCTAssertTrue(merged.content.contains("written on the desktop"))
    }

    func testNewestVersionLeadsTheMergedNote() throws {
        let older = note("older text", updated: 100)
        let newer = note("newer text", updated: 200)

        let merged = try XCTUnwrap(ConflictResolver.merge([older, newer], now: now))
        XCTAssertTrue(merged.content.hasPrefix("newer text"), "got \(merged.content)")
    }

    func testLosingVersionsAreLabelledAsConflictedCopies() throws {
        let merged = try XCTUnwrap(ConflictResolver.merge(
            [note("a", updated: 100), note("b", updated: 200)], now: now
        ))
        XCTAssertTrue(merged.content.contains("Conflicted copy"), "got \(merged.content)")
    }

    func testIdenticalVersionsAreNotDuplicated() throws {
        let merged = try XCTUnwrap(ConflictResolver.merge(
            [note("same text", updated: 100), note("same text", updated: 200)], now: now
        ))
        XCTAssertEqual(merged.content, "same text", "identical copies need no divider")
    }

    /// A version whose text the winner already contains added nothing — this
    /// is the common shape when one Mac simply saved later.
    func testAVersionContainedInTheWinnerIsDropped() throws {
        let short = note("first paragraph", updated: 100)
        let long = note("first paragraph\n\nsecond paragraph", updated: 200)

        let merged = try XCTUnwrap(ConflictResolver.merge([short, long], now: now))
        XCTAssertEqual(merged.content, "first paragraph\n\nsecond paragraph")
        XCTAssertFalse(merged.content.contains("Conflicted copy"))
    }

    func testThreeWayConflictKeepsEveryDistinctBody() throws {
        let merged = try XCTUnwrap(ConflictResolver.merge([
            note("from the laptop", updated: 100),
            note("from the desktop", updated: 200),
            note("from the mini", updated: 300)
        ], now: now))
        for text in ["from the laptop", "from the desktop", "from the mini"] {
            XCTAssertTrue(merged.content.contains(text), "lost \(text)")
        }
    }

    func testAppendedSectionsReadOldestFirst() throws {
        let merged = try XCTUnwrap(ConflictResolver.merge([
            note("oldest", updated: 100),
            note("middle", updated: 200),
            note("newest", updated: 300)
        ], now: now))
        let oldest = try XCTUnwrap(merged.content.range(of: "oldest"))
        let middle = try XCTUnwrap(merged.content.range(of: "middle"))
        XCTAssertLessThan(oldest.lowerBound, middle.lowerBound)
    }

    /// Losing a tag in a merge is data loss too, just quieter.
    func testLabelsFromEveryVersionAreKept() throws {
        let merged = try XCTUnwrap(ConflictResolver.merge([
            note("a", labels: ["work"], updated: 100),
            note("b", labels: ["urgent"], updated: 200)
        ], now: now))
        XCTAssertEqual(Set(merged.labels), ["work", "urgent"])
    }

    func testLabelsAreNotDuplicated() throws {
        let merged = try XCTUnwrap(ConflictResolver.merge([
            note("a", labels: ["work"], updated: 100),
            note("b", labels: ["work", "urgent"], updated: 200)
        ], now: now))
        XCTAssertEqual(merged.labels.count, 2)
    }

    func testEmptyVersionsAreIgnored() throws {
        let merged = try XCTUnwrap(ConflictResolver.merge([
            note("", updated: 100), note("real text", updated: 200)
        ], now: now))
        XCTAssertEqual(merged.content, "real text")
    }

    func testMergeKeepsTheWinnersIdentity() throws {
        let id = UUID()
        let merged = try XCTUnwrap(ConflictResolver.merge([
            note("a", updated: 100, id: id), note("b", updated: 200, id: id)
        ], now: now))
        XCTAssertEqual(merged.id, id)
    }

    // MARK: - needsMerge

    func testIdenticalCopiesDoNotNeedMerging() {
        XCTAssertFalse(ConflictResolver.needsMerge([note("same", updated: 1), note("same", updated: 2)]))
    }

    func testDifferentBodiesNeedMerging() {
        XCTAssertTrue(ConflictResolver.needsMerge([note("a", updated: 1), note("b", updated: 2)]))
    }

    func testDifferentLabelsAloneNeedMerging() {
        XCTAssertTrue(ConflictResolver.needsMerge([
            note("same", labels: ["work"], updated: 1),
            note("same", labels: [], updated: 2)
        ]))
    }

    func testASingleVersionNeverNeedsMerging() {
        XCTAssertFalse(ConflictResolver.needsMerge([note("a", updated: 1)]))
        XCTAssertFalse(ConflictResolver.needsMerge([]))
    }

    func testWhitespaceOnlyDifferencesDoNotCountAsConflicts() {
        XCTAssertFalse(ConflictResolver.needsMerge([
            note("text", updated: 1), note("  text\n", updated: 2)
        ]))
    }
}

final class TrashTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeNote(_ content: String = "n") -> Note {
        Note(
            id: UUID(), title: "", content: content,
            positionX: 0, positionY: 0, width: 240, height: 200,
            collapsed: false, color: .yellow, labels: [],
            createdAt: Date(), updatedAt: Date()
        )
    }

    private let formats: [StorageFormat] = [.json, .markdown]

    func testDeletingForeverMovesTheNoteToTheTrash() throws {
        for format in formats {
            let store = NoteStore(rootURL: root.appendingPathComponent("\(format)"), format: format)
            let note = makeNote("recoverable")
            store.save(note)
            store.archive(note)
            store.deleteForever(note)

            XCTAssertTrue(store.loadArchived().isEmpty, "\(format)")
            XCTAssertEqual(store.loadTrashed().map(\.content), ["recoverable"],
                           "\(format): delete should be recoverable")
        }
    }

    func testATrashedNoteCanBeRestored() throws {
        for format in formats {
            let store = NoteStore(rootURL: root.appendingPathComponent("restore-\(format)"), format: format)
            let note = makeNote("came back")
            store.save(note)
            store.archive(note)
            store.deleteForever(note)

            let trashed = try XCTUnwrap(store.loadTrashed().first, "\(format)")
            store.restoreFromTrash(trashed)

            XCTAssertEqual(store.loadArchived().map(\.content), ["came back"], "\(format)")
            XCTAssertTrue(store.loadTrashed().isEmpty, "\(format)")
        }
    }

    func testTrashedNotesAreNotListedAsActiveOrArchived() {
        let store = NoteStore(rootURL: root, format: .json)
        let note = makeNote()
        store.save(note)
        store.archive(note)
        store.deleteForever(note)

        XCTAssertTrue(store.loadActive().isEmpty)
        XCTAssertTrue(store.loadArchived().isEmpty)
    }

    /// Two notes created in the same second get the same Markdown filename, and
    /// the trash is the one place we must not overwrite anything.
    func testTwoDeletionsWithTheSameFilenameBothSurvive() throws {
        let store = NoteStore(rootURL: root, format: .markdown)
        let created = Date(timeIntervalSince1970: 1_700_000_000)

        for content in ["first", "second"] {
            let note = Note(
                id: UUID(), title: "", content: content,
                positionX: 0, positionY: 0, width: 240, height: 200,
                collapsed: false, color: .yellow, labels: [],
                createdAt: created, updatedAt: created
            )
            store.save(note)
            store.archive(note)
            store.deleteForever(note)
        }

        XCTAssertEqual(Set(store.loadTrashed().map(\.content)), ["first", "second"],
                       "one deletion overwrote the other in the trash")
    }

    func testRecentlyTrashedNotesAreNotPurged() {
        let store = NoteStore(rootURL: root, format: .json)
        let note = makeNote()
        store.save(note)
        store.archive(note)
        store.deleteForever(note)

        XCTAssertEqual(store.purgeExpiredTrash(), 0)
        XCTAssertEqual(store.loadTrashed().count, 1)
    }

    func testExpiredNotesArePurged() throws {
        let store = NoteStore(rootURL: root, format: .json)
        let note = makeNote()
        store.save(note)
        store.archive(note)
        store.deleteForever(note)

        // Pretend the deletion happened well past the retention window.
        let future = Date().addingTimeInterval(NoteStore.trashRetention + 3600)
        XCTAssertEqual(store.purgeExpiredTrash(now: future), 1)
        XCTAssertTrue(store.loadTrashed().isEmpty)
    }

    /// Retention has to run from the deletion. Moving a file preserves its
    /// modification date, so a note last edited months ago used to be purged
    /// the moment it was deleted — the one thing the trash exists to prevent.
    func testANoteDeletedTodaySurvivesEvenIfItWasEditedLongAgo() throws {
        let store = NoteStore(rootURL: root, format: .json)
        let note = makeNote()
        store.save(note)
        store.archive(note)

        // Age the file on disk well past the retention window, then delete it.
        let archived = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("archive", isDirectory: true),
                includingPropertiesForKeys: nil
            ).first
        )
        let longAgo = Date().addingTimeInterval(-(NoteStore.trashRetention + 86_400))
        try FileManager.default.setAttributes(
            [.modificationDate: longAgo], ofItemAtPath: archived.path
        )
        store.deleteForever(note)

        XCTAssertEqual(store.purgeExpiredTrash(), 0)
        XCTAssertEqual(store.loadTrashed().count, 1)
    }

    func testPurgingAnEmptyTrashIsHarmless() {
        let store = NoteStore(rootURL: root, format: .json)
        XCTAssertEqual(store.purgeExpiredTrash(), 0)
    }

    func testTrashLivesInsideTheStorageRoot() {
        let store = NoteStore(rootURL: root, format: .json)
        XCTAssertEqual(store.trashURL.lastPathComponent, ".trash")
        XCTAssertEqual(store.trashURL.deletingLastPathComponent().path, root.path)
    }

    func testTheTrashTabListsDeletedNotes() throws {
        let store = NoteStore(rootURL: root, format: .json)
        let note = makeNote("deleted")
        store.save(note)
        store.archive(note)
        store.deleteForever(note)

        let panel = NotesPanelController(store: store, onActivate: { _ in })
        XCTAssertEqual(panel.rowCount, 0, "an active-tab panel should not show trash")

        panel.showMode(.trash)
        XCTAssertEqual(panel.visibleTitles, ["deleted"])
    }

    func testPuttingBackFromTheTrashTabReturnsTheNoteToArchive() throws {
        let store = NoteStore(rootURL: root, format: .json)
        let note = makeNote("put back")
        store.save(note)
        store.archive(note)
        store.deleteForever(note)

        let panel = NotesPanelController(store: store, onActivate: { _ in })
        panel.showMode(.trash)
        panel.putBackFirstRow()

        XCTAssertTrue(store.loadTrashed().isEmpty)
        XCTAssertEqual(store.loadArchived().map(\.content), ["put back"])
    }

    func testResolvingConflictsOnACleanStoreChangesNothing() {
        let store = NoteStore(rootURL: root, format: .json)
        store.save(makeNote("untouched"))
        XCTAssertEqual(store.resolveConflicts(), 0)
        XCTAssertEqual(store.loadActive().map(\.content), ["untouched"])
    }
}
