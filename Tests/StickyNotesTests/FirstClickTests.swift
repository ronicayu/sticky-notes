import AppKit
import XCTest
@testable import StickyNotesKit

/// The click that brings a note forward. AppKit hands it to the view under the
/// pointer only if that view accepts first mouse.
@MainActor final class FirstClickTests: XCTestCase {
    func testTheClickThatBringsANoteForwardNeverReachesItsText() throws {
        _ = NSApplication.shared
        let textView = TodoTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))

        XCTAssertFalse(
            textView.acceptsFirstMouse(for: click),
            "a link or checkbox under the pointer would act on the click meant to focus the note"
        )
    }
}
