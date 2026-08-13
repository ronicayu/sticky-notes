import AppKit
import XCTest
@testable import StickyNotesKit

/// Renders the notes panel offscreen so layout regressions in the new filter
/// row, empty state, and result rows show up as more than a passing assertion.
final class NotesPanelSnapshotTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesPanelSnapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func seededStore() -> NoteStore {
        let store = NoteStore(rootURL: root, format: .markdown)
        let samples: [(String, String, [String], NoteColor, TimeInterval)] = [
            ("Groceries", "- [ ] oat milk\n- [x] eggs", ["home"], .yellow, -120),
            ("Q3 planning", "Ship the search release first.", ["work"], .blue, -3600),
            ("", "Call the dentist back about the appointment", [], .pink, -7200),
            ("Reading list", "Design of Everyday Things", ["someday"], .green, -86400),
            ("Standup", "Blocked on the vault migration", ["work", "urgent"], .orange, -172800)
        ]
        for sample in samples {
            store.save(Note(
                id: UUID(), title: sample.0, content: sample.1,
                positionX: 0, positionY: 0, width: 240, height: 200,
                collapsed: false, color: sample.3, labels: sample.2,
                createdAt: Date().addingTimeInterval(sample.4),
                updatedAt: Date().addingTimeInterval(sample.4)
            ))
        }
        return store
    }

    private func render(_ panel: NotesPanelController, to name: String) throws {
        let window = try XCTUnwrap(panel.window)
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"],
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        XCTAssertGreaterThan(rep.pixelsWide, 0)
    }

    func testPanelRendersTheDefaultList() throws {
        let panel = NotesPanelController(store: seededStore(), onActivate: { _ in })
        try render(panel, to: "notes-panel-default.png")
    }

    func testPanelRendersSearchResults() throws {
        let panel = NotesPanelController(store: seededStore(), onActivate: { _ in })
        panel.search("vault")
        try render(panel, to: "notes-panel-search.png")
    }

    func testPanelRendersTheEmptyState() throws {
        let panel = NotesPanelController(store: seededStore(), onActivate: { _ in })
        panel.search("no-such-note-anywhere")
        try render(panel, to: "notes-panel-empty.png")
    }
}
