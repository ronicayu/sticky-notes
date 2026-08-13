import Foundation
import CoreGraphics

/// Where a new note lands.
///
/// This used to be `Double.random(in:)` over a hardcoded 1440×900 rectangle,
/// which put notes off screen on any other display and — worse — meant you had
/// to hunt for the note you just made. Notes now cascade from a fixed anchor
/// on the screen you're pointing at, so the next one is always where you
/// expect it.
enum NotePlacement {
    static let defaultSize = CGSize(width: 240, height: 200)

    /// Distance between successive notes in a cascade.
    static let step: CGFloat = 26

    /// Frame for the next new note.
    ///
    /// - Parameters:
    ///   - previous: frame of the last note created this session, if any.
    ///   - screen: the visible frame (excluding menu bar and Dock) to place into.
    ///   - size: the new note's size.
    static func next(
        previous: CGRect?,
        screen: CGRect,
        size: CGSize = defaultSize
    ) -> CGRect {
        let width = min(size.width, max(80, screen.width - 2 * margin))
        let height = min(size.height, max(80, screen.height - 2 * margin))
        let clamped = CGSize(width: width, height: height)

        guard let previous = previous else {
            return anchor(in: screen, size: clamped)
        }

        let candidate = CGRect(
            x: previous.minX + step,
            y: previous.maxY - step - clamped.height,
            width: clamped.width,
            height: clamped.height
        )
        // Restart rather than march off the edge — a cascade that walks
        // offscreen is the bug this replaced.
        guard fits(candidate, in: screen) else {
            return anchor(in: screen, size: clamped)
        }
        return candidate
    }

    /// First note of a session: horizontally centered and set high, the same
    /// place the quick switcher opens, so the app has one visual home.
    static func anchor(in screen: CGRect, size: CGSize) -> CGRect {
        let origin = CGPoint(
            x: screen.midX - size.width / 2,
            y: screen.minY + screen.height * 0.62 - size.height / 2
        )
        return clamp(CGRect(origin: origin, size: size), to: screen)
    }

    /// The visible frame of the screen under the pointer, falling back to the
    /// main screen. Separated so callers can be tested with a fixed rect.
    static func screenUnderPointer(
        mouse: CGPoint,
        screens: [CGRect],
        main: CGRect?
    ) -> CGRect? {
        screens.first(where: { $0.contains(mouse) }) ?? main ?? screens.first
    }

    private static let margin: CGFloat = 12

    private static func fits(_ rect: CGRect, in screen: CGRect) -> Bool {
        rect.minX >= screen.minX + margin
            && rect.maxX <= screen.maxX - margin
            && rect.minY >= screen.minY + margin
            && rect.maxY <= screen.maxY - margin
    }

    private static func clamp(_ rect: CGRect, to screen: CGRect) -> CGRect {
        var result = rect
        result.origin.x = min(max(rect.minX, screen.minX + margin), screen.maxX - margin - rect.width)
        result.origin.y = min(max(rect.minY, screen.minY + margin), screen.maxY - margin - rect.height)
        return result
    }
}
