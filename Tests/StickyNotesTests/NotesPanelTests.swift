import AppKit
import XCTest
@testable import StickyNotesKit

final class NotesPanelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesPanelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func seed(
        _ store: NoteStore,
        title: String = "",
        content: String = "",
        labels: [String] = [],
        color: NoteColor = .yellow,
        updated: TimeInterval = 0
    ) -> Note {
        let note = Note(
            id: UUID(), title: title, content: content,
            positionX: 0, positionY: 0, width: 240, height: 200,
            collapsed: false, color: color, labels: labels,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + updated),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + updated)
        )
        store.save(note)
        return note
    }

    private func makePanel(_ store: NoteStore) -> NotesPanelController {
        NotesPanelController(store: store, onActivate: { _ in })
    }

    func testPanelListsEveryActiveNoteByDefault() {
        let store = NoteStore(rootURL: root, format: .json)
        seed(store, title: "One")
        seed(store, title: "Two")
        seed(store, title: "Three")

        let panel = makePanel(store)
        XCTAssertEqual(panel.rowCount, 3)
    }

    func testSearchNarrowsTheList() {
        let store = NoteStore(rootURL: root, format: .json)
        seed(store, title: "Groceries")
        seed(store, title: "Standup")
        seed(store, content: "buy groceries on the way home")

        let panel = makePanel(store)
        panel.search("groceries")
        XCTAssertEqual(panel.rowCount, 2, "should match the title and the body mention")

        panel.search("standup")
        XCTAssertEqual(panel.rowCount, 1)
    }

    func testSearchMatchesLabels() {
        let store = NoteStore(rootURL: root, format: .json)
        seed(store, title: "Tagged", labels: ["urgent"])
        seed(store, title: "Untagged")

        let panel = makePanel(store)
        panel.search("urgent")
        XCTAssertEqual(panel.rowCount, 1)
    }

    func testClearingSearchRestoresTheFullList() {
        let store = NoteStore(rootURL: root, format: .json)
        seed(store, title: "One")
        seed(store, title: "Two")

        let panel = makePanel(store)
        panel.search("one")
        XCTAssertEqual(panel.rowCount, 1)
        panel.search("")
        XCTAssertEqual(panel.rowCount, 2)
    }

    func testLabelFilterNarrowsToTaggedNotes() {
        let store = NoteStore(rootURL: root, format: .json)
        seed(store, title: "Work note", labels: ["work"])
        seed(store, title: "Home note", labels: ["home"])
        seed(store, title: "Untagged")

        let panel = makePanel(store)
        panel.filterByLabel("work")
        XCTAssertEqual(panel.rowCount, 1)

        panel.filterByLabel(nil)
        XCTAssertEqual(panel.rowCount, 3)
    }

    func testLabelFilterAndSearchCombine() {
        let store = NoteStore(rootURL: root, format: .json)
        seed(store, title: "Work plan", labels: ["work"])
        seed(store, title: "Work log", labels: ["work"])
        seed(store, title: "Home plan", labels: ["home"])

        let panel = makePanel(store)
        panel.filterByLabel("work")
        panel.search("plan")
        XCTAssertEqual(panel.rowCount, 1, "should be the work-tagged note matching 'plan'")
    }

    func testAFilterOnADeletedLabelFallsBackToAllNotes() {
        let store = NoteStore(rootURL: root, format: .json)
        let tagged = seed(store, title: "Work", labels: ["work"])
        seed(store, title: "Other")

        let panel = makePanel(store)
        panel.filterByLabel("work")
        XCTAssertEqual(panel.rowCount, 1)

        // The only note carrying #work goes away; the stale filter must not
        // leave the panel permanently empty.
        store.discardActive(tagged)
        panel.reload()
        XCTAssertEqual(panel.rowCount, 1, "the remaining note should be listed again")
    }

    func testSortByTitleIsAlphabetical() {
        let store = NoteStore(rootURL: root, format: .json)
        seed(store, title: "Charlie", updated: 300)
        seed(store, title: "alpha", updated: 200)
        seed(store, title: "Bravo", updated: 100)

        let panel = makePanel(store)
        panel.sort(by: .title)
        XCTAssertEqual(panel.visibleTitles, ["alpha", "Bravo", "Charlie"],
                       "sorting by title should ignore case")
    }

    func testSortByLastEditedIsNewestFirst() {
        let store = NoteStore(rootURL: root, format: .json)
        seed(store, title: "Oldest", updated: 0)
        seed(store, title: "Newest", updated: 300)
        seed(store, title: "Middle", updated: 100)

        let panel = makePanel(store)
        panel.sort(by: .updated)
        XCTAssertEqual(panel.visibleTitles, ["Newest", "Middle", "Oldest"])
    }

    func testSearchResultsKeepRelevanceOrderRegardlessOfSort() {
        let store = NoteStore(rootURL: root, format: .json)
        seed(store, title: "zzz plan", updated: 0)           // title hit
        seed(store, content: "a plan mentioned here", updated: 900)  // body hit, newer

        let panel = makePanel(store)
        panel.sort(by: .title)
        panel.search("plan")
        XCTAssertEqual(panel.visibleTitles.first, "zzz plan",
                       "a title hit should stay first — sorting must not override relevance")
    }

    func testArchivedTabListsArchivedNotesOnly() {
        let store = NoteStore(rootURL: root, format: .json)
        let archived = seed(store, title: "Gone")
        seed(store, title: "Here")
        store.archive(archived)

        let panel = makePanel(store)
        XCTAssertEqual(panel.visibleTitles, ["Here"])

        panel.showMode(.archived)
        XCTAssertEqual(panel.visibleTitles, ["Gone"])
    }

    func testPanelRefreshesWhenTheStoreChanges() {
        let store = NoteStore(rootURL: root, format: .json)
        seed(store, title: "First")

        let panel = makePanel(store)
        XCTAssertEqual(panel.rowCount, 1)

        seed(store, title: "Second")
        panel.reload()
        XCTAssertEqual(panel.rowCount, 2)
    }

    func testEmptyStoreShowsNoRows() {
        let panel = makePanel(NoteStore(rootURL: root, format: .json))
        XCTAssertEqual(panel.rowCount, 0)
    }
}

