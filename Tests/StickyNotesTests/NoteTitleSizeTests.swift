import AppKit
import XCTest
@testable import StickyNotesKit

/// The title is seven points larger than the body text and follows the text
/// size with it: ⌘+ / ⌘- / ⌘0 move both.
///
/// Set `SNAPSHOT_DIR` to also write PNGs of the window at each size.
@MainActor final class NoteTitleSizeTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var layout: DeviceLayoutStore!
    private var savedSize: CGFloat = 0
    private var controllers: [NoteWindowController] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        savedSize = MarkdownStyler.baseFontSize
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteTitleSize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(rootURL: root)
        layout = DeviceLayoutStore(url: root.appendingPathComponent("layout.json"))
    }

    override func tearDown() async throws {
        store?.stopWatching()
        controllers.forEach { $0.window?.close() }
        MarkdownStyler.baseFontSize = savedSize
        try? FileManager.default.removeItem(at: root)
    }

    private func openNote(at size: CGFloat) -> NoteWindowController {
        MarkdownStyler.baseFontSize = size
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
        note.title = "Groceries for Friday"
        note.content = "- [ ] oat milk\n- [x] eggs"
        store.save(note)
        let controller = NoteWindowController(note: note, store: store, layout: layout, onClosed: { _ in })
        controllers.append(controller)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    private func render(_ controller: NoteWindowController, to name: String) throws {
        let view = try XCTUnwrap(controller.window?.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"],
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }

    private func assertTitleFits(_ controller: NoteWindowController, size: CGFloat,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let font = try XCTUnwrap(controller.titleField.font)
        XCTAssertEqual(font.pointSize, size + 7, file: file, line: line)
        XCTAssertEqual(font.fontDescriptor.symbolicTraits.contains(.bold), true, file: file, line: line)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        XCTAssertGreaterThanOrEqual(controller.titleField.frame.height, lineHeight,
                                    "the title row clips a \(size) pt note's title", file: file, line: line)
    }

    func testTheTitleIsSevenPointsAboveTheBodyAtTheSmallestSize() throws {
        let controller = openNote(at: Settings.minBodyFontSize)
        try assertTitleFits(controller, size: 11)
        XCTAssertEqual(controller.titleField.frame.height, 28, "the row grew at the default look")
        try render(controller, to: "note-title-11pt.png")
    }

    func testTheTitleIsSevenPointsAboveTheBodyAtTheLargestSize() throws {
        let controller = openNote(at: Settings.maxBodyFontSize)
        try assertTitleFits(controller, size: 18)
        XCTAssertGreaterThan(controller.titleField.frame.height, 28, "the row did not grow for a 25 pt title")
        try render(controller, to: "note-title-18pt.png")
    }

    func testAnOpenNoteTitleFollowsTheTextSizeUpAndBack() throws {
        let controller = openNote(at: Settings.defaultBodyFontSize)
        try assertTitleFits(controller, size: 13)

        MarkdownStyler.baseFontSize = 18
        controller.restyleForTextSize()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        try assertTitleFits(controller, size: 18)

        MarkdownStyler.baseFontSize = 13
        controller.restyleForTextSize()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        try assertTitleFits(controller, size: 13)
        XCTAssertEqual(controller.titleField.frame.height, 28)
    }

    func testTheDeskPassesTheTextSizeToTheTitleOfEveryOpenNote() throws {
        let isolated = IsolatedSettings()
        defer { isolated.tearDown() }
        let clock = ManualClock()
        let desk = DeskController(
            store: store, settings: isolated.settings, clock: clock, undo: UndoCenter(clock: clock),
            recovery: RecoveryFiles(settings: isolated.settings, store: store, clock: clock)
        )
        desk.makeNote(title: "One")
        let controller = try XCTUnwrap(desk.windowControllers.values.first)
        defer { controller.window?.close() }

        desk.increaseTextSize()

        XCTAssertEqual(controller.titleField.font?.pointSize, isolated.settings.bodyFontSize + 7)
        desk.resetTextSize()
        XCTAssertEqual(controller.titleField.font?.pointSize, Settings.defaultBodyFontSize + 7)
    }
}
