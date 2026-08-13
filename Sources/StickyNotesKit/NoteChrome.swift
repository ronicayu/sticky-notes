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
}

/// Invisible region at the top of a note. A normal click+drag moves the
/// window; a double-click toggles the note's collapsed state. Subviews
/// (like buttons) still receive their own clicks via standard hit testing.
final class NoteDragZone: NSView {
    weak var delegate: NoteDragZoneDelegate?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            delegate?.dragZoneDidDoubleClick()
            return
        }
        window?.performDrag(with: event)
    }
}

// MARK: - Color picker

protocol ColorPickerBarDelegate: AnyObject {
    func colorPicker(_ bar: ColorPickerBar, didSelect color: NoteColor)
}

/// Horizontal row of color dots. The currently active color renders as a
/// hollow ring; the rest as filled circles.
final class ColorPickerBar: NSView {
    weak var delegate: ColorPickerBarDelegate?

    var currentColor: NoteColor {
        didSet { needsDisplay = true }
    }

    private let colors = NoteColor.allCases
    private let dotSize: CGFloat = 11
    private let spacing: CGFloat = 7

    init(currentColor: NoteColor) {
        self.currentColor = currentColor
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let count = CGFloat(colors.count)
        return NSSize(width: count * dotSize + (count - 1) * spacing, height: dotSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, color) in colors.enumerated() {
            let rect = dotRect(at: i)
            let path = NSBezierPath(ovalIn: rect)

            if color == currentColor {
                // Hollow ring for the currently selected color.
                NSColor.black.withAlphaComponent(0.35).setStroke()
                path.lineWidth = 1.2
                path.stroke()
            } else {
                NSColor(hex: color.bodyHex)?.setFill()
                path.fill()
                NSColor.black.withAlphaComponent(0.18).setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        for (i, color) in colors.enumerated() {
            if dotRect(at: i).insetBy(dx: -3, dy: -3).contains(local) {
                delegate?.colorPicker(self, didSelect: color)
                return
            }
        }
    }

    private func dotRect(at index: Int) -> NSRect {
        let x = CGFloat(index) * (dotSize + spacing)
        return NSRect(x: x, y: 0, width: dotSize, height: dotSize)
    }
}
