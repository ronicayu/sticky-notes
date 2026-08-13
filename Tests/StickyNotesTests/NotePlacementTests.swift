import XCTest
@testable import StickyNotesKit

final class NotePlacementTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    /// A second display sitting to the right, with a different size and a
    /// non-zero origin — the case the old hardcoded rect got wrong.
    private let sideScreen = CGRect(x: 1440, y: 200, width: 1920, height: 1080)

    private func contains(_ frame: CGRect, in screen: CGRect) -> Bool {
        screen.contains(frame)
    }

    // MARK: - First note

    func testFirstNoteLandsOnScreen() {
        let frame = NotePlacement.next(previous: nil, screen: screen)
        XCTAssertTrue(contains(frame, in: screen), "\(frame) is not inside \(screen)")
    }

    func testFirstNoteIsHorizontallyCentered() {
        let frame = NotePlacement.next(previous: nil, screen: screen)
        XCTAssertEqual(frame.midX, screen.midX, accuracy: 1)
    }

    func testFirstNoteSitsInTheUpperHalf() {
        let frame = NotePlacement.next(previous: nil, screen: screen)
        XCTAssertGreaterThan(frame.midY, screen.midY, "a new note should open where you're looking")
    }

    func testPlacementIsDeterministic() {
        let a = NotePlacement.next(previous: nil, screen: screen)
        let b = NotePlacement.next(previous: nil, screen: screen)
        XCTAssertEqual(a, b, "placement must not be random — you have to be able to find the note")
    }

    func testFirstNoteRespectsTheScreensOrigin() {
        let frame = NotePlacement.next(previous: nil, screen: sideScreen)
        XCTAssertTrue(contains(frame, in: sideScreen), "\(frame) escaped the second display")
    }

    // MARK: - Cascade

    func testSecondNoteCascadesDownAndRight() {
        let first = NotePlacement.next(previous: nil, screen: screen)
        let second = NotePlacement.next(previous: first, screen: screen)

        XCTAssertGreaterThan(second.minX, first.minX)
        XCTAssertLessThan(second.maxY, first.maxY, "each note should step downward")
    }

    func testCascadeStepIsConsistent() {
        let first = NotePlacement.next(previous: nil, screen: screen)
        let second = NotePlacement.next(previous: first, screen: screen)
        XCTAssertEqual(second.minX - first.minX, NotePlacement.step, accuracy: 0.5)
    }

    func testALongCascadeNeverLeavesTheScreen() {
        var previous: CGRect?
        for i in 0..<200 {
            let frame = NotePlacement.next(previous: previous, screen: screen)
            XCTAssertTrue(contains(frame, in: screen), "note \(i) at \(frame) escaped")
            previous = frame
        }
    }

    func testCascadeRestartsRatherThanWalkingOff() {
        var previous = NotePlacement.next(previous: nil, screen: screen)
        var sawRestart = false
        for _ in 0..<200 {
            let next = NotePlacement.next(previous: previous, screen: screen)
            if next.minX < previous.minX { sawRestart = true; break }
            previous = next
        }
        XCTAssertTrue(sawRestart, "the cascade should return to the anchor instead of marching off")
    }

    func testCascadeRestartsToTheAnchor() {
        // A previous note pinned to the bottom-right leaves no room to step.
        let cornered = CGRect(x: screen.maxX - 250, y: screen.minY + 5, width: 240, height: 200)
        let next = NotePlacement.next(previous: cornered, screen: screen)
        XCTAssertEqual(next, NotePlacement.next(previous: nil, screen: screen))
    }

    // MARK: - Awkward screens

    func testANoteBiggerThanTheScreenIsClampedToFit() {
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 250)
        let frame = NotePlacement.next(previous: nil, screen: tiny)
        XCTAssertTrue(contains(frame, in: tiny), "\(frame) does not fit \(tiny)")
    }

    func testPlacementHonoursACustomSize() {
        let size = CGSize(width: 420, height: 380)
        let frame = NotePlacement.next(previous: nil, screen: screen, size: size)
        XCTAssertEqual(frame.size, size)
    }

    func testPlacementOnAScreenWithAMenuBarInset() {
        // visibleFrame excludes the menu bar, so minY is non-zero.
        let inset = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let frame = NotePlacement.next(previous: nil, screen: inset)
        XCTAssertTrue(contains(frame, in: inset), "\(frame) overlapped the menu bar or Dock")
    }

    // MARK: - Choosing a screen

    func testThePointersScreenWins() {
        let pointer = CGPoint(x: 2000, y: 600)   // inside sideScreen
        XCTAssertEqual(
            NotePlacement.screenUnderPointer(mouse: pointer, screens: [screen, sideScreen], main: screen),
            sideScreen
        )
    }

    func testAPointerOnNoScreenFallsBackToMain() {
        let pointer = CGPoint(x: -5000, y: -5000)
        XCTAssertEqual(
            NotePlacement.screenUnderPointer(mouse: pointer, screens: [screen, sideScreen], main: screen),
            screen
        )
    }

    func testWithNoMainScreenTheFirstOneIsUsed() {
        XCTAssertEqual(
            NotePlacement.screenUnderPointer(mouse: CGPoint(x: -1, y: -1), screens: [sideScreen], main: nil),
            sideScreen
        )
    }

    func testNoScreensAtAllPlacesNothing() {
        XCTAssertNil(NotePlacement.screenUnderPointer(mouse: .zero, screens: [], main: nil))
    }
}
