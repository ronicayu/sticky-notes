import AppKit
import XCTest
@testable import StickyNotesKit

/// The two things that move: a new note fades in, an archived note fades out.
/// Both are instant when the person asked for less motion.
@MainActor final class NoteMotionTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var isolated: IsolatedSettings!
    private var clock: ManualClock!
    private var scheduler: TestScheduler!
    private var desk: DeskController!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Motion-\(UUID().uuidString)", isDirectory: true)
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
    }

    override func tearDown() async throws {
        scheduler.advance(by: 1)
        store?.stopWatching()
        desk.windowControllers.values.forEach { $0.window?.close() }
        isolated.tearDown()
        try? FileManager.default.removeItem(at: root)
    }

    private func fullMotion() { desk.motionDuration = { $0 } }
    private func noMotion() { desk.motionDuration = { _ in 0 } }

    private func seedAndOpen(_ title: String = "Seeded") throws -> NoteWindowController {
        var note = Note.makeNew(frame: NSRect(x: 40, y: 40, width: 240, height: 200), now: clock.now())
        note.title = title
        note.content = "body"
        store.save(note)
        desk.presentWindow(for: note)
        return try XCTUnwrap(desk.windowControllers[note.id])
    }

    private func appearAnimation(of controller: NoteWindowController) -> CAAnimationGroup? {
        controller.window?.contentView?.layer?
            .animation(forKey: NoteWindowController.appearAnimationKey) as? CAAnimationGroup
    }

    // MARK: - A new note

    func testANewNoteFadesInFor120MillisecondsAndGrowsFrom98Percent() throws {
        fullMotion()
        let id = desk.makeNote()
        let group = try XCTUnwrap(appearAnimation(of: try XCTUnwrap(desk.windowControllers[id])))

        XCTAssertEqual(group.duration, 0.12, accuracy: 0.0001)
        let fade = try XCTUnwrap(group.animations?.first { ($0 as? CABasicAnimation)?.keyPath == "opacity" } as? CABasicAnimation)
        XCTAssertEqual(fade.fromValue as? Double, 0)
        XCTAssertEqual(fade.toValue as? Double, 1)
        let grow = try XCTUnwrap(group.animations?.first { ($0 as? CABasicAnimation)?.keyPath == "transform" } as? CABasicAnimation)
        let from = try XCTUnwrap(grow.fromValue as? NSValue).caTransform3DValue
        XCTAssertEqual(from.m11, 0.98, accuracy: 0.0001)
        XCTAssertEqual(from.m22, 0.98, accuracy: 0.0001)
        XCTAssertTrue(CATransform3DIsIdentity(try XCTUnwrap(grow.toValue as? NSValue).caTransform3DValue))
    }

    func testANewNoteDoesNotMoveUnderReduceMotion() throws {
        noMotion()
        let id = desk.makeNote()
        XCTAssertNil(appearAnimation(of: try XCTUnwrap(desk.windowControllers[id])))
    }

    /// Nothing else moves: a note restored at launch, or opened from the panel, just appears.
    func testARestoredNoteDoesNotAnimateIn() throws {
        fullMotion()
        let controller = try seedAndOpen()
        XCTAssertNil(appearAnimation(of: controller))
    }

    // MARK: - An archived note

    func testAnArchivedNoteIsGoneFromTheDeskAtOnceButItsWindowFadesFor120Milliseconds() throws {
        fullMotion()
        let controller = try seedAndOpen()
        let id = controller.noteId
        let window = try XCTUnwrap(controller.window)
        var iconAsked = 0
        desk.menuBarIconFrame = { iconAsked += 1; return NSRect(x: 900, y: 880, width: 24, height: 22) }
        XCTAssertTrue(window.isVisible)

        controller.closeNote()

        XCTAssertTrue(store.loadArchived().contains { $0.id == id }, "the note was not archived")
        XCTAssertNil(desk.windowControllers[id])
        XCTAssertTrue(controller.isFadingOut)
        XCTAssertTrue(window.isVisible, "the window closed with no fade")
        XCTAssertTrue(window.ignoresMouseEvents, "a fading note still took clicks")
        XCTAssertEqual(iconAsked, 1)

        let placeAfterClose = try XCTUnwrap(desk.layout.layout(for: id))
        window.setFrameOrigin(NSPoint(x: window.frame.origin.x + 30, y: window.frame.origin.y - 30))
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        XCTAssertEqual(desk.layout.layout(for: id), placeAfterClose, "the fade was taken for the person moving the note")

        scheduler.advance(by: 0.119)
        XCTAssertTrue(window.isVisible, "the fade ended early")
        scheduler.advance(by: 0.002)
        XCTAssertFalse(window.isVisible)
    }

    func testAnArchivedNoteClosesAtOnceUnderReduceMotion() throws {
        noMotion()
        let controller = try seedAndOpen()
        let window = try XCTUnwrap(controller.window)

        controller.closeNote()

        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(controller.isFadingOut)
        XCTAssertEqual(scheduler.pendingCount, 0, "something was left to wait for")
    }

    func testNothingFadesForAWindowThatIsNotOnScreen() throws {
        fullMotion()
        let controller = try seedAndOpen()
        let window = try XCTUnwrap(controller.window)
        window.orderOut(nil)
        let before = scheduler.pendingCount

        controller.closeNote()

        XCTAssertEqual(scheduler.pendingCount, before)
        XCTAssertFalse(controller.isFadingOut)
    }

    /// A note that was never used leaves no trace, and that includes no goodbye.
    func testDiscardingAnAbandonedCaptureDoesNotFade() throws {
        fullMotion()
        let id = desk.makeNote()
        let controller = try XCTUnwrap(desk.windowControllers[id])
        let before = scheduler.pendingCount

        controller.discardAbandonedCapture()

        XCTAssertEqual(scheduler.pendingCount, before)
        XCTAssertFalse(controller.isFadingOut)
        XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
    }

    func testAnUndoDuringTheFadeBringsTheNoteBackOnItsOwn() throws {
        fullMotion()
        let controller = try seedAndOpen()
        let id = controller.noteId
        let old = try XCTUnwrap(controller.window)
        controller.closeNote()
        let archived = try XCTUnwrap(store.loadArchived().first { $0.id == id })

        store.restore(archived)
        desk.focusNote(id: id)
        scheduler.advance(by: 0.2)

        XCTAssertFalse(old.isVisible)
        let back = try XCTUnwrap(desk.windowControllers[id])
        XCTAssertTrue(back.window?.isVisible == true)
        XCTAssertNotNil(store.loadNote(id: id))
    }
}
