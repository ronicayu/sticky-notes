import XCTest
@testable import StickyNotesKit

final class ToastTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Lifetime

    func testAToastExpiresAfterItsLifetime() {
        let toast = Toast(message: "x", now: now, undo: {})
        XCTAssertFalse(toast.hasExpired(at: now))
        XCTAssertFalse(toast.hasExpired(at: now.addingTimeInterval(Toast.lifetime - 1)))
        XCTAssertTrue(toast.hasExpired(at: now.addingTimeInterval(Toast.lifetime)))
    }

    /// Long enough to notice and react to, short enough not to become
    /// furniture on the screen.
    func testTheLifetimeIsInAReasonableRange() {
        XCTAssertGreaterThanOrEqual(Toast.lifetime, 4)
        XCTAssertLessThanOrEqual(Toast.lifetime, 10)
    }

    func testTheUndoActionRunsWhenInvoked() {
        var ran = false
        let toast = Toast(message: "x", now: now, undo: { ran = true })
        toast.undo()
        XCTAssertTrue(ran)
    }

    // MARK: - Archive wording

    func testArchiveMessageNamesTheNote() {
        XCTAssertEqual(Toast.archivedMessage(noteName: "Groceries"), "Archived “Groceries”")
    }

    func testArchiveMessageFallsBackWhenThereIsNoName() {
        XCTAssertEqual(Toast.archivedMessage(noteName: ""), "Note archived")
        XCTAssertEqual(Toast.archivedMessage(noteName: "   "), "Note archived")
    }

    func testArchiveMessageTrimsTheName() {
        XCTAssertEqual(Toast.archivedMessage(noteName: "  Groceries  "), "Archived “Groceries”")
    }

    /// A long first line would otherwise push the undo button off the toast.
    func testALongNameIsShortened() {
        let long = String(repeating: "a", count: 200)
        let message = Toast.archivedMessage(noteName: long)
        XCTAssertLessThan(message.count, 60, "got \(message.count) characters")
        XCTAssertTrue(message.contains("…"))
    }

    func testShorteningLeavesShortTextAlone() {
        XCTAssertEqual(Toast.shorten("Groceries"), "Groceries")
    }

    func testShorteningRespectsTheLimit() {
        let shortened = Toast.shorten(String(repeating: "b", count: 100), limit: 10)
        XCTAssertEqual(shortened.count, 10)
    }

    // MARK: - Hide wording

    func testHideMessageCountsNotes() {
        XCTAssertEqual(Toast.hiddenMessage(count: 3, label: nil), "Hid 3 notes")
    }

    func testHideMessageIsSingularForOne() {
        XCTAssertEqual(Toast.hiddenMessage(count: 1, label: nil), "Hid 1 note")
    }

    func testHideMessageNamesTheLabel() {
        XCTAssertEqual(Toast.hiddenMessage(count: 2, label: "work"), "Hid 2 #work notes")
        XCTAssertEqual(Toast.hiddenMessage(count: 1, label: "work"), "Hid 1 #work note")
    }

    // MARK: - Controller

    func testShowingAToastMakesItTheCurrentOne() {
        let controller = ToastController()
        controller.show(Toast(message: "first", undo: {}))
        XCTAssertEqual(controller.visibleToast?.message, "first")
        controller.dismiss()
    }

    /// A stack of undo offers is noise; only the most recent action is the one
    /// the user is reacting to.
    func testASecondToastReplacesTheFirst() {
        let controller = ToastController()
        controller.show(Toast(message: "first", undo: {}))
        controller.show(Toast(message: "second", undo: {}))
        XCTAssertEqual(controller.visibleToast?.message, "second")
        controller.dismiss()
    }

    func testPerformingUndoRunsTheActionAndClearsTheToast() {
        let controller = ToastController()
        var ran = false
        controller.show(Toast(message: "x", undo: { ran = true }))

        XCTAssertTrue(controller.performUndo())
        XCTAssertTrue(ran)
        XCTAssertNil(controller.visibleToast, "the toast should go away once undone")
    }

    /// The caller passes the keystroke along when there's nothing pending, so
    /// ⌘Z still reaches the text editor.
    func testUndoWithNothingPendingReportsFalse() {
        let controller = ToastController()
        XCTAssertFalse(controller.performUndo())
    }

    func testUndoOnlyRunsOnce() {
        let controller = ToastController()
        var count = 0
        controller.show(Toast(message: "x", undo: { count += 1 }))

        controller.performUndo()
        controller.performUndo()
        XCTAssertEqual(count, 1, "a dismissed toast must not fire again")
    }

    func testDismissingClearsWithoutRunningTheUndo() {
        let controller = ToastController()
        var ran = false
        controller.show(Toast(message: "x", undo: { ran = true }))

        controller.dismiss()
        XCTAssertFalse(ran, "letting a toast expire is not the same as undoing")
        XCTAssertNil(controller.visibleToast)
    }

    func testReplacingAToastDoesNotRunTheReplacedUndo() {
        let controller = ToastController()
        var firstRan = false
        controller.show(Toast(message: "first", undo: { firstRan = true }))
        controller.show(Toast(message: "second", undo: {}))

        XCTAssertFalse(firstRan)
        controller.dismiss()
    }
}
