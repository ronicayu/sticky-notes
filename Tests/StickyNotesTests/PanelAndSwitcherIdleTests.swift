import AppKit
import XCTest
@testable import StickyNotesKit

/// The notes panel and the quick switcher do no work for the store while they
/// are hidden, and show what changed in the meantime when they are opened.
@MainActor final class PanelAndSwitcherIdleTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var today = "first"

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelAndSwitcherIdle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(rootURL: root)
        today = "first"
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func seed(_ title: String, content: String = "") -> Note {
        var note = Note.makeNew(frame: NSRect(x: 40, y: 40, width: 240, height: 200), now: Date())
        note.title = title
        note.content = content
        store.save(note)
        return note
    }

    private func todaysNote() -> Note {
        DailyNote.candidate(body: today, day: Date(), modified: nil, color: .yellow)
    }

    private func makePanel() -> NotesPanelController {
        NotesPanelController(store: store, dailyNote: { [unowned self] in todaysNote() }, onActivate: { _ in })
    }

    private func makeSwitcher() -> QuickSwitcherController {
        QuickSwitcherController(store: store, dailyNote: { [unowned self] in todaysNote() }, onChoose: { _ in })
    }

    private func drainMainQueue() {
        for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    // MARK: - Notes panel

    func testAHiddenPanelDoesNotReloadWhenTheStoreChanges() {
        let panel = makePanel()
        let reloads = panel.reloadCount

        let note = seed("saved while hidden")
        store.archive(note)
        drainMainQueue()
        XCTAssertEqual(panel.reloadCount, reloads, "a hidden panel rebuilt its list after a save and an archive")

        let reads = store.readCount
        NotificationCenter.default.post(name: NoteStore.didChange, object: store)
        drainMainQueue()
        XCTAssertEqual(panel.reloadCount, reloads, "a hidden panel rebuilt its list after a reset")
        XCTAssertEqual(store.readCount, reads, "the panel read the disk while hidden")
    }

    func testAPanelShownAfterChangesListsThem() {
        let panel = makePanel()
        XCTAssertEqual(panel.rowCount, 1, "just today's note")

        let archived = seed("will be archived")
        seed("stays")
        store.archive(archived)
        drainMainQueue()
        XCTAssertEqual(panel.rowCount, 1, "a hidden panel should not have changed")

        let reloads = panel.reloadCount
        panel.showWindow(nil)
        defer { panel.window?.orderOut(nil) }

        XCTAssertEqual(panel.reloadCount, reloads + 1)
        XCTAssertEqual(panel.visibleTitles.count, 2)
        XCTAssertTrue(panel.visibleTitles.contains("stays"))
        XCTAssertFalse(panel.visibleTitles.contains("will be archived"))
    }

    func testAPanelShownAgainShowsTodaysNoteAsItIsNow() {
        let panel = makePanel()
        panel.showWindow(nil)
        XCTAssertEqual(panel.visibleTitles.first, "Today")
        panel.window?.orderOut(nil)

        today = "changed while the panel was closed"
        panel.showWindow(nil)
        defer { panel.window?.orderOut(nil) }

        XCTAssertEqual(panel.rowCount, 1)
        panel.search("closed")
        XCTAssertEqual(panel.rowCount, 1, "today's note has the new text")
        panel.search("first")
        XCTAssertEqual(panel.rowCount, 0, "today's note still has the old text")
    }

    func testAVisiblePanelStillFollowsTheStore() {
        let panel = makePanel()
        panel.showWindow(nil)
        defer { panel.window?.orderOut(nil) }
        let reloads = panel.reloadCount

        seed("typed while the panel was open")
        drainMainQueue()

        XCTAssertGreaterThan(panel.reloadCount, reloads)
        XCTAssertTrue(panel.visibleTitles.contains("typed while the panel was open"))
    }

    func testAPanelThatWasHiddenAgainStopsFollowingTheStore() {
        let panel = makePanel()
        panel.showWindow(nil)
        panel.window?.orderOut(nil)
        let reloads = panel.reloadCount

        seed("after hiding")
        drainMainQueue()

        XCTAssertEqual(panel.reloadCount, reloads)
    }

    func testAChangeThatLandsAfterThePanelIsHiddenIsNotReloaded() {
        let panel = makePanel()
        panel.showWindow(nil)
        let reloads = panel.reloadCount

        seed("saved just before hiding")
        panel.window?.orderOut(nil)
        drainMainQueue()

        XCTAssertEqual(panel.reloadCount, reloads, "the queued reload ran for a hidden panel")
        panel.showWindow(nil)
        defer { panel.window?.orderOut(nil) }
        XCTAssertTrue(panel.visibleTitles.contains("saved just before hiding"))
    }

    func testAPanelThatBecomesVisibleWithoutShowWindowReloadsWhatItSkipped() {
        let panel = makePanel()
        seed("saved while the app was hidden")
        drainMainQueue()
        XCTAssertFalse(panel.visibleTitles.contains("saved while the app was hidden"))

        // The app unhiding orders the window back without calling showWindow.
        panel.window?.orderFront(nil)
        defer { panel.window?.orderOut(nil) }
        NotificationCenter.default.post(name: NSApplication.didUnhideNotification, object: NSApp)

        XCTAssertTrue(panel.visibleTitles.contains("saved while the app was hidden"))
    }

    // MARK: - Quick switcher

    func testAHiddenSwitcherDoesNotReadTheStoreWhenItChanges() {
        let switcher = makeSwitcher()
        switcher.prepare()
        XCTAssertFalse(switcher.isVisible)
        let reads = store.readCount

        NotificationCenter.default.post(name: NoteStore.didChange, object: store)
        drainMainQueue()

        XCTAssertEqual(store.readCount, reads, "the hidden switcher read the disk")
    }

    func testASwitcherOpenedAfterChangesFindsThemAndTodaysNoteAsItIsNow() {
        let switcher = makeSwitcher()
        switcher.prepare()
        seed("quokka notes", content: "about quokkas")
        today = "walrus today"
        drainMainQueue()

        switcher.prepare()

        switcher.search("quokka")
        XCTAssertEqual(switcher.resultCount, 1)
        switcher.search("walrus")
        XCTAssertEqual(switcher.resultCount, 1, "today's note has the new text")
        XCTAssertTrue(switcher.previewText.contains("walrus today"))
        switcher.search("first")
        XCTAssertEqual(switcher.resultCount, 0)
    }
}
