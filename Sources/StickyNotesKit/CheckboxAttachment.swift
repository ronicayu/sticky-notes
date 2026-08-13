import AppKit

extension NSAttributedString.Key {
    /// Marks the character range of a markdown checkbox prefix
    /// ("- [ ]" / "- [x]" with optional leading whitespace and trailing
    /// space) so the layout manager can hide it and the text view can
    /// overlay-draw a real checkbox in its place.
    static let checkboxRange = NSAttributedString.Key("checkboxRange")
    /// Bool attribute set on the same range. True if the box should render
    /// as checked.
    static let checkboxChecked = NSAttributedString.Key("checkboxChecked")
}

protocol TodoTextViewDelegate: AnyObject {
    func textViewDidToggleCheckbox(at charIndex: Int)
}

/// `NSTextView` subclass that paints a real checkbox over each markdown
/// `- [ ]` line and toggles the source character on click. The text storage
/// itself is never modified — the checkbox is purely a render layer.
final class TodoTextView: NSTextView {
    weak var todoDelegate: TodoTextViewDelegate?

    static let leadingPaddingForCheckbox: CGFloat = 18

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawCheckboxes(in: dirtyRect)
    }

    private func drawCheckboxes(in dirtyRect: NSRect) {
        guard let storage = textStorage, let lm = layoutManager, let tc = textContainer else { return }
        let full = NSRange(location: 0, length: storage.length)

        storage.enumerateAttribute(.checkboxRange, in: full, options: []) { value, range, _ in
            guard value is NSValue else { return }
            let isChecked = (storage.attribute(.checkboxChecked, at: range.location, effectiveRange: nil) as? Bool) ?? false

            // Use the bounding rect of the (transparent) marker chars: that's
            // the gutter where we paint the real checkbox.
            let markerRect = boundingRectInView(for: range, lm: lm, tc: tc)
            guard !markerRect.isEmpty else { return }

            let cbSize: CGFloat = 13
            let cbRect = NSRect(
                x: markerRect.minX + 1,
                y: markerRect.minY + (markerRect.height - cbSize) / 2,
                width: cbSize,
                height: cbSize
            )
            if !cbRect.intersects(dirtyRect) { return }
            drawCheckbox(in: cbRect, checked: isChecked)
        }
    }

    private func drawCheckbox(in rect: NSRect, checked: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        if checked {
            NSColor(srgbRed: 0.27, green: 0.55, blue: 0.95, alpha: 1.0).setFill()
            path.fill()
            // NSTextView is flipped (y grows downward) — the V's bottom point
            // sits at maxY (the visual bottom in flipped coords) and the
            // top-right tip at minY (the visual top).
            let check = NSBezierPath()
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.move(to: NSPoint(x: rect.minX + 2.8, y: rect.midY + 0.2))
            check.line(to: NSPoint(x: rect.minX + 5.2, y: rect.maxY - 3.0))
            check.line(to: NSPoint(x: rect.maxX - 2.4, y: rect.minY + 3.0))
            NSColor.white.setStroke()
            check.stroke()
        } else {
            NSColor.black.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1.1
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let charIdx = checkboxStartIndex(at: viewPoint) {
            todoDelegate?.textViewDidToggleCheckbox(at: charIdx)
            return
        }
        super.mouseDown(with: event)
    }

    private func checkboxStartIndex(at point: NSPoint) -> Int? {
        guard let storage = textStorage, let lm = layoutManager, let tc = textContainer else { return nil }
        let full = NSRange(location: 0, length: storage.length)
        var hit: Int?
        storage.enumerateAttribute(.checkboxRange, in: full, options: []) { value, range, stop in
            guard value is NSValue else { return }
            let markerRect = self.boundingRectInView(for: range, lm: lm, tc: tc)
            if markerRect.isEmpty { return }
            if markerRect.contains(point) {
                hit = range.location
                stop.pointee = true
            }
        }
        return hit
    }

    private func boundingRectInView(for charRange: NSRange,
                                    lm: NSLayoutManager,
                                    tc: NSTextContainer) -> NSRect {
        let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return .zero }
        var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }
}
