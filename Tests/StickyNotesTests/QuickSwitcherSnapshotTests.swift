import AppKit
import XCTest
@testable import StickyNotesKit

/// Builds the quick switcher's view tree and renders it offscreen. The
/// assertions cover what the ranker tests can't — that the controller wires a
/// query to the right rows, and that laying the palette out doesn't crash.
///
/// Set `SNAPSHOT_DIR` to also write PNGs for a human to look at. Pixel content
/// is deliberately not asserted: whether text rasterizes offscreen depends on
/// the window server, which differs between a developer's machine and a CI
/// runner, and a flaky pixel heuristic is worse than no assertion.
final class QuickSwitcherSnapshotTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickSwitcherSnapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func seededStore() -> NoteStore {
        let store = NoteStore(rootURL: root, format: .markdown)
        let samples: [(String, String, [String], NoteColor)] = [
            ("Groceries", "- [ ] oat milk\n- [x] eggs\n- [ ] sourdough", ["home"], .yellow),
            ("Q3 planning", "Ship the search release.\nThen the editor work.", ["work"], .blue),
            ("", "Remember to call the dentist back about the appointment", [], .pink),
            ("Reading list", "*Design of Everyday Things*\n`swift-markdown` docs", ["someday"], .green),
            ("Standup", "Blocked on the vault migration", ["work"], .orange)
        ]
        for (index, sample) in samples.enumerated() {
            store.save(Note(
                id: UUID(), title: sample.0, content: sample.1,
                positionX: 0, positionY: 0, width: 240, height: 200,
                collapsed: false, color: sample.3, labels: sample.2,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date().addingTimeInterval(Double(-index) * 3600)
            ))
        }
        return store
    }

    /// Lay out and rasterize the palette, failing if either step can't run.
    private func render(_ controller: QuickSwitcherController, to name: String) throws {
        let view = try XCTUnwrap(controller.window?.contentView, "controller has no content view")
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.bounds.width, 0, "palette laid out to zero width")
        XCTAssertGreaterThan(view.bounds.height, 0, "palette laid out to zero height")

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds),
                                "could not create a bitmap for the palette")
        view.cacheDisplay(in: view.bounds, to: rep)

        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"],
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }

    func testEmptyQueryListsEveryNote() throws {
        let controller = QuickSwitcherController(store: seededStore(), onChoose: { _ in })
        controller.prepare()

        XCTAssertEqual(controller.resultCount, 5)
        try render(controller, to: "quick-switcher-empty-query.png")
    }

    func testQueryNarrowsToMatchingNotes() throws {
        let controller = QuickSwitcherController(store: seededStore(), onChoose: { _ in })
        controller.prepare()

        controller.search("work")
        XCTAssertEqual(controller.resultCount, 2, "both #work notes should match")
        try render(controller, to: "quick-switcher-query-work.png")
    }

    func testNoMatchesLeavesTheListEmpty() throws {
        let controller = QuickSwitcherController(store: seededStore(), onChoose: { _ in })
        controller.prepare()

        controller.search("zzzzz-no-such-note")
        XCTAssertEqual(controller.resultCount, 0)
        try render(controller, to: "quick-switcher-no-matches.png")
    }

    func testChoosingAResultReportsTheNoteAndItsArchivedState() throws {
        let store = seededStore()
        let archived = try XCTUnwrap(store.loadActive().first(where: { $0.title == "Standup" }))
        store.archive(archived)

        var chosen: QuickSwitcherController.Selection?
        let controller = QuickSwitcherController(store: store, onChoose: { chosen = $0 })
        controller.prepare()

        controller.search("standup")
        controller.activateSelection()

        XCTAssertEqual(chosen?.id, archived.id)
        XCTAssertEqual(chosen?.wasArchived, true,
                       "the caller has to restore an archived note before focusing it")
    }

    func testArchivedNotesAreSearchable() throws {
        let store = seededStore()
        for note in store.loadActive() { store.archive(note) }

        let controller = QuickSwitcherController(store: store, onChoose: { _ in })
        controller.prepare()

        controller.search("groceries")
        XCTAssertEqual(controller.resultCount, 1,
                       "the switcher should reach archived notes, not just active ones")
    }

    func testPreparingAgainPicksUpNotesAddedSince() throws {
        let store = seededStore()
        let controller = QuickSwitcherController(store: store, onChoose: { _ in })
        controller.prepare()
        XCTAssertEqual(controller.resultCount, 5)

        store.save(Note(
            id: UUID(), title: "Brand new", content: "", positionX: 0, positionY: 0,
            width: 240, height: 200, collapsed: false, color: .yellow, labels: [],
            createdAt: Date(), updatedAt: Date()
        ))
        controller.prepare()
        XCTAssertEqual(controller.resultCount, 6, "each invocation should reload the candidates")
    }
}
