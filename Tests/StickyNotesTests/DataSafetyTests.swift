import AppKit
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

    // MARK: - Titles

    func testWhenOnlyTheTitleDiffersTheNewestVersionIsReturnedAsItIs() throws {
        var older = note("same", updated: 100)
        older.title = "Old name"
        var newer = note("same", updated: 200)
        newer.title = "New name"
        let merged = try XCTUnwrap(ConflictResolver.merge([newer, older], now: now))
        XCTAssertEqual(merged.title, "New name")
        XCTAssertEqual(merged.content, "same")
        XCTAssertEqual(merged.updatedAt, newer.updatedAt, "nothing was merged, so nothing is restamped")
    }

    func testATitleThatLosesAMergeIsKeptAsAnAlsoTitledLine() throws {
        var older = note("shared\nonly older", updated: 100)
        older.title = "Old name"
        var newer = note("shared\nonly newer", updated: 200)
        newer.title = "New name"
        let merged = try XCTUnwrap(ConflictResolver.merge([older, newer], now: now))
        XCTAssertEqual(merged.title, "New name")
        XCTAssertTrue(merged.content.contains("only older"))
        XCTAssertTrue(merged.content.hasSuffix("Also titled: Old name"), merged.content)
    }

    func testAMergeGivesAnUntitledWinnerTheOtherTitleInsteadOfAnAlsoTitledLine() throws {
        var older = note("shared\nonly older", updated: 100)
        older.title = "Old name"
        var newer = note("shared\nonly newer", updated: 200)
        newer.title = ""
        let merged = try XCTUnwrap(ConflictResolver.merge([older, newer], now: now))
        XCTAssertEqual(merged.title, "Old name")
        XCTAssertFalse(merged.content.contains("Also titled"))
    }

    func testMergingTheSameVersionsAgainDoesNotStackAlsoTitledLines() throws {
        var older = note("shared\nonly older", updated: 100)
        older.title = "Old name"
        var newer = note("shared\nonly newer", updated: 200)
        newer.title = "New name"
        let once = try XCTUnwrap(ConflictResolver.merge([older, newer], now: now))
        let twice = try XCTUnwrap(ConflictResolver.merge([once, older], now: now.addingTimeInterval(60)))
        XCTAssertEqual(twice.content, once.content)
    }

    // MARK: - Line-based merge rule

    func testAConflictVersionWithNothingNewLeavesTheNoteAlone() throws {
        let merged = try XCTUnwrap(ConflictResolver.merge([
            note("a\nb", updated: 100), note("a\nX\nb", updated: 200)
        ], now: now))
        XCTAssertEqual(merged.content, "a\nX\nb")
    }

    func testAnOlderSaveCutMidWordIsNotAppended() throws {
        let merged = try XCTUnwrap(ConflictResolver.merge([
            note("line one\nline tw", updated: 100),
            note("line one\nline two\nline three", updated: 200),
            note("line one\na new line\nline two\nline three", updated: 300)
        ], now: now))
        XCTAssertEqual(merged.content, "line one\na new line\nline two\nline three")
    }

    func testAnOutsideAppendIsTakenWithoutAConflictBlock() throws {
        let merged = try XCTUnwrap(ConflictResolver.merge([
            note("a\nb", updated: 200), note("a\nb\nc", updated: 100)
        ], now: now))
        XCTAssertEqual(merged.content, "a\nb\nc")
    }

    func testAVersionMissingARepeatedLineIsNotTakenAsTheBase() throws {
        let merged = try XCTUnwrap(ConflictResolver.merge([
            note("- [ ]\n- [ ]\nb", updated: 200), note("- [ ]\nb\nc", updated: 100)
        ], now: now))
        XCTAssertTrue(merged.content.hasPrefix("- [ ]\n- [ ]\nb"), "got \(merged.content)")
        XCTAssertTrue(merged.content.hasSuffix("- [ ]\nb\nc"), "got \(merged.content)")
    }

    func testALabelOnAVersionWithNothingNewInItsBodyIsKept() throws {
        let merged = try XCTUnwrap(ConflictResolver.merge([
            note("a\nb", updated: 200), note("a", labels: ["work"], updated: 100)
        ], now: now))
        XCTAssertEqual(merged.content, "a\nb")
        XCTAssertEqual(merged.labels, ["work"])
    }

    func testTwoGenuinelyDivergentVersionsStillGetADivider() throws {
        let merged = try XCTUnwrap(ConflictResolver.merge([
            note("a\nmine", updated: 200), note("a\ntheirs", updated: 100)
        ], now: now))
        XCTAssertTrue(merged.content.hasPrefix("a\nmine"), "got \(merged.content)")
        XCTAssertEqual(merged.content.components(separatedBy: "Conflicted copy").count, 2)
        XCTAssertTrue(merged.content.hasSuffix("theirs"), "got \(merged.content)")
    }

    func testTwoDivergentVersionsWithTheSameTextAreAppendedOnce() throws {
        let merged = try XCTUnwrap(ConflictResolver.merge([
            note("base\nmine", updated: 300),
            note("base\ntheirs", updated: 100),
            note("base\ntheirs", updated: 200)
        ], now: now))
        XCTAssertEqual(merged.content.components(separatedBy: "theirs").count, 2, "got \(merged.content)")
    }

    func testBodyMergeIntoAnEmptyFileTakesTheOtherTextWithoutADivider() {
        let merged = ConflictResolver.mergeBodies(
            local: "", external: "first line", externalDate: now, now: now
        )
        XCTAssertEqual(merged, "first line")
    }

    func testBodyMergeTakesAnOutsideAppendWithoutADivider() {
        let merged = ConflictResolver.mergeBodies(
            local: "a\nb", external: "a\nb\nc", externalDate: now, now: now
        )
        XCTAssertEqual(merged, "a\nb\nc")
    }

    func testBodyMergeDropsAnOlderCopyThatIsNotASubstring() {
        let merged = ConflictResolver.mergeBodies(
            local: "a\nX\nb", external: "a\nb", externalDate: now, now: now
        )
        XCTAssertEqual(merged, "a\nX\nb")
    }

    // MARK: - Repeated lines, order and cleared notes

    func testAnOutsideAppendOfARepeatedLineIsKept() {
        let merged = ConflictResolver.mergeBodies(
            local: "Mon\nrun\nTue", external: "Mon\nrun\nTue\nrun", externalDate: now, now: now
        )
        XCTAssertEqual(merged, "Mon\nrun\nTue\nrun")
    }

    func testAnAppendedCopyOfAChecklistLineIsKept() {
        let merged = ConflictResolver.mergeBodies(
            local: "- [ ] milk\n- [ ] eggs",
            external: "- [ ] milk\n- [ ] eggs\n- [ ] milk",
            externalDate: now, now: now
        )
        XCTAssertEqual(merged, "- [ ] milk\n- [ ] eggs\n- [ ] milk")
    }

    func testAConflictVersionThatOnlyAddsARepeatedLineIsKept() throws {
        let merged = try XCTUnwrap(ConflictResolver.merge([
            note("Mon\nrun\nTue", updated: 200), note("Mon\nrun\nTue\nrun", updated: 100)
        ], now: now))
        XCTAssertEqual(merged.content, "Mon\nrun\nTue\nrun")
    }

    func testARepeatedLineThatTheWinnerAlreadyHasTwiceAddsNothing() throws {
        let merged = try XCTUnwrap(ConflictResolver.merge([
            note("run\nTue\nrun", updated: 200), note("run\nrun", updated: 100)
        ], now: now))
        XCTAssertEqual(merged.content, "run\nTue\nrun")
    }

    func testAReorderedNoteIsNotRevertedByASupersetInAnotherOrder() throws {
        let merged = try XCTUnwrap(ConflictResolver.merge([
            note("C\nA\nB", updated: 200), note("A\nB\nC\nD", updated: 100)
        ], now: now))
        XCTAssertTrue(merged.content.hasPrefix("C\nA\nB"), "got \(merged.content)")
        XCTAssertTrue(merged.content.contains("Conflicted copy"), "got \(merged.content)")
    }

    func testAClearedNoteIsNotRevertedByAnOlderCopy() throws {
        let merged = try XCTUnwrap(ConflictResolver.merge([
            note("", updated: 200), note("old text", updated: 100)
        ], now: now))
        XCTAssertTrue(merged.content.contains("Conflicted copy"), "got \(merged.content)")
        XCTAssertTrue(merged.content.contains("old text"), "got \(merged.content)")
    }

    func testABodyMergeDoesNotRevertAReorder() {
        let merged = ConflictResolver.mergeBodies(
            local: "C\nA\nB", external: "A\nB\nC\nD", externalDate: now, now: now
        )
        XCTAssertTrue(merged.hasPrefix("C\nA\nB"), "got \(merged)")
        XCTAssertTrue(merged.contains("Conflicted copy"), "got \(merged)")
    }

    func testVersionsFromThisProcessAreDroppedOnlyWhenTheFileIsOursToo() {
        let current = note("current", updated: 200)
        let own = note("older own save", updated: 100)
        let theirs = note("from another Mac", updated: 100)
        let isOurs: (Note) -> Bool = { $0.content == "older own save" }

        let ours = ConflictResolver.versionsToMerge(
            current: current, currentIsOurNewest: true, conflicts: [own, theirs], isOurs: isOurs
        )
        XCTAssertEqual(ours.map(\.content), ["current", "from another Mac"])

        let notOurs = ConflictResolver.versionsToMerge(
            current: current, currentIsOurNewest: false, conflicts: [own, theirs], isOurs: isOurs
        )
        XCTAssertEqual(notOurs.count, 3)
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

    func testDeletingForeverMovesTheNoteToTheTrash() throws {
        let store = NoteStore(rootURL: root)
        let note = makeNote("recoverable")
        store.save(note)
        store.archive(note)
        store.deleteForever(note)

        XCTAssertTrue(store.loadArchived().isEmpty)
        XCTAssertEqual(store.loadTrashed().map(\.content), ["recoverable"],
                       "delete should be recoverable")
    }

    func testATrashedNoteCanBeRestored() throws {
        let store = NoteStore(rootURL: root)
        let note = makeNote("came back")
        store.save(note)
        store.archive(note)
        store.deleteForever(note)

        let trashed = try XCTUnwrap(store.loadTrashed().first)
        store.restoreFromTrash(trashed)

        XCTAssertEqual(store.loadArchived().map(\.content), ["came back"])
        XCTAssertTrue(store.loadTrashed().isEmpty)
    }

    func testTrashedNotesAreNotListedAsActiveOrArchived() {
        let store = NoteStore(rootURL: root)
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
        let store = NoteStore(rootURL: root)
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
        let store = NoteStore(rootURL: root)
        let note = makeNote()
        store.save(note)
        store.archive(note)
        store.deleteForever(note)

        XCTAssertEqual(store.purgeExpiredTrash(), 0)
        XCTAssertEqual(store.loadTrashed().count, 1)
    }

    func testExpiredNotesArePurged() throws {
        let store = NoteStore(rootURL: root)
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
        let store = NoteStore(rootURL: root)
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
        let store = NoteStore(rootURL: root)
        XCTAssertEqual(store.purgeExpiredTrash(), 0)
    }

    func testTrashLivesInsideTheStorageRoot() {
        let store = NoteStore(rootURL: root)
        XCTAssertEqual(store.trashURL.lastPathComponent, ".trash")
        XCTAssertEqual(store.trashURL.deletingLastPathComponent().path, root.path)
    }

    @MainActor func testTheTrashTabListsDeletedNotes() throws {
        let store = NoteStore(rootURL: root)
        let note = makeNote("deleted")
        store.save(note)
        store.archive(note)
        store.deleteForever(note)

        let panel = NotesPanelController(store: store, onActivate: { _ in })
        XCTAssertEqual(panel.rowCount, 0, "an active-tab panel should not show trash")

        panel.showMode(.trash)
        XCTAssertEqual(panel.visibleTitles, ["deleted"])
    }

    @MainActor func testPuttingBackFromTheTrashTabReturnsTheNoteToArchive() throws {
        let store = NoteStore(rootURL: root)
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
        let store = NoteStore(rootURL: root)
        store.save(makeNote("untouched"))
        XCTAssertEqual(store.resolveConflicts(), 0)
        XCTAssertEqual(store.loadActive().map(\.content), ["untouched"])
    }
}

