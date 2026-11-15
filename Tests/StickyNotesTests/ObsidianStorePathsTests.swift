import XCTest
@testable import StickyNotesKit

/// The properties of the file in place are its own: every path in the store that
/// merges versions or rewrites a file keeps them, and a save leaves the lines
/// of the app's own keys alone when their value did not change.
final class ObsidianStorePathsTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ObsidianStore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private let tags = "tags:\n  - project/x\naliases: [Plan B]"

    private func note(_ body: String, id: UUID = UUID(), updated: TimeInterval = 1_700_000_500) -> Note {
        Note(
            id: id, title: "T", content: body,
            positionX: 120, positionY: 240, width: 300, height: 220,
            collapsed: false, color: .blue, labels: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }

    /// A note file as Obsidian leaves it, with `extra` among the app's keys.
    private func file(
        _ id: UUID, in dir: URL, name: String? = nil, extra: String = "", body: String,
        updated: String = "2020-01-01T00:00:00Z"
    ) throws -> URL {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name ?? "\(id.uuidString).md")
        let extraBlock = extra.isEmpty ? "" : extra + "\n"
        try "---\nid: \(id.uuidString)\ntitle: T\n\(extraBlock)updated: \(updated)\n---\n\n\(body)"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Store paths that merge versions

    func testAJSONMergeKeepsThePropertiesOfTheMarkdownFileInPlace() throws {
        let id = UUID()
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        let md = try file(id, in: notes, extra: tags, body: "markdown text")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(note("newer json text", id: id, updated: 1_900_000_000))
            .write(to: notes.appendingPathComponent("\(id.uuidString).json"))

        _ = NoteStore(rootURL: root)

        let result = try text(md)
        XCTAssertTrue(result.contains("newer json text"), result)
        XCTAssertTrue(result.contains(tags), result)
    }

    func testCopyingANoteIntoARootThatHoldsItKeepsThePropertiesOfTheFileThere() throws {
        let id = UUID()
        let store = NoteStore(rootURL: root.appendingPathComponent("old", isDirectory: true))
        store.save(note("from the old root", id: id, updated: 1_900_000_000))
        let newRoot = root.appendingPathComponent("new", isDirectory: true)
        let target = try file(id, in: newRoot.appendingPathComponent("notes", isDirectory: true),
                              extra: tags, body: "from the old root")

        store.reconfigure(rootURL: newRoot)

        let result = try text(target)
        XCTAssertTrue(result.contains(tags), result)
    }

    func testAConflictSweepKeepsThePropertiesOfTheFileInPlace() throws {
        let id = UUID()
        let store = NoteStore(rootURL: root)
        let notes = store.activeURL
        let current = try file(id, in: notes, extra: tags, body: "current text")
        let version = try file(id, in: root.appendingPathComponent("versions"), name: "version.md",
                               body: "newer text from the other Mac", updated: "2030-01-01T00:00:00Z")
        store.conflictVersionsProvider = { _ in [.init(url: version, markResolved: {})] }
        store.otherVersionsRemover = { _ in }

        store.resolveConflicts()

        let result = try text(current)
        XCTAssertTrue(result.contains("newer text from the other Mac"), result)
        XCTAssertTrue(result.contains(tags), result)
    }

    func testGivingADuplicateANewIdLeavesANestedIdAlone() throws {
        let id = UUID()
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        let nested = "source:\n  id: 123"
        _ = try file(id, in: notes, name: "a.md", body: "first")
        let copy = try file(id, in: notes, name: "b.md", extra: nested, body: "second")
        // The nested `id:` comes before the note's own in this file.
        try text(copy).replacingOccurrences(of: "id: \(id.uuidString)\ntitle: T\n\(nested)",
                                            with: "title: T\n\(nested)\nid: \(id.uuidString)")
            .write(to: copy, atomically: true, encoding: .utf8)

        let loaded = NoteStore(rootURL: root).loadActive()

        XCTAssertEqual(Set(loaded.map(\.id)).count, 2, "the duplicate keeps its id")
        let result = try text(copy)
        XCTAssertTrue(result.contains("source:\n  id: 123\n"), result)
        XCTAssertEqual(result.components(separatedBy: "\nid: ").count - 1, 1, result)
    }

    func testANoteDocumentOpenedOverAFileWithNewPropertiesDoesNotOverwriteThem() throws {
        let store = NoteStore(rootURL: root)
        let saved = note("start")
        store.save(saved)
        // Obsidian adds properties; the window is handed the older copy.
        let url = try XCTUnwrap(fm.contentsOfDirectory(at: store.activeURL, includingPropertiesForKeys: nil).first)
        let original = try text(url)
        try original.replacingOccurrences(of: "---\n\nstart", with: "\(tags)\n---\n\nstart")
            .write(to: url, atomically: true, encoding: .utf8)
        let clock = ManualClock()
        let document = NoteDocument(note: saved, repository: store, scheduler: TestScheduler(clock: clock), clock: clock)

        document.setBody("start\nmore")
        document.flush()

        let result = try text(url)
        XCTAssertTrue(result.contains(tags), result)
    }

    // MARK: - What a save writes for the app's own keys

    /// A file as the app and Obsidian leave it: unquoted title, block labels,
    /// a comment, a plugin's own keys.
    private let obsidianFile = """
    ---
    # plugin
    id: 6F0E0F00-0000-4000-8000-000000000001
    title: Meeting
    color: blue
    labels:
      - work
      - home
    tags: [a]
    positionX: 120.00
    positionY: 240.00
    width: 300.00
    height: 220.00
    collapsed: false
    float: floating
    created: 2023-11-14T22:13:20Z
    updated: 2023-11-14T22:21:40Z
    summary: |
      two
        lines
    ---

    Body
    """

    func testASaveThroughTheStoreWritesAFileItDidNotChangeByteForByte() throws {
        let store = NoteStore(rootURL: root)
        let url = root.appendingPathComponent("notes/x.md")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try obsidianFile.write(to: url, atomically: true, encoding: .utf8)
        let loaded = try XCTUnwrap(store.loadActive().first)

        XCTAssertEqual(store.recoveryText(for: loaded), obsidianFile)
    }

    func testARenamedTitleKeepsAnUnquotedStyleWhenItIsSafe() throws {
        let store = NoteStore(rootURL: root)
        let url = root.appendingPathComponent("notes/x.md")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try obsidianFile.write(to: url, atomically: true, encoding: .utf8)
        var loaded = try XCTUnwrap(store.loadActive().first)

        loaded.title = "Weekly sync"
        XCTAssertTrue(store.recoveryText(for: loaded).contains("\ntitle: Weekly sync\n"))
        loaded.title = "Plan: Q3"
        XCTAssertTrue(store.recoveryText(for: loaded).contains("\ntitle: \"Plan: Q3\"\n"))
        loaded.title = "true"
        XCTAssertTrue(store.recoveryText(for: loaded).contains("\ntitle: \"true\"\n"))
    }

    func testANewNotesTitleIsQuoted() {
        let store = NoteStore(rootURL: root)
        XCTAssertTrue(store.recoveryText(for: note("b")).contains("\ntitle: \"T\"\n"))
    }

    func testACreatedDateInAnotherFormatIsLeftAsWritten() throws {
        let store = NoteStore(rootURL: root)
        let url = root.appendingPathComponent("notes/x.md")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try obsidianFile.replacingOccurrences(of: "created: 2023-11-14T22:13:20Z", with: "created: 2026-11-15 10:00")
            .write(to: url, atomically: true, encoding: .utf8)
        var loaded = try XCTUnwrap(store.loadActive().first)
        loaded.content = "Body changed"
        loaded.updatedAt = Date(timeIntervalSince1970: 1_900_000_000)

        let written = store.recoveryText(for: loaded)

        XCTAssertTrue(written.contains("\ncreated: 2026-11-15 10:00\n"), written)
        XCTAssertFalse(written.contains("\nupdated: 2023"), written)
    }
}
