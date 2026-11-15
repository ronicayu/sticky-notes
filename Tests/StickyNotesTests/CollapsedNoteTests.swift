import AppKit
import XCTest
@testable import StickyNotesKit

/// A collapsed note's bar, how a note is brought back from search, and the
/// footer date.
@MainActor final class CollapsedNoteTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var isolated: IsolatedSettings!
    private var clock: ManualClock!
    private var scheduler: TestScheduler!
    private var desk: DeskController!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Collapsed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clock = ManualClock()
        scheduler = TestScheduler(clock: clock)
        store = NoteStore(rootURL: root, clock: clock)
        isolated = IsolatedSettings()
        desk = DeskController(
            store: store, settings: isolated.settings, clock: clock, undo: UndoCenter(clock: clock),
            recovery: RecoveryFiles(settings: isolated.settings, store: store, clock: clock),
            scheduler: scheduler,
            layout: DeviceLayoutStore(url: root.appendingPathComponent("layout.json"), scheduler: TestScheduler())
        )
        desk.motionDuration = { _ in 0 }
    }

    override func tearDown() async throws {
        scheduler.advance(by: 1)
        store?.stopWatching()
        desk.windowControllers.values.forEach { $0.window?.close() }
        isolated.tearDown()
        try? FileManager.default.removeItem(at: root)
    }

    private func seed(_ title: String) -> Note {
        var note = Note.makeNew(frame: NSRect(x: 40, y: 40, width: 240, height: 200), now: clock.now())
        note.title = title
        note.content = "body"
        store.save(note)
        return note
    }

    private func open(_ note: Note) throws -> NoteWindowController {
        desk.presentWindow(for: note)
        return try XCTUnwrap(desk.windowControllers[note.id])
    }

    private func all<T: NSView>(_ type: T.Type, in controller: NoteWindowController) -> [T] {
        var found: [T] = []
        func walk(_ view: NSView) {
            if let match = view as? T { found.append(match) }
            view.subviews.forEach(walk)
        }
        controller.window?.contentView.map(walk)
        return found
    }

    func testTheCollapsedBarHasNoClickableButtons() throws {
        let controller = try open(seed("Groceries"))
        let strip = try XCTUnwrap(all(NoteDragZone.self, in: controller).first)
        let buttons = all(NSButton.self, in: controller).filter { $0.isDescendant(of: strip) }
        XCTAssertFalse(buttons.isEmpty)

        controller.toggleCollapse()
        XCTAssertTrue(buttons.allSatisfy(\.isHidden), "an invisible button on the bar would swallow the click that starts a drag")

        controller.toggleCollapse()
        XCTAssertTrue(buttons.allSatisfy { !$0.isHidden })
    }

    func testFocusingACollapsedNoteExpandsIt() throws {
        let note = seed("Groceries")
        let controller = try open(note)
        controller.toggleCollapse()

        desk.focusNote(id: note.id)

        XCTAssertFalse(controller.isCollapsed)
    }

    func testTheFooterShowsWhenTheNoteWasLastSavedNotToday() throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let saved = formatter.string(from: clock.now())
        let note = seed("Old")
        clock.advance(by: 90 * 24 * 3600)
        let today = formatter.string(from: clock.now())

        let controller = try open(note)

        let texts = all(NSTextField.self, in: controller).map(\.stringValue)
        XCTAssertTrue(texts.contains { $0.hasSuffix(saved) }, "\(texts)")
        XCTAssertFalse(texts.contains { $0.hasSuffix(today) }, "\(texts)")
    }
}
