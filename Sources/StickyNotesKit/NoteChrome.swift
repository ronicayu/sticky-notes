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
///
/// For VoiceOver it is plain text, or a button when `onPress` is set: the bar of
/// a collapsed note is all there is to press to expand it.
final class CenteredTitleLabel: NSView {
    /// What pressing the label does. Set while the label is the way back to a
    /// collapsed note's text.
    var onPress: (() -> Void)?
    /// What VoiceOver says for the title, when it should differ from the drawn
    /// text, which may carry a task count such as "2/5".
    var spokenTitle: String?
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

    private var spokenName: String {
        spokenTitle ?? (text.isEmpty ? placeholder : text)
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? {
        onPress == nil ? .staticText : .button
    }

    override func accessibilityLabel() -> String? {
        onPress == nil ? spokenName : "\(spokenName), collapsed note, press to expand"
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress = onPress else { return false }
        onPress()
        return true
    }
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

@MainActor
protocol NoteDragZoneDelegate: AnyObject {
    func dragZoneDidDoubleClick()
    /// Called once the drag loop finishes, so the note can settle against
    /// nearby edges. `suppressSnapping` is true when the user held Option.
    func dragZoneDidEndDrag(suppressSnapping: Bool)
}

/// Invisible region at the top of a note. A normal click+drag moves the
/// window; a double-click toggles the note's collapsed state. Subviews
/// (like buttons) still receive their own clicks via standard hit testing.
final class NoteDragZone: NSView {
    weak var delegate: NoteDragZoneDelegate?

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Note top bar" }
    override func accessibilityHelp() -> String? {
        "Drag to move the note. Double-click to collapse or expand it."
    }

    /// The double-click, for a person who cannot make one.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let name = isCollapsed ? "Expand note" : "Collapse note"
        return [NSAccessibilityCustomAction(name: name) { [weak self] in
            self?.delegate?.dragZoneDidDoubleClick()
            return true
        }]
    }

    /// Names the VoiceOver action. A single click never toggles: it is how a
    /// collapsed note gets picked up and moved.
    var isCollapsed = false {
        didSet { toolTip = isCollapsed ? "Double-click to expand" : nil }
    }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            delegate?.dragZoneDidDoubleClick()
            return
        }
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

        guard moved else { return }
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
///
/// VoiceOver cannot drag a corner, so it gets the same resizing as four actions.
final class ResizeGripView: NSView {
    override var isFlipped: Bool { true }

    /// How far one action changes the note, in points.
    static let accessibilityStep: CGFloat = 40

    /// Asked to change the note's size by this much: width grows rightward and
    /// height grows downward, as the corner drag does.
    var onResize: ((_ dx: CGFloat, _ dy: CGFloat) -> Void)?

    /// False while the note is collapsed: there is no corner to resize.
    var isResizable = true

    override func isAccessibilityElement() -> Bool { isResizable }
    override func accessibilityRole() -> NSAccessibility.Role? { .growArea }
    override func accessibilityLabel() -> String? { "Resize note" }
    override func accessibilityHelp() -> String? { "Make the note wider, narrower, taller or shorter." }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let step = ResizeGripView.accessibilityStep
        let choices: [(String, CGFloat, CGFloat)] = [
            ("Make wider", step, 0), ("Make narrower", -step, 0),
            ("Make taller", 0, step), ("Make shorter", 0, -step)
        ]
        return choices.map { name, dx, dy in
            NSAccessibilityCustomAction(name: name) { [weak self] in
                self?.onResize?(dx, dy)
                return true
            }
        }
    }

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
