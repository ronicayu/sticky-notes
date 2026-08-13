import Foundation
import CoreGraphics

/// Geometry for note windows: snapping a dragged note to nearby edges, and
/// packing a screenful of them into a grid.
///
/// Pure functions over rectangles so the behavior can be tested without
/// dragging anything.
enum WindowArrangement {

    /// How close an edge has to be before it pulls.
    static let snapThreshold: CGFloat = 8

    /// Nudge `frame` so its edges line up with the screen or with a nearby
    /// note. Returns the frame unchanged when nothing is close enough.
    ///
    /// Each axis is decided independently, and the nearest candidate wins, so
    /// a note dropped into a corner catches both walls.
    static func snap(
        _ frame: CGRect,
        toScreen screen: CGRect,
        others: [CGRect],
        threshold: CGFloat = snapThreshold
    ) -> CGRect {
        var result = frame

        var xCandidates: [(offset: CGFloat, distance: CGFloat)] = []
        var yCandidates: [(offset: CGFloat, distance: CGFloat)] = []

        func considerX(_ target: CGFloat, from current: CGFloat) {
            let distance = abs(target - current)
            if distance <= threshold { xCandidates.append((target - current, distance)) }
        }
        func considerY(_ target: CGFloat, from current: CGFloat) {
            let distance = abs(target - current)
            if distance <= threshold { yCandidates.append((target - current, distance)) }
        }

        // Screen walls.
        considerX(screen.minX, from: frame.minX)
        considerX(screen.maxX, from: frame.maxX)
        considerY(screen.minY, from: frame.minY)
        considerY(screen.maxY, from: frame.maxY)

        for other in others {
            // Edge-to-edge: sit flush beside a neighbour.
            considerX(other.maxX, from: frame.minX)
            considerX(other.minX, from: frame.maxX)
            considerY(other.maxY, from: frame.minY)
            considerY(other.minY, from: frame.maxY)
            // Edge-to-same-edge: line up in a column or a row.
            considerX(other.minX, from: frame.minX)
            considerX(other.maxX, from: frame.maxX)
            considerY(other.minY, from: frame.minY)
            considerY(other.maxY, from: frame.maxY)
        }

        if let best = xCandidates.min(by: { $0.distance < $1.distance }) {
            result.origin.x += best.offset
        }
        if let best = yCandidates.min(by: { $0.distance < $1.distance }) {
            result.origin.y += best.offset
        }
        return result
    }

    /// Lay `sizes` out left-to-right, top-to-bottom inside `screen`, keeping
    /// each note's own size. Rows are as tall as their tallest note.
    ///
    /// Notes that would overflow the bottom wrap back to the top and shift
    /// right by a column, so nothing lands off screen — a tidy-up that hides
    /// windows would be worse than the mess it replaced.
    static func grid(
        sizes: [CGSize],
        in screen: CGRect,
        gap: CGFloat = 12
    ) -> [CGRect] {
        guard !sizes.isEmpty else { return [] }

        var frames: [CGRect] = []
        var x = screen.minX + gap
        var y = screen.maxY - gap        // AppKit's origin is bottom-left
        var rowHeight: CGFloat = 0
        var columnWidth: CGFloat = 0

        for size in sizes {
            let width = min(size.width, screen.width - gap * 2)
            let height = min(size.height, screen.height - gap * 2)

            // Wrap to the next row when this note would run off the right.
            if x + width > screen.maxX - gap, x > screen.minX + gap {
                x = screen.minX + gap
                y -= rowHeight + gap
                rowHeight = 0
            }
            // Out of vertical room: start a fresh column band from the top.
            if y - height < screen.minY + gap {
                y = screen.maxY - gap
                x += columnWidth + gap
                rowHeight = 0
                columnWidth = 0
                if x + width > screen.maxX - gap { x = screen.minX + gap }
            }

            frames.append(CGRect(x: x, y: y - height, width: width, height: height))
            x += width + gap
            rowHeight = max(rowHeight, height)
            columnWidth = max(columnWidth, width)
        }
        return frames
    }

    /// Classic overlapping cascade from the top-left.
    static func cascade(
        sizes: [CGSize],
        in screen: CGRect,
        step: CGFloat = 28
    ) -> [CGRect] {
        var frames: [CGRect] = []
        for (index, size) in sizes.enumerated() {
            let offset = CGFloat(index) * step
            var x = screen.minX + 20 + offset
            var y = screen.maxY - 20 - offset - size.height

            // Restart the cascade rather than walking off the screen.
            if x + size.width > screen.maxX || y < screen.minY {
                let wrapped = CGFloat(index % 8) * step
                x = screen.minX + 20 + wrapped
                y = screen.maxY - 20 - wrapped - size.height
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
        }
        return frames
    }
}
