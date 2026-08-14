import AppKit

// MARK: - Flush-left text field

/// Removes the default ~2pt cell-internal padding so the title text origin
/// lines up exactly with the body editor's first character.
final class FlushLeftTextFieldCell: NSTextFieldCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect { rect }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: titleRect(forBounds: cellFrame), in: controlView)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView,
                       editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: titleRect(forBounds: rect),
                   in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView,
                         editor textObj: NSText, delegate: Any?,
                         start selStart: Int, length selLength: Int) {
        super.select(withFrame: titleRect(forBounds: rect),
                     in: controlView, editor: textObj, delegate: delegate,
                     start: selStart, length: selLength)
    }
}

final class FlushLeftTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { FlushLeftTextFieldCell.self }
        set { _ = newValue }
    }
}

// MARK: - Centered title label (collapsed read-only display)

/// Read-only title label drawn at the geometric vertical center of its frame.
/// Used for the collapsed sticky bar where NSTextField's baseline-aligned
/// rendering leaves an empty lower half. Hit-test always returns nil so
/// pointer events fall through to the underlying drag zone.
final class CenteredTitleLabel: NSView {
    var text: String = "" {
        didSet { needsDisplay = true }
    }
    var font: NSFont = NSFont.systemFont(ofSize: 12, weight: .semibold) {
        didSet { needsDisplay = true }
    }
    var textColor: NSColor = .black {
        didSet { needsDisplay = true }
    }
    var placeholder: String = "Title" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let isPlaceholder = text.isEmpty
        let displayString = isPlaceholder ? placeholder : text
        let displayColor = isPlaceholder ? textColor.withAlphaComponent(0.4) : textColor

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: displayColor,
            .paragraphStyle: para
        ]
        let attr = NSAttributedString(string: displayString, attributes: attrs)
        let textHeight = attr.size().height
        let y = max(0, (bounds.height - textHeight) / 2)
        let drawRect = NSRect(x: 0, y: y, width: bounds.width, height: textHeight)
        attr.draw(in: drawRect)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let val = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((val >> 16) & 0xFF) / 255.0
        let g = CGFloat((val >> 8) & 0xFF) / 255.0
        let b = CGFloat(val & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}

// MARK: - Drag zone

protocol NoteDragZoneDelegate: AnyObject {
    func dragZoneDidDoubleClick()
    /// A click that didn't turn into a drag. Only sent while collapsed, where
    /// the 22pt bar is the whole note and double-clicking it isn't discoverable.
    func dragZoneDidClick()
    /// Called once the drag loop finishes, so the note can settle against
    /// nearby edges. `suppressSnapping` is true when the user held Option.
    func dragZoneDidEndDrag(suppressSnapping: Bool)
}

/// Invisible region at the top of a note. A normal click+drag moves the
/// window; a double-click toggles the note's collapsed state. Subviews
/// (like buttons) still receive their own clicks via standard hit testing.
final class NoteDragZone: NSView {
    weak var delegate: NoteDragZoneDelegate?

    /// When true, a click that doesn't move reports `dragZoneDidClick`.
    /// Set while the note is collapsed.
    var reportsSingleClick = false

    override var isFlipped: Bool { true }

    /// True once a click in this sequence already acted. A collapsed note
    /// expands on the first click of a double-click, so letting the second
    /// half toggle as well would collapse it straight back.
    private var singleClickHandled = false

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            if singleClickHandled {
                singleClickHandled = false
                return
            }
            delegate?.dragZoneDidDoubleClick()
            return
        }
        singleClickHandled = false
        let origin = window?.frame.origin
        // performDrag runs its own event loop and returns when the mouse is
        // released — snapping here means the note settles once, on drop,
        // rather than fighting the pointer the whole way.
        window?.performDrag(with: event)

        // Distinguish a click from a drag by how far the window actually
        // moved. performDrag swallows the intermediate events, so the window's
        // own displacement is the only signal available.
        let moved = origin.map { start in
            guard let end = window?.frame.origin else { return false }
            return abs(end.x - start.x) > 2 || abs(end.y - start.y) > 2
        } ?? false

        if !moved {
            if reportsSingleClick {
                delegate?.dragZoneDidClick()
                singleClickHandled = true
            }
            return
        }
        let optionHeld = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option)
        delegate?.dragZoneDidEndDrag(suppressSnapping: optionHeld)
    }
}


// MARK: - Resize affordance

/// Three diagonal dots in the bottom-right corner, drawn only while the
/// pointer is over the note.
///
/// The window is borderless and resizable, which gives no visual hint that
/// dragging the corner does anything. This doesn't implement resizing — AppKit
/// already handles that — it just says the corner is live.
final class ResizeGripView: NSView {
    override var isFlipped: Bool { true }

    /// Purely decorative: the window's own resize region handles the drag, and
    /// swallowing clicks here would break it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let color = (Appearance.isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.28)
        color.setFill()

        let dot: CGFloat = 2
        let gap: CGFloat = 4
        // Rows of 1, 2, 3 dots stepping out from the corner.
        for row in 0..<3 {
            for column in 0...row {
                let x = bounds.maxX - gap - dot - CGFloat(row - column) * gap
                let y = bounds.maxY - gap - dot - CGFloat(column) * gap
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dot, height: dot)).fill()
            }
        }
    }
}
