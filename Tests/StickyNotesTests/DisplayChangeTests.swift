import AppKit
import XCTest
@testable import StickyNotesKit

/// A note on a screen that is unplugged is shown on a screen that is left, and
/// goes back to where the person put it when the screen comes back. What the
/// layout remembers is only ever what the person chose. The screens are the
/// test's own: `visibleScreenFrames` stands in for `NSScreen.screens`.
@MainActor final class DisplayChangeTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var clock: ManualClock!
    private var scheduler: TestScheduler!
    private var layout: DeviceLayoutStore!
    private var controllers: [NoteWindowController] = []

    /// The host's own screen, and a taller one to its right.
    private var laptop: NSRect!
    private var external: NSRect!

    override func setUp() async throws {
        _ = NSApplication.shared
        laptop = try XCTUnwrap(NSScreen.main?.visibleFrame, "no screen")
        external = NSRect(x: laptop.maxX + 500, y: laptop.minY, width: 1600, height: laptop.height + 300)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Display-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(rootURL: root)
        clock = ManualClock()
        scheduler = TestScheduler(clock: clock)
        layout = DeviceLayoutStore(scheduler: scheduler)
    }

    override func tearDown() async throws {
        controllers.forEach { $0.window?.close() }
        controllers = []
        store?.stopWatching()
        try? FileManager.default.removeItem(at: root)
    }

    private func makeNote() -> Note {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200), now: clock.now())
        note.content = "text"
        store.save(note)
        return note
    }

    /// A window for a note whose layout is `frame`, with the laptop and the
    /// external screen both there. The window opens on the real screens, so it
    /// is then shown where the layout puts it, as when the screens are reported.
    private func open(_ note: Note, at frame: NSRect, collapsed: Bool = false) -> NoteWindowController {
        layout.set(NoteLayout(frame: frame, collapsed: collapsed), for: note.id)
        let controller = NoteWindowController(
            note: note, store: store, layout: layout, clock: clock, scheduler: scheduler, onClosed: { _ in }
        )
        controllers.append(controller)
        screensChange(controller, to: [laptop, external])
        return controller
    }

    private func screensChange(_ controller: NoteWindowController, to screens: [NSRect]) {
        controller.visibleScreenFrames = { screens }
        controller.screensDidChange()
    }

    /// The person drags the note: the pointer is down while the window moves.
    private func drag(_ controller: NoteWindowController, to origin: NSPoint) throws {
        let window = try XCTUnwrap(controller.window)
        controller.isPersonDraggingOrResizing = { true }
        defer { controller.isPersonDraggingOrResizing = { false } }
        window.setFrameOrigin(origin)
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
    }

    // MARK: - Unplugging

    func testUnpluggingTheScreenShowsTheNoteOnTheOneLeftAndKeepsItsLayout() throws {
        let note = makeNote()
        let chosen = NSRect(x: external.minX + 400, y: laptop.minY + 100, width: 240, height: 200)
        let controller = open(note, at: chosen)
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.frame.origin, chosen.origin)

        screensChange(controller, to: [laptop])

        XCTAssertTrue(laptop.contains(window.frame), "the note is out of reach on a screen that is gone")
        XCTAssertEqual(layout.layout(for: note.id)?.frame, chosen, "the layout was overwritten with the stand-in position")
    }

    func testPluggingTheScreenBackPutsTheNoteWhereThePersonLeftIt() throws {
        let note = makeNote()
        let chosen = NSRect(x: external.minX + 400, y: laptop.minY + 100, width: 240, height: 200)
        let controller = open(note, at: chosen)
        screensChange(controller, to: [laptop])

        screensChange(controller, to: [laptop, external])

        XCTAssertEqual(controller.window?.frame, chosen)
        XCTAssertEqual(layout.layout(for: note.id)?.frame, chosen)
    }

    func testANoteTheScreenChangeDoesNotTouchStaysWhereItIs() throws {
        let note = makeNote()
        let chosen = NSRect(x: laptop.minX + 100, y: laptop.minY + 200, width: 240, height: 200)
        let controller = open(note, at: chosen)

        screensChange(controller, to: [laptop])
        screensChange(controller, to: [laptop, external])

        XCTAssertEqual(controller.window?.frame, chosen)
    }

    func testAnOversizedNoteIsShrunkOnASmallerScreenAndGetsItsSizeBack() throws {
        let note = makeNote()
        let chosen = NSRect(x: external.minX + 100, y: laptop.minY + 20, width: 400, height: 600)
        let small = NSRect(x: laptop.minX, y: laptop.minY, width: 800, height: 400)
        let controller = open(note, at: chosen)
        screensChange(controller, to: [small])
        let shown = try XCTUnwrap(controller.window?.frame)
        XCTAssertEqual(shown.height, small.height)

        // The window reports its own resize; that is not the person's.
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: controller.window))

        XCTAssertEqual(layout.layout(for: note.id)?.frame, chosen)
        screensChange(controller, to: [small, external])
        XCTAssertEqual(controller.window?.frame, chosen)
    }

    func testFramesTheSystemGivesTheWindowWhenAScreenGoesDoNotReplaceTheLayout() throws {
        let note = makeNote()
        let chosen = NSRect(x: external.minX + 400, y: laptop.minY + 100, width: 240, height: 200)
        let controller = open(note, at: chosen)
        let window = try XCTUnwrap(controller.window)
        controller.isPersonDraggingOrResizing = { false }

        // The screen is gone before the note's own handler has run.
        controller.visibleScreenFrames = { [laptop] in [laptop!] }
        window.setFrame(NSRect(x: laptop.minX + 50, y: laptop.minY + 60, width: 180, height: 150), display: false)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            let notification = Notification(name: name, object: window)
            controller.windowDidMove(notification)
            controller.windowDidResize(notification)
            controller.windowDidChangeScreen(notification)
        }
        XCTAssertEqual(layout.layout(for: note.id)?.frame, chosen, "the system's frame replaced the person's")

        screensChange(controller, to: [laptop, external])

        XCTAssertEqual(controller.window?.frame, chosen)
        XCTAssertEqual(layout.layout(for: note.id)?.frame, chosen)
    }

    // MARK: - After the person moves it

    func testMovingTheNoteWhileItIsStoodInMakesThatItsPlaceForGood() throws {
        let note = makeNote()
        let controller = open(note, at: NSRect(x: external.minX + 400, y: laptop.minY + 100, width: 240, height: 200))
        screensChange(controller, to: [laptop])

        try drag(controller, to: NSPoint(x: laptop.minX + 300, y: laptop.minY + 250))
        screensChange(controller, to: [laptop, external])

        XCTAssertEqual(controller.window?.frame.origin, NSPoint(x: laptop.minX + 300, y: laptop.minY + 250))
        XCTAssertEqual(layout.layout(for: note.id)?.x, Double(laptop.minX + 300))
        XCTAssertEqual(layout.layout(for: note.id)?.y, Double(laptop.minY + 250))
    }

    func testCollapsingAStoodInNoteKeepsItsLayoutTopEdge() throws {
        let note = makeNote()
        let chosen = NSRect(x: external.minX + 400, y: laptop.minY + 100, width: 240, height: 200)
        let controller = open(note, at: chosen)
        screensChange(controller, to: [laptop])

        controller.dragZoneDidDoubleClick()
        scheduler.advance(by: 1)

        let bar = NoteWindowController.collapsedHeight
        let saved = try XCTUnwrap(layout.layout(for: note.id))
        XCTAssertTrue(saved.collapsed)
        XCTAssertEqual(saved.x, chosen.minX)
        XCTAssertEqual(saved.y, chosen.maxY - bar, "the bar did not keep the note's top edge")
        XCTAssertEqual(saved.height, chosen.height)

        screensChange(controller, to: [laptop, external])
        XCTAssertEqual(controller.window?.frame, NSRect(x: chosen.minX, y: chosen.maxY - bar, width: chosen.width, height: bar))

        controller.dragZoneDidDoubleClick()
        XCTAssertEqual(controller.window?.frame, chosen, "expanding moved the note")
    }

    func testExpandingAStoodInBarKeepsItsLayoutTopEdge() throws {
        let note = makeNote()
        let bar = NoteWindowController.collapsedHeight
        let chosen = NSRect(x: external.minX + 400, y: laptop.minY + 500, width: 240, height: 200)
        let controller = open(note, at: chosen, collapsed: true)
        screensChange(controller, to: [laptop])

        controller.toggleCollapse()

        let saved = try XCTUnwrap(layout.layout(for: note.id))
        XCTAssertFalse(saved.collapsed)
        XCTAssertEqual(saved.y, chosen.minY + bar - chosen.height, "the note lost its top edge")

        screensChange(controller, to: [laptop, external])
        XCTAssertEqual(controller.window?.frame, NSRect(x: chosen.minX, y: chosen.minY + bar - 200, width: 240, height: 200))
    }

    func testClosingAStoodInNoteLeavesItsLayoutAlone() throws {
        let note = makeNote()
        let chosen = NSRect(x: external.minX + 400, y: laptop.minY + 100, width: 240, height: 200)
        let controller = open(note, at: chosen)
        screensChange(controller, to: [laptop])

        controller.closeNote()

        XCTAssertEqual(layout.layout(for: note.id)?.frame, chosen)
    }

    // MARK: - Collapsing and expanding without the mouse

    func testExpandingABarAtTheScreenTopWithTheKeyboardKeepsTheNoteWhereItIs() throws {
        let note = makeNote()
        let top = laptop.maxY
        let controller = open(note, at: NSRect(x: laptop.minX + 100, y: top - NoteWindowController.collapsedHeight, width: 240, height: 200), collapsed: true)
        controller.isPersonDraggingOrResizing = { false }

        controller.toggleCollapse()

        let expanded = NSRect(x: laptop.minX + 100, y: top - 200, width: 240, height: 200)
        XCTAssertEqual(controller.window?.frame, expanded)
        XCTAssertEqual(layout.layout(for: note.id)?.frame, expanded, "the layout kept the bar's origin for the whole note")
        XCTAssertEqual(layout.layout(for: note.id)?.collapsed, false)
        screensChange(controller, to: [laptop, external])
        XCTAssertEqual(controller.window?.frame, expanded, "the note jumped on the next screen change")
    }

    func testCollapsingAndExpandingAnExpandedNoteWithTheKeyboardReturnsItsLayout() throws {
        let note = makeNote()
        let chosen = NSRect(x: laptop.minX + 100, y: laptop.minY + 200, width: 240, height: 200)
        let controller = open(note, at: chosen)
        controller.isPersonDraggingOrResizing = { false }

        controller.toggleCollapse()
        XCTAssertEqual(layout.layout(for: note.id)?.y, Double(chosen.maxY - NoteWindowController.collapsedHeight))
        controller.toggleCollapse()

        XCTAssertEqual(layout.layout(for: note.id)?.frame, chosen)
        XCTAssertEqual(controller.window?.frame, chosen)
    }

    // MARK: - Notes the person placed across the edge of a screen

    func testANoteAcrossTwoScreensStaysThereWhenTheScreensAreReported() throws {
        let note = makeNote()
        let neighbour = NSRect(x: laptop.maxX, y: laptop.minY, width: 1600, height: laptop.height)
        let chosen = NSRect(x: laptop.maxX - 120, y: laptop.minY + 100, width: 240, height: 200)
        let controller = open(note, at: chosen)

        screensChange(controller, to: [laptop, neighbour])

        XCTAssertEqual(controller.window?.frame, chosen, "a note the person put across two screens was pulled onto one")
        XCTAssertEqual(layout.layout(for: note.id)?.frame, chosen)
    }

    func testANoteHalfOffTheLeftEdgeStaysThereWhenTheScreensAreReported() throws {
        let note = makeNote()
        let chosen = NSRect(x: laptop.minX - 100, y: laptop.minY + 100, width: 240, height: 200)
        let controller = open(note, at: chosen)

        screensChange(controller, to: [laptop])

        XCTAssertEqual(controller.window?.frame, chosen)
    }

    func testCollapsingANoteAcrossTwoScreensIsRecorded() throws {
        let note = makeNote()
        let neighbour = NSRect(x: laptop.maxX, y: laptop.minY, width: 1600, height: laptop.height)
        let chosen = NSRect(x: laptop.maxX - 120, y: laptop.minY + 100, width: 240, height: 200)
        let controller = open(note, at: chosen)
        screensChange(controller, to: [laptop, neighbour])
        controller.isPersonDraggingOrResizing = { false }

        controller.toggleCollapse()

        let bar = NoteWindowController.collapsedHeight
        let expected = NSRect(x: chosen.minX, y: chosen.maxY - bar, width: chosen.width, height: bar)
        XCTAssertEqual(controller.window?.frame, expected)
        XCTAssertEqual(layout.layout(for: note.id)?.y, Double(expected.minY), "the collapse was not recorded")
        XCTAssertEqual(layout.layout(for: note.id)?.collapsed, true)
        screensChange(controller, to: [laptop, neighbour])
        XCTAssertEqual(controller.window?.frame, expected)
    }

    func testANoteWithOnlyASliverOnAScreenIsBroughtBackOntoIt() throws {
        let note = makeNote()
        let chosen = NSRect(x: laptop.maxX - 30, y: laptop.minY + 100, width: 240, height: 200)
        let controller = open(note, at: chosen)

        screensChange(controller, to: [laptop])

        let frame = try XCTUnwrap(controller.window?.frame)
        XCTAssertTrue(laptop.contains(frame), "a note nobody can grab was left half off the screen")
        XCTAssertEqual(layout.layout(for: note.id)?.frame, chosen)
    }

    // MARK: - Launching without the screen

    func testLaunchingWithoutTheScreenKeepsTheLayoutAndShowsTheNoteOnARealScreen() throws {
        let note = makeNote()
        let chosen = NSRect(x: 30_000, y: 300, width: 240, height: 200)
        layout.set(NoteLayout(frame: chosen), for: note.id)

        let controller = NoteWindowController(
            note: note, store: store, layout: layout, clock: clock, scheduler: scheduler, onClosed: { _ in }
        )
        controllers.append(controller)

        let frame = try XCTUnwrap(controller.window?.frame)
        XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }, "the note is out of reach")
        XCTAssertEqual(layout.layout(for: note.id)?.frame, chosen, "the launch overwrote the layout with the stand-in position")

        controller.visibleScreenFrames = { [NSScreen.main!.visibleFrame, NSRect(x: 29_000, y: 0, width: 2000, height: 1000)] }
        controller.screensDidChange()
        XCTAssertEqual(controller.window?.frame, chosen)
    }

    func testANoteWithNoLayoutYetIsPlacedOnAScreenAndThatIsItsLayout() throws {
        let note = makeNote()
        let controller = NoteWindowController(
            note: note, store: store, layout: layout,
            placing: { _ in NSRect(x: 30_000, y: 300, width: 240, height: 200) },
            clock: clock, scheduler: scheduler, onClosed: { _ in }
        )
        controllers.append(controller)

        let frame = try XCTUnwrap(controller.window?.frame)
        XCTAssertEqual(layout.layout(for: note.id)?.frame, frame)
    }
}