final class LabelVisibilityTests: XCTestCase {
    /// Settings.shared is a singleton over UserDefaults.standard, so put the
    /// developer's real preference back when we're done with it.
    private var savedHiddenLabels: Set<String> = []

    override func setUpWithError() throws {
        savedHiddenLabels = Settings.shared.hiddenLabels
    }

    override func tearDownWithError() throws {
        Settings.shared.hiddenLabels = savedHiddenLabels
    }

    private func note(labels: [String]) -> Note {
        Note(
            id: UUID(), title: "", content: "",
            positionX: 0, positionY: 0, width: 1, height: 1,
            collapsed: false, color: .yellow, labels: labels,
            createdAt: Date(), updatedAt: Date()
        )
    }

    func testNoHiddenLabelsMeansEverythingIsVisible() {
        Settings.shared.hiddenLabels = []
        XCTAssertFalse(Settings.shared.isHiddenByLabel(note(labels: ["work"])))
        XCTAssertFalse(Settings.shared.isHiddenByLabel(note(labels: [])))
    }

    func testHidingALabelHidesNotesCarryingIt() {
        Settings.shared.hiddenLabels = ["work"]
        XCTAssertTrue(Settings.shared.isHiddenByLabel(note(labels: ["work"])))
        XCTAssertFalse(Settings.shared.isHiddenByLabel(note(labels: ["home"])))
    }

    func testUnlabeledNotesAreNeverHiddenByALabelFilter() {
        Settings.shared.hiddenLabels = ["work"]
        XCTAssertFalse(Settings.shared.isHiddenByLabel(note(labels: [])),
                       "hiding #work should not sweep away untagged notes")
    }

    /// A note tagged both #work and #home disappears when either is hidden —
    /// the intent to put something away is the narrower one.
    func testANoteWithAnyHiddenLabelIsHidden() {
        Settings.shared.hiddenLabels = ["work"]
        XCTAssertTrue(Settings.shared.isHiddenByLabel(note(labels: ["work", "home"])))
    }

    func testHiddenLabelsPersistAndRoundTrip() {
        Settings.shared.hiddenLabels = ["work", "someday"]
        XCTAssertEqual(Settings.shared.hiddenLabels, ["work", "someday"])

        Settings.shared.hiddenLabels = []
        XCTAssertTrue(Settings.shared.hiddenLabels.isEmpty)
    }
}
