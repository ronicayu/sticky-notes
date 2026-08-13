import AppKit
import XCTest
@testable import StickyNotesKit

/// Renders the quick switcher offscreen. Catches layout mistakes that unit
/// tests on the ranker can't — an empty table, a clipped label, a row that
/// never got its constraints.
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

    private func render(_ controller: QuickSwitcherController, to name: String) throws -> NSBitmapImageRep {
        let view = try XCTUnwrap(controller.window?.contentView, "controller has no content view")
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds),
                                "could not create a bitmap for the palette")
        view.cacheDisplay(in: view.bounds, to: rep)

        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"],
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        return rep
    }

    /// A rendering that is one flat color means nothing drew.
    private func assertNotBlank(_ rep: NSBitmapImageRep, _ message: String) {
        var seen = Set<UInt32>()
        let step = 4
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let packed = (UInt32(color.redComponent * 255) << 16)
                    | (UInt32(color.greenComponent * 255) << 8)
                    | UInt32(color.blueComponent * 255)
                seen.insert(packed)
                if seen.count > 8 { return }
            }
        }
        XCTFail("\(message) — only \(seen.count) distinct colors, the view looks blank")
    }

    func testPaletteRendersResultsForAnEmptyQuery() throws {
        let store = seededStore()
        let controller = QuickSwitcherController(store: store, onChoose: { _ in })
        controller.show()
        defer { controller.dismiss() }

        let rep = try render(controller, to: "quick-switcher-empty-query.png")
        assertNotBlank(rep, "palette with no query")
    }

    func testPaletteRendersFilteredResults() throws {
        let store = seededStore()
        let controller = QuickSwitcherController(store: store, onChoose: { _ in })
        controller.show()
        defer { controller.dismiss() }

        controller.search("work")
        let rep = try render(controller, to: "quick-switcher-query-work.png")
        assertNotBlank(rep, "palette filtered to 'work'")
    }

    func testPaletteRendersTheNoMatchesState() throws {
        let store = seededStore()
        let controller = QuickSwitcherController(store: store, onChoose: { _ in })
        controller.show()
        defer { controller.dismiss() }

        controller.search("zzzzz-no-such-note")
        let rep = try render(controller, to: "quick-switcher-no-matches.png")
        assertNotBlank(rep, "palette with no matches")
    }

    func testChoosingAResultReportsTheNoteAndItsArchivedState() throws {
        let store = seededStore()
        let archived = try XCTUnwrap(store.loadActive().first(where: { $0.title == "Standup" }))
        store.archive(archived)

        var chosen: QuickSwitcherController.Selection?
        let controller = QuickSwitcherController(store: store, onChoose: { chosen = $0 })
        controller.show()
        defer { controller.dismiss() }

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
        controller.show()
        defer { controller.dismiss() }

        controller.search("groceries")
        XCTAssertEqual(controller.resultCount, 1,
                       "the switcher should reach archived notes, not just active ones")
    }
}
