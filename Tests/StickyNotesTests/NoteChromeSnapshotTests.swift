import AppKit
import XCTest
@testable import StickyNotesKit

/// Renders a note's footer and collapsed bar offscreen, in light and dark, so a
/// change to the label chips or the title bar shows up as more than an assertion.
/// Set SNAPSHOT_DIR to keep the images.
@MainActor final class NoteChromeSnapshotTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var controllers: [NoteWindowController] = []
    private let originalAppearance = NSApp?.appearance

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChromeSnapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(rootURL: root)
    }

    override func tearDown() async throws {
        NSApp.appearance = originalAppearance
        store?.stopWatching()
        controllers.forEach { $0.window?.close() }
        try? FileManager.default.removeItem(at: root)
    }

    private func save(_ view: NSView, as name: String) throws {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"],
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        XCTAssertGreaterThan(rep.pixelsWide, 0)
    }

    private func render(dark: Bool, collapsed: Bool, to name: String) throws {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        note.title = "Groceries"
        note.content = "- [x] eggs\n- [ ] milk"
        note.labels = ["home", "weekly", "later"]
        note.color = dark ? .blue : .yellow
        store.save(note)
        let layoutURL = root.appendingPathComponent("layout-\(name).json")
        let controller = NoteWindowController(
            note: note, store: store, layout: DeviceLayoutStore(url: layoutURL, scheduler: TestScheduler()),
            placing: { _ in NSRect(x: 0, y: 0, width: 300, height: 200) }, onClosed: { _ in }
        )
        controllers.append(controller)
        if collapsed { controller.toggleCollapse() }
        let view = try XCTUnwrap(controller.window?.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"],
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        XCTAssertGreaterThan(rep.pixelsWide, 0)
    }

    func testANoteWithLabelChipsRendersInLightAndDark() throws {
        try render(dark: false, collapsed: false, to: "note-chips-light.png")
        try render(dark: true, collapsed: false, to: "note-chips-dark.png")
    }

    func testACollapsedNoteRendersItsTitleBar() throws {
        try render(dark: false, collapsed: true, to: "note-collapsed-light.png")
    }

    func testTheWelcomeNoteWithAllFourTasksDone() throws {
        NSApp.appearance = NSAppearance(named: .aqua)
        let suite = "ChromeSnapshot-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let welcome = try XCTUnwrap(WelcomeNote.makeIfNeeded(store: store, defaults: defaults))
        let controller = NoteWindowController(
            note: welcome, store: store,
            layout: DeviceLayoutStore(url: root.appendingPathComponent("layout-welcome.json"), scheduler: TestScheduler()),
            placing: { _ in NSRect(x: 0, y: 0, width: 320, height: 340) }, onClosed: { _ in }
        )
        controllers.append(controller)
        let checklist = WelcomeChecklist(defaults: defaults, windowFor: { _ in controller })
        WelcomeNote.Step.allCases.forEach(checklist.did)

        let text = controller.textView.string
        XCTAssertTrue(WelcomeNote.allTasksChecked(in: text))
        XCTAssertTrue(text.contains(WelcomeNote.doneLine))
        XCTAssertFalse(checklist.isListening)
        XCTAssertEqual(MarkdownEditing.checkboxProgress(in: text)?.done, 4)
        try save(try XCTUnwrap(controller.window?.contentView), as: "welcome-done.png")
    }
}
