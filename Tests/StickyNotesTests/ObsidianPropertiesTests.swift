import XCTest
@testable import StickyNotesKit

/// What Obsidian adds to a note's frontmatter must outlive the app's saves: a
/// real `NoteDocument` over a real `NoteStore`, with the file rewritten behind
/// the app's back the way Obsidian does it.
final class ObsidianPropertiesTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var clock: ManualClock!
    private var scheduler: TestScheduler!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObsidianProperties-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clock = ManualClock()
        scheduler = TestScheduler(clock: clock)
        store = NoteStore(rootURL: root, clock: clock)
    }

    override func tearDownWithError() throws {
        store?.stopWatching()
        try? FileManager.default.removeItem(at: root)
    }

    private let properties = """
    tags:
      - project/x
      - "needs: review"
    aliases: [Plan B, 'Plan "C"']
    # kept by a plugin
    meta:
      owner:
        name: Ada
      summary: |
        two
        lines
    """

    private func open(title: String = "Note", content: String = "start", labels: [String] = []) -> NoteDocument {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        note.title = title
        note.content = content
        note.labels = labels
        store.save(note)
        return NoteDocument(note: note, repository: store, scheduler: scheduler, clock: clock)
    }

    private func fileURL() throws -> URL {
        try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: store.activeURL, includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "md" })
    }

    private func fileText() throws -> String {
        try String(contentsOf: fileURL(), encoding: .utf8)
    }

    /// The file as Obsidian leaves it after a property edit: the app's own
    /// keys, `extra` lines among them, and the body.
    private func obsidianWrites(
        _ document: NoteDocument, title: String = "Note", labels: String = " []",
        extra: String, body: String = "start", updated: String = "2030-01-01T00:00:00Z"
    ) throws {
        try """
        ---
        id: \(document.id.uuidString)
        title: \(title)
        \(extra)
        labels:\(labels)
        updated: \(updated)
        ---

        \(body)
        """.write(to: fileURL(), atomically: true, encoding: .utf8)
    }

    private func assertKeepsProperties(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(text.contains("\n" + properties + "\n"), "properties changed:\n\(text)", file: file, line: line)
    }

    // MARK: - Reading and writing

    func testAPropertyAddedInObsidianSurvivesTheNextSaveOfTheApp() throws {
        let document = open()
        try obsidianWrites(document, extra: properties)
        document.storeDidChange()

        document.setBody("start\nmore")
        document.flush()

        let text = try fileText()
        assertKeepsProperties(text)
        XCTAssertTrue(text.contains("start\nmore"))
    }

    func testAPropertyEditedInObsidianWhileTheAppHoldsAnOlderCopyIsNotLost() throws {
        let document = open()
        try obsidianWrites(document, extra: properties)
        // The document is not told, as when the event arrives late.
        document.setBody("start\nmore")
        document.flush()

        let text = try fileText()
        assertKeepsProperties(text)
        XCTAssertTrue(text.contains("start\nmore"))
        XCTAssertFalse(text.contains("Conflicted copy"), text)
    }

    func testAnObsidianPropertyEditWhileTypingIsKeptWhenTheMergeRuns() throws {
        let document = open(content: "start")
        document.setBody("start\ntyped here")
        try obsidianWrites(document, extra: properties, body: "start\nfrom Obsidian", updated: "2030-01-01T00:00:00Z")
        document.storeDidChange()
        document.flush()

        let text = try fileText()
        assertKeepsProperties(text)
        XCTAssertTrue(text.contains("typed here"), text)
        XCTAssertTrue(text.contains("from Obsidian"), text)
    }

    func testAConflictAtSaveTimeKeepsTheFilesPropertiesAndBothTexts() throws {
        let document = open(content: "start")
        document.setBody("start\ntyped here")
        try obsidianWrites(document, extra: properties, body: "start\nfrom Obsidian")
        document.flush()

        let text = try fileText()
        assertKeepsProperties(text)
        XCTAssertTrue(text.contains("typed here"), text)
        XCTAssertTrue(text.contains("from Obsidian"), text)
    }

    func testAPropertyRemovedInObsidianStaysRemoved() throws {
        let document = open()
        try obsidianWrites(document, extra: "tags: [x]")
        document.storeDidChange()
        try obsidianWrites(document, extra: "")
        document.storeDidChange()

        document.setBody("start\nmore")
        document.flush()

        XCTAssertFalse(try fileText().contains("tags"))
    }

    func testPropertiesAreNotPartOfTheNoteTheAppCompares() throws {
        let document = open()
        try obsidianWrites(document, extra: properties)
        document.storeDidChange()

        XCTAssertFalse(document.hasUnsavedEdits)
        XCTAssertNil(document.pendingExternal)
        let loaded = try XCTUnwrap(store.loadNote(id: document.id))
        XCTAssertEqual(
            NoteStore.contentHash(body: loaded.content, title: loaded.title, labels: loaded.labels),
            NoteStore.contentHash(body: "start", title: "Note", labels: [])
        )
    }

    // MARK: - Label list styles

    func testBlockStyleLabelsAreReadAndKeptNotWiped() throws {
        let document = open()
        try obsidianWrites(document, labels: "\n  - work\n  - home", extra: "tags: [x]")
        document.storeDidChange()

        document.setBody("start\nmore")
        document.flush()

        let loaded = try XCTUnwrap(store.loadNote(id: document.id))
        XCTAssertEqual(loaded.labels, ["work", "home"])
        let text = try fileText()
        XCTAssertTrue(text.contains("labels:\n  - work\n  - home\n"), text)
    }

    func testALabelAddedInTheAppIsWrittenInTheStyleTheFileUses() throws {
        let document = open()
        try obsidianWrites(document, labels: "\n  - work", extra: "tags: [x]")
        document.storeDidChange()

        document.edit { $0.labels.append("home") }
        document.flush()

        let text = try fileText()
        XCTAssertTrue(text.contains("labels:\n  - ") && !text.contains("labels: ["), text)
        XCTAssertEqual(Set(try XCTUnwrap(store.loadNote(id: document.id)).labels), ["work", "home"])
    }

    func testFlowStyleLabelsStayInFlowStyle() throws {
        let document = open(labels: ["work"])
        document.setBody("start\nmore")
        document.flush()

        let text = try fileText()
        XCTAssertTrue(text.contains("labels: [work]\n"), text)
    }

    func testLabelsRewrittenInBlockStyleBeforeTheAppHeardAboutItAreStillUnioned() throws {
        let document = open(labels: ["mine"])
        try obsidianWrites(document, labels: "\n  - work\n  - mine", extra: "tags: [x]")
        document.setBody("start\nmore")
        document.flush()

        let loaded = try XCTUnwrap(store.loadNote(id: document.id))
        XCTAssertEqual(Set(loaded.labels), ["mine", "work"])
        XCTAssertTrue(try fileText().contains("tags: [x]"))
    }

    // MARK: - The creation echo

    /// A title typed in the first moments of a note that already has its (empty)
    /// file: the watcher's report of that creation must not wipe it.
    func testATitleTypedInTheFirstMomentSurvivesTheCreationEcho() throws {
        let document = open(title: "", content: "")

        document.setTitle("Plan")
        document.storeDidChange()
        document.flush()

        XCTAssertEqual(document.buffer.title, "Plan")
        XCTAssertEqual(try XCTUnwrap(store.loadNote(id: document.id)).title, "Plan")
    }

    func testATitleTypedBeforeTheFileExistsSurvivesTheCreationEcho() throws {
        let note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        let document = NoteDocument(note: note, repository: store, scheduler: scheduler, clock: clock)
        document.createsFileOnFirstEdit = true

        document.setTitle("Plan")
        document.storeDidChange()
        document.flush()

        XCTAssertEqual(try XCTUnwrap(store.loadNote(id: document.id)).title, "Plan")
    }
}
