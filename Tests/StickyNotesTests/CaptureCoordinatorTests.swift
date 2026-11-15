import AppKit
import XCTest
@testable import StickyNotesKit

/// Every way a note arrives from outside, driven without a hotkey, a URL
/// handler registration or a real pasteboard.
@MainActor final class CaptureCoordinatorTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var isolated: IsolatedSettings!
    private var clock: ManualClock!
    private var desk: DeskController!
    private var capture: CaptureCoordinator!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(rootURL: root)
        isolated = IsolatedSettings()
        clock = ManualClock()
        desk = DeskController(
            store: store,
            settings: isolated.settings,
            clock: clock,
            undo: UndoCenter(clock: clock),
            recovery: RecoveryFiles(settings: isolated.settings, store: store, clock: clock)
        )
        capture = CaptureCoordinator(desk: desk, store: store)
    }

    override func tearDownWithError() throws {
        desk.windowControllers.values.forEach { $0.window?.close() }
        desk.dailyNote?.window?.close()
        isolated.tearDown()
        try? FileManager.default.removeItem(at: root)
    }

    func testANewCommandMakesANoteWithEveryFieldItCarries() throws {
        capture.perform(.new(title: "Call back", text: "after lunch", color: .blue, labels: ["work", "today"]))

        let note = try XCTUnwrap(store.loadActive().first)
        XCTAssertEqual(note.title, "Call back")
        XCTAssertEqual(note.content, "after lunch")
        XCTAssertEqual(note.color, .blue)
        XCTAssertEqual(note.labels, ["work", "today"])
        XCTAssertNotNil(desk.windowControllers[note.id], "the note was saved but not shown")
    }

    func testADailyCommandOpensTodaysDailyNote() throws {
        let vault = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        isolated.settings.obsidianVaultPath = vault.path
        isolated.settings.dailyNotesPattern = "Daily/{YYYY}-{MM}-{DD}.md"

        capture.perform(.daily)

        XCTAssertTrue(desk.isDailyNoteVisible)
    }

    func testAURLEventIsParsedAndRoutedToANewNote() throws {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: "stickynotes://new?title=From%20Raycast&text=hello"), forKeyword: keyDirectObject)

        capture.handleURLEvent(event, replyEvent: NSAppleEventDescriptor.null())

        let note = try XCTUnwrap(store.loadActive().first)
        XCTAssertEqual(note.title, "From Raycast")
        XCTAssertEqual(note.content, "hello")
    }

    func testAURLThatIsNotOursMakesNothing() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: "https://example.com/new?text=x"), forKeyword: keyDirectObject)

        capture.handleURLEvent(event, replyEvent: NSAppleEventDescriptor.null())

        XCTAssertTrue(store.loadActive().isEmpty)
    }

    func testAServiceSelectionBecomesANoteWithThatTextInTheBody() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CaptureTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("selected in Safari", forType: .string)
        var error: NSString = ""

        capture.makeNoteFromService(pasteboard, userData: nil, error: &error)

        XCTAssertEqual(error, "")
        XCTAssertEqual(try XCTUnwrap(store.loadActive().first).content, "selected in Safari")
    }

    func testAServiceWithNoSelectionReportsItAndMakesNothing() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CaptureTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        var error: NSString = ""

        capture.makeNoteFromService(pasteboard, userData: nil, error: &error)

        XCTAssertEqual(error, "No text was selected.")
        XCTAssertTrue(store.loadActive().isEmpty)
    }
}
