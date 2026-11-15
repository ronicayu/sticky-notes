import AppKit
import XCTest
@testable import StickyNotesKit

@MainActor final class UndoCenterTests: XCTestCase {
    private let clock = ManualClock()

    override func setUp() async throws {
        _ = NSApplication.shared
    }

    func testOnlyTheLatestOfferIsKeptAndUndoRunsIt() {
        let center = UndoCenter(clock: clock)
        var ran: [String] = []
        center.offerUndoForHiding(count: 2, label: nil) { ran.append("first") }
        center.offerUndoForHiding(count: 3, label: "work") { ran.append("second") }
        defer { center.dismiss() }

        center.undoLastAction(nil)

        XCTAssertEqual(ran, ["second"])
        XCTAssertFalse(center.hasPendingOffer)
    }

    func testHidingNothingOffersNothing() {
        let center = UndoCenter(clock: clock)
        center.offerUndoForHiding(count: 0, label: nil) { XCTFail("undo of nothing") }
        XCTAssertFalse(center.hasPendingOffer)
    }

    func testAnArchiveOfferRestoresTheNoteAndARefusedCloseOffersARetry() {
        let center = UndoCenter(clock: clock)
        var restored = 0
        var retried = 0
        center.offerUndoForArchive(of: Note.makeNew(frame: .zero, now: clock.now())) { restored += 1 }
        XCTAssertTrue(center.hasPendingOffer)
        center.undoLastAction(nil)
        XCTAssertEqual(restored, 1)

        center.offerRetryAfterRefusedClose { retried += 1 }
        defer { center.dismiss() }
        center.undoLastAction(nil)
        XCTAssertEqual(retried, 1)
    }

    func testDismissingDropsTheOffer() {
        let center = UndoCenter(clock: clock)
        center.offerUndoForHiding(count: 1, label: nil) { XCTFail("undone after dismiss") }
        center.dismiss()
        XCTAssertFalse(center.hasPendingOffer)
    }
}

@MainActor final class RecoveryFilesTests: XCTestCase {
    private var isolated: IsolatedSettings!
    private var store: NoteStore!
    private var clock: ManualClock!
    private var recovery: RecoveryFiles!

    override func setUp() async throws {
        isolated = IsolatedSettings()
        clock = ManualClock()
        store = NoteStore(rootURL: isolated.localRoot.appendingPathComponent("notes"))
        recovery = RecoveryFiles(settings: isolated.settings, store: store, clock: clock)
    }

    override func tearDown() async throws {
        isolated.tearDown()
    }

    func testTheFolderSitsBesideTheLocalStorageNotInsideTheNotes() {
        XCTAssertEqual(recovery.folder, isolated.settings.localStorageRoot.appendingPathComponent("Recovered", isDirectory: true))
    }

    func testANoteIsWrittenUnderItsIdWithItsText() throws {
        var note = Note.makeNew(frame: .zero, now: clock.now())
        note.title = "Draft"
        note.content = "unsaved words"

        XCTAssertTrue(recovery.write(note))

        let files = try FileManager.default.contentsOfDirectory(at: recovery.folder, includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix(note.id.uuidString) })
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("unsaved words"))
    }

    func testADailyNoteIsWrittenUnderItsDayWithItsBodyOnly() throws {
        XCTAssertTrue(recovery.writeDaily(body: "today's plan", day: clock.now()))

        let files = try FileManager.default.contentsOfDirectory(at: recovery.folder, includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("Daily ") })
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "today's plan")
    }

    func testWritingReportsFailureWhenTheFolderCannotBeCreated() throws {
        try FileManager.default.createDirectory(at: recovery.folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: recovery.folder)

        XCTAssertFalse(recovery.writeDaily(body: "lost", day: clock.now()))
    }
}
