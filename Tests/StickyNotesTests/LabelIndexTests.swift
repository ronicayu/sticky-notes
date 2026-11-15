import XCTest
@testable import StickyNotesKit

/// The label list the `#` completion and the label menu ask for, which is kept
/// between calls and dropped only by what can change it.
final class LabelIndexTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LabelIndex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(rootURL: root)
    }

    override func tearDownWithError() throws {
        store?.stopWatching()
        try? FileManager.default.removeItem(at: root)
    }

    private func make(_ labels: [String]) -> Note {
        Note(
            id: UUID(), title: "", content: "n", width: 240, height: 200, color: .yellow, labels: labels,
            createdAt: Date(), updatedAt: Date())
    }

    func testAskingAgainReadsNothingAndAnUnrelatedSaveKeepsTheAnswer() {
        var note = make(["work"])
        store.save(note)
        store.save(make(["home"]))
        XCTAssertEqual(store.allLabels(), ["home", "work"])
        let reads = store.readCount

        XCTAssertEqual(store.allLabels(), ["home", "work"])
        note.content = "typed more"
        store.save(note)
        XCTAssertEqual(store.allLabels(), ["home", "work"])

        XCTAssertEqual(store.readCount, reads, "the label list was rebuilt from disk")
    }

    func testChangingANotesLabelsChangesTheAnswer() {
        var note = make(["work"])
        store.save(note)
        XCTAssertEqual(store.allLabels(), ["work"])

        note.labels = ["play"]
        store.save(note)

        XCTAssertEqual(store.allLabels(), ["play"])
    }

    func testArchivingTheOnlyNoteWithALabelKeepsItBecauseTheArchiveCounts() {
        let note = make(["solo"])
        store.save(note)
        XCTAssertEqual(store.allLabels(), ["solo"])

        store.archive(note)
        XCTAssertEqual(store.allLabels(), ["solo"])

        store.deleteForever(note)
        XCTAssertEqual(store.allLabels(), [], "a deleted note's label stayed in the list")
    }

    func testTrashingANoteDropsItsLabel() {
        let note = make(["gone"])
        store.save(note)
        XCTAssertEqual(store.allLabels(), ["gone"])

        store.discardActive(note)

        XCTAssertEqual(store.allLabels(), [])
    }

    func testAnOutsideEditThatAddsALabelIsSeen() throws {
        let note = make(["old"])
        store.save(note)
        XCTAssertEqual(store.allLabels(), ["old"])
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: store.activeURL, includingPropertiesForKeys: nil).first)
        let text = try String(contentsOf: file, encoding: .utf8)
        try text.replacingOccurrences(of: "old", with: "new").write(to: file, atomically: true, encoding: .utf8)

        store.handleFileSystemEvent(.init(changed: [file.path]))

        XCTAssertEqual(store.allLabels(), ["new"])
    }

    func testANewNoteWithALabelIsSeen() {
        store.save(make(["a"]))
        XCTAssertEqual(store.allLabels(), ["a"])

        store.save(make(["b"]))

        XCTAssertEqual(store.allLabels(), ["a", "b"])
    }
}
