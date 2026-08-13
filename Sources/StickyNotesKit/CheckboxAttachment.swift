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
        if handleLinkClick(at: viewPoint, event: event) { return }
        super.mouseDown(with: event)
    }

    /// Open a link on ⌘-click, or on a plain click when this editor doesn't
    /// have focus. Clicking a link in the note you're editing places the caret
    /// instead — the same split Obsidian uses, so a link never fights you for
    /// a click while you're writing.
    private func handleLinkClick(at point: NSPoint, event: NSEvent) -> Bool {
        let commandHeld = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        let focused = window?.firstResponder === self
        guard commandHeld || !focused else { return false }

        guard let storage = textStorage, let lm = layoutManager, let tc = textContainer else { return false }
        let container = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = lm.glyphIndex(for: container, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < lm.numberOfGlyphs else { return false }
        let index = lm.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return false }

        guard let value = storage.attribute(.link, at: index, effectiveRange: nil) else { return false }
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        guard let url = url else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    /// Pasting a URL over selected text turns the selection into a markdown
    /// link rather than replacing it — the usual reason to paste a URL onto
    /// words is to link them.
    override func paste(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length > 0,
              let pasted = NSPasteboard.general.string(forType: .string)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              isLinkLike(pasted) else {
            super.paste(sender)
            return
        }

        let selected = (string as NSString).substring(with: selection)
        // Don't nest a link inside a link.
        guard !selected.contains("]("), !isLinkLike(selected) else {
            super.paste(sender)
            return
        }

        let replacement = "[\(selected)](\(pasted))"
        guard shouldChangeText(in: selection, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: selection, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: selection.location + (replacement as NSString).length, length: 0))
    }

    private func isLinkLike(_ candidate: String) -> Bool {
        guard !candidate.contains(" "), !candidate.contains("\n") else { return false }
        guard let url = URL(string: candidate), let scheme = url.scheme else { return false }
        return !scheme.isEmpty && url.host != nil
    }

    // MARK: - Markdown shortcuts

    /// ⌘B / ⌘I / ⌘E wrap the selection, ⌘↩ turns the current line into a task.
    /// Handled here rather than through the main menu so they only apply while
    /// a note editor has focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command else { return super.performKeyEquivalent(with: event) }

        if event.keyCode == 36 || event.keyCode == 76 {     // return, enter
            return apply { MarkdownEditing.toggleCheckbox($0, selection: $1) }
        }

        let marker: String?
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": marker = "**"
        case "i": marker = "*"
        case "e": marker = "`"
        default:  marker = nil
        }
        guard let marker = marker else { return super.performKeyEquivalent(with: event) }
        return apply { MarkdownEditing.toggleWrap($0, selection: $1, marker: marker) }
    }

    /// Indent and outdent list items. Only claims Tab on a list line so it
    /// still moves focus everywhere else.
    func indentSelection(outdent: Bool) -> Bool {
        guard MarkdownEditing.isListLine(string, selection: selectedRange()) else { return false }
        return apply { text, selection in
            outdent
                ? MarkdownEditing.outdent(text, selection: selection)
                : MarkdownEditing.indent(text, selection: selection)
        }
    }

    /// Run a transform through the undo-aware editing path so ⌘Z still works.
    /// `didChangeText()` drives the delegate's usual restyle-and-save path, so
    /// there's nothing extra to notify.
    private func apply(_ transform: (String, NSRange) -> MarkdownEditing.Edit) -> Bool {
        let edit = transform(string, selectedRange())
        guard edit.text != string else {
            setSelectedRange(edit.selection)
            return true
        }
        let whole = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: whole, replacementString: edit.text) else { return false }
        textStorage?.replaceCharacters(in: whole, with: edit.text)
        didChangeText()
        setSelectedRange(edit.selection)
        return true
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
