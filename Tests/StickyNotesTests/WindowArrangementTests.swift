import XCTest
@testable import StickyNotesKit

final class WindowArrangementTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func note(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 240, _ h: CGFloat = 200) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Snapping

    func testFrameFarFromEverythingIsUnchanged() {
        let frame = note(500, 400)
        XCTAssertEqual(WindowArrangement.snap(frame, toScreen: screen, others: []), frame)
    }

    func testSnapsToTheLeftScreenEdge() {
        let snapped = WindowArrangement.snap(note(5, 400), toScreen: screen, others: [])
        XCTAssertEqual(snapped.minX, screen.minX)
    }

    func testSnapsToTheRightScreenEdge() {
        let snapped = WindowArrangement.snap(note(1440 - 240 - 5, 400), toScreen: screen, others: [])
        XCTAssertEqual(snapped.maxX, screen.maxX)
    }

    func testSnapsToTheTopAndBottomScreenEdges() {
        XCTAssertEqual(WindowArrangement.snap(note(500, 5), toScreen: screen, others: []).minY, screen.minY)
        XCTAssertEqual(WindowArrangement.snap(note(500, 900 - 200 - 4), toScreen: screen, others: []).maxY, screen.maxY)
    }

    func testSnapsBothAxesInACorner() {
        let snapped = WindowArrangement.snap(note(4, 6), toScreen: screen, others: [])
        XCTAssertEqual(snapped.minX, screen.minX)
        XCTAssertEqual(snapped.minY, screen.minY)
    }

    func testJustOutsideTheThresholdDoesNotSnap() {
        let frame = note(WindowArrangement.snapThreshold + 1, 400)
        XCTAssertEqual(WindowArrangement.snap(frame, toScreen: screen, others: []), frame)
    }

    func testSnapsFlushAgainstAnotherNote() {
        let neighbour = note(500, 400)
        // Dropped just to the right of the neighbour's trailing edge.
        let snapped = WindowArrangement.snap(note(745, 400), toScreen: screen, others: [neighbour])
        XCTAssertEqual(snapped.minX, neighbour.maxX, "should sit flush beside its neighbour")
    }

    func testAlignsWithANeighboursLeadingEdge() {
        let neighbour = note(500, 400)
        let snapped = WindowArrangement.snap(note(504, 100), toScreen: screen, others: [neighbour])
        XCTAssertEqual(snapped.minX, neighbour.minX, "should line up into a column")
    }

    func testNearestCandidateWins() {
        let far = note(0, 400)          // its maxX is 240
        let near = note(300, 400)       // its minX is 300
        // Frame's leading edge at 298: 2pt from `near.minX`, 58pt from far.maxX.
        let snapped = WindowArrangement.snap(note(298, 100), toScreen: screen, others: [far, near])
        XCTAssertEqual(snapped.minX, 300)
    }

    func testAThresholdOfZeroDisablesSnapping() {
        let frame = note(1, 1)
        XCTAssertEqual(WindowArrangement.snap(frame, toScreen: screen, others: [], threshold: 0), frame)
    }

    func testSnappingNeverChangesTheSize() {
        let frame = note(4, 6, 321, 234)
        let snapped = WindowArrangement.snap(frame, toScreen: screen, others: [note(500, 500)])
        XCTAssertEqual(snapped.size, frame.size)
    }

    // MARK: - Grid

    func testGridPlacesEveryNote() {
        let sizes = Array(repeating: CGSize(width: 240, height: 200), count: 12)
        XCTAssertEqual(WindowArrangement.grid(sizes: sizes, in: screen).count, 12)
    }

    func testGridKeepsEveryNoteOnScreen() {
        let sizes = Array(repeating: CGSize(width: 240, height: 200), count: 40)
        for frame in WindowArrangement.grid(sizes: sizes, in: screen) {
            XCTAssertTrue(screen.contains(frame), "\(frame) escaped the screen")
        }
    }

    func testGridStartsAtTheTopLeft() {
        let frames = WindowArrangement.grid(sizes: [CGSize(width: 240, height: 200)], in: screen, gap: 12)
        XCTAssertEqual(frames.first?.minX, 12)
        XCTAssertEqual(frames.first?.maxY, screen.maxY - 12)
    }

    func testGridRowsDoNotOverlap() {
        let sizes = Array(repeating: CGSize(width: 240, height: 200), count: 8)
        let frames = WindowArrangement.grid(sizes: sizes, in: screen)
        for (i, a) in frames.enumerated() {
            for b in frames[(i + 1)...] {
                XCTAssertFalse(a.intersects(b), "\(a) overlaps \(b)")
            }
        }
    }

    func testGridPreservesEachNotesOwnSize() {
        let sizes = [CGSize(width: 200, height: 150), CGSize(width: 320, height: 260)]
        let frames = WindowArrangement.grid(sizes: sizes, in: screen)
        XCTAssertEqual(frames[0].size, sizes[0])
        XCTAssertEqual(frames[1].size, sizes[1])
    }

    func testGridClampsANoteBiggerThanTheScreen() {
        let frames = WindowArrangement.grid(sizes: [CGSize(width: 5000, height: 5000)], in: screen)
        XCTAssertTrue(screen.contains(try! XCTUnwrap(frames.first)))
    }

    func testGridOfNothingIsEmpty() {
        XCTAssertTrue(WindowArrangement.grid(sizes: [], in: screen).isEmpty)
    }

    // MARK: - Cascade

    func testCascadePlacesEveryNote() {
        let sizes = Array(repeating: CGSize(width: 240, height: 200), count: 10)
        XCTAssertEqual(WindowArrangement.cascade(sizes: sizes, in: screen).count, 10)
    }

    func testCascadeStepsDownAndRight() {
        let sizes = Array(repeating: CGSize(width: 240, height: 200), count: 3)
        let frames = WindowArrangement.cascade(sizes: sizes, in: screen)
        XCTAssertLessThan(frames[0].minX, frames[1].minX)
        XCTAssertGreaterThan(frames[0].minY, frames[1].minY, "each note should step downward")
    }

    func testCascadeKeepsEveryNoteOnScreen() {
        let sizes = Array(repeating: CGSize(width: 240, height: 200), count: 60)
        for frame in WindowArrangement.cascade(sizes: sizes, in: screen) {
            XCTAssertTrue(screen.intersects(frame), "\(frame) is entirely off screen")
        }
    }
}