final class ConflictSweepTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConflictSweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(rootURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func savedNote(_ content: String) -> Note {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        note.content = content
        store.save(note)
        return note
    }

    private func fileURL() throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: store.activeURL, includingPropertiesForKeys: nil)
        return try XCTUnwrap(files.first { $0.pathExtension == "md" })
    }

    private func rawNote(id: UUID, content: String, updated: String) -> String {
        "---\nid: \(id.uuidString)\nupdated: \(updated)\n---\n\(content)\n"
    }

    /// A stand-in for an `NSFileVersion`: a real file holding `content`, so
    /// the sweep reads it exactly as it would a downloaded conflict version.
    /// Nil content makes a version that cannot be read.
    private func version(
        of note: Note, content: String?, resolved: @escaping () -> Void = {}
    ) throws -> NoteStore.ConflictVersionHandle {
        let url = root.appendingPathComponent("version-\(UUID().uuidString).md")
        if let content {
            try rawNote(id: note.id, content: content, updated: "1970-01-01T00:00:01Z")
                .write(to: url, atomically: true, encoding: .utf8)
        }
        return .init(url: url, markResolved: resolved)
    }

    func testAnUnreadableConflictVersionIsKeptForLater() throws {
        let note = savedNote("current text")
        var resolved: [String] = []
        var removed = false
        let readable = try version(of: note, content: "from the desktop") { resolved.append("readable") }
        let missing = try version(of: note, content: nil) { resolved.append("missing") }
        store.conflictVersionsProvider = { _ in [readable, missing] }
        store.otherVersionsRemover = { _ in removed = true }

        XCTAssertEqual(store.resolveConflicts(), 1)

        XCTAssertEqual(resolved, ["readable"], "the unreadable version must stay unresolved")
        XCTAssertFalse(removed, "other versions were removed while one was still unread")
        let content = try XCTUnwrap(store.loadNote(id: note.id)).content
        XCTAssertTrue(content.contains("from the desktop"), "got \(content)")
    }

    func testAnUnreadableCurrentFileLeavesItsVersionsUnresolved() throws {
        let note = savedNote("current text")
        try Data([0xFF, 0xFE, 0x00]).write(to: fileURL())
        var resolved = 0
        var removed = false
        let other = try version(of: note, content: "the only readable copy") { resolved += 1 }
        store.conflictVersionsProvider = { _ in [other] }
        store.otherVersionsRemover = { _ in removed = true }

        XCTAssertEqual(store.resolveConflicts(), 0)

        XCTAssertEqual(resolved, 0, "a version was resolved while the current file was unreadable")
        XCTAssertFalse(removed)
    }

    func testEveryReadVersionIsResolvedAndTheOthersRemoved() throws {
        let note = savedNote("current text")
        var resolved = 0
        var removed = false
        let other = try version(of: note, content: "from the desktop") { resolved += 1 }
        store.conflictVersionsProvider = { _ in [other] }
        store.otherVersionsRemover = { _ in removed = true }

        store.resolveConflicts()

        XCTAssertEqual(resolved, 1)
        XCTAssertTrue(removed)
    }

    /// Text that only exists in an older version this process never wrote is
    /// not proved to be the user's own, so it is merged, not thrown away.
    func testTextOnlyInAnUntrackedOlderVersionIsMerged() throws {
        let note = savedNote("current text")
        let old = try version(of: note, content: "current tex\nold line")
        store.conflictVersionsProvider = { _ in [old] }
        store.otherVersionsRemover = { _ in }

        XCTAssertEqual(store.resolveConflicts(), 1)

        let content = try XCTUnwrap(store.loadNote(id: note.id)).content
        XCTAssertTrue(content.contains("old line"), "got \(content)")
    }

    func testAnOlderOwnSaveWithATypoFixedLaterIsDropped() throws {
        var note = savedNote("teh cat\nsat down")
        let typo = try version(of: note, content: "teh cat\nsat down")
        note.content = "the cat\nsat down"
        note.updatedAt = Date()
        store.save(note)
        var resolved = 0
        store.otherVersionsRemover = { _ in }
        let counting = NoteStore.ConflictVersionHandle(url: typo.url) { resolved += 1 }
        store.conflictVersionsProvider = { _ in [counting] }

        XCTAssertEqual(store.resolveConflicts(), 0)

        XCTAssertEqual(try XCTUnwrap(store.loadNote(id: note.id)).content, "the cat\nsat down")
        XCTAssertEqual(resolved, 1)
    }

    private func taggedVersion(
        of note: Note, content: String, title: String, labels: String, updated: String
    ) throws -> NoteStore.ConflictVersionHandle {
        let url = root.appendingPathComponent("version-\(UUID().uuidString).md")
        try "---\nid: \(note.id.uuidString)\ntitle: \"\(title)\"\nlabels: \(labels)\nupdated: \(updated)\n---\n\(content)\n"
            .write(to: url, atomically: true, encoding: .utf8)
        return .init(url: url, markResolved: {})
    }

    func testAnOlderOwnBodyCarryingAnotherMacsLabelKeepsTheLabel() throws {
        var note = savedNote("A")
        let tagged = try taggedVersion(
            of: note, content: "A", title: "", labels: "[work]", updated: "1970-01-01T00:00:01Z"
        )
        note.content = "A\nB"
        note.updatedAt = Date()
        store.save(note)
        store.conflictVersionsProvider = { _ in [tagged] }
        store.otherVersionsRemover = { _ in }

        store.resolveConflicts()

        let merged = try XCTUnwrap(store.loadNote(id: note.id))
        XCTAssertEqual(merged.labels, ["work"])
        XCTAssertEqual(merged.content.trimmingCharacters(in: .whitespacesAndNewlines), "A\nB")
    }

    func testAnOlderOwnBodyCarryingAnotherMacsNewerTitleKeepsTheTitle() throws {
        var note = savedNote("A")
        let renamed = try taggedVersion(
            of: note, content: "A", title: "Groceries", labels: "[]", updated: "2100-01-01T00:00:00Z"
        )
        note.content = "A\nB"
        note.updatedAt = Date()
        store.save(note)
        store.conflictVersionsProvider = { _ in [renamed] }
        store.otherVersionsRemover = { _ in }

        store.resolveConflicts()

        let merged = try XCTUnwrap(store.loadNote(id: note.id))
        XCTAssertEqual(merged.title, "Groceries")
        XCTAssertEqual(merged.content.trimmingCharacters(in: .whitespacesAndNewlines), "A\nB")
    }

    /// The race: this Mac saves, the other Mac's file arrives and the idle
    /// window adopts it, then any save writes the adopted text back. The
    /// older own save now holds text the file lacks and must be merged.
    func testAnOwnVersionIsMergedAfterAdoptingAnotherMacsFile() throws {
        var note = savedNote("A\nmine")
        let own = try version(of: note, content: "A\nmine")
        try rawNote(id: note.id, content: "A\ntheirs", updated: "2026-01-01T00:00:00Z")
            .write(to: fileURL(), atomically: true, encoding: .utf8)
        XCTAssertEqual(try XCTUnwrap(store.loadNote(id: note.id)).content.trimmingCharacters(in: .whitespacesAndNewlines), "A\ntheirs")
        note.content = "A\ntheirs\nmoved the window"
        note.updatedAt = Date()
        store.save(note)
        store.conflictVersionsProvider = { _ in [own] }
        store.otherVersionsRemover = { _ in }

        XCTAssertEqual(store.resolveConflicts(), 1)

        let content = try XCTUnwrap(store.loadNote(id: note.id)).content
        XCTAssertTrue(content.contains("mine"), "lost the text from the older save: \(content)")
        XCTAssertTrue(content.contains("theirs"), "got \(content)")
    }

    /// The record of what this process wrote is in memory only, so after a
    /// relaunch nothing can be proved and every version is merged.
    func testAnOldVersionIsMergedAfterARelaunch() throws {
        var note = savedNote("teh cat\nsat down")
        let typo = try version(of: note, content: "teh cat\nsat down")
        note.content = "the cat\nsat down"
        note.updatedAt = Date()
        store.save(note)

        WriteLineage.reset()
        let relaunched = NoteStore(rootURL: root)
        relaunched.conflictVersionsProvider = { _ in [typo] }
        relaunched.otherVersionsRemover = { _ in }

        XCTAssertEqual(relaunched.resolveConflicts(), 1)

        let content = try XCTUnwrap(relaunched.loadNote(id: note.id)).content
        XCTAssertTrue(content.contains("teh cat"), "got \(content)")
    }

    /// Mac B saved an older body again while Mac A had moved on, so the
    /// current file holds an older body of ours and the conflict holds our
    /// newer one. The newer text exists nowhere else.
    func testANewerOwnSaveIsKeptWhenTheCurrentFileHoldsAnOlderOwnBody() throws {
        var note = savedNote("A")
        let url = try fileURL()
        note.content = "A\nnew line"
        note.updatedAt = Date()
        store.save(note)
        let newer = try version(of: note, content: "A\nnew line")
        try rawNote(id: note.id, content: "A", updated: "2026-12-01T00:00:00Z")
            .write(to: url, atomically: true, encoding: .utf8)
        store.conflictVersionsProvider = { _ in [newer] }
        store.otherVersionsRemover = { _ in }

        XCTAssertEqual(store.resolveConflicts(), 1)

        let content = try XCTUnwrap(store.loadNote(id: note.id)).content
        XCTAssertTrue(content.contains("new line"), "lost the newer save: \(content)")
    }

    /// The same, when the sweep was skipped: the window adopts the older body
    /// and the user types on from it.
    func testANewerOwnSaveIsKeptAfterTheWindowAdoptsAnOlderOwnBody() throws {
        var note = savedNote("A")
        let url = try fileURL()
        note.content = "A\nnew line"
        note.updatedAt = Date()
        store.save(note)
        let newer = try version(of: note, content: "A\nnew line")
        try rawNote(id: note.id, content: "A", updated: "2026-12-01T00:00:00Z")
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try XCTUnwrap(store.loadNote(id: note.id)).content
            .trimmingCharacters(in: .whitespacesAndNewlines), "A")
        note.content = "A!"
        note.updatedAt = Date()
        store.save(note)
        store.conflictVersionsProvider = { _ in [newer] }
        store.otherVersionsRemover = { _ in }

        store.resolveConflicts()

        let content = try XCTUnwrap(store.loadNote(id: note.id)).content
        XCTAssertTrue(content.contains("new line"), "lost the newer save: \(content)")
    }

    /// A second store on the same folder (the daily note keeps one for
    /// attachments) must honour what the first one wrote.
    func testASecondStoreOnTheSameFolderHonoursTheFirstStoresWrites() throws {
        var note = savedNote("teh cat\nsat down")
        let typo = try version(of: note, content: "teh cat\nsat down")
        note.content = "the cat\nsat down"
        note.updatedAt = Date()
        store.save(note)

        let second = NoteStore(rootURL: root)
        second.conflictVersionsProvider = { _ in [typo] }
        second.otherVersionsRemover = { _ in }

        XCTAssertEqual(second.resolveConflicts(), 0)
        XCTAssertEqual(try XCTUnwrap(second.loadNote(id: note.id)).content, "the cat\nsat down")
    }
}
