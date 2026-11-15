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

@MainActor
protocol TodoTextViewDelegate: AnyObject {
    func textViewDidToggleCheckbox(at charIndex: Int)
}

/// `NSTextView` subclass that paints a real checkbox over each markdown
/// `- [ ]` line and toggles the source character on click. The text storage
/// itself is never modified — the checkbox is purely a render layer.
final class TodoTextView: NSTextView {
    weak var todoDelegate: TodoTextViewDelegate?
    private var checkboxElements: [NSRange: CheckboxAccessibilityElement] = [:]

    nonisolated static let leadingPaddingForCheckbox: CGFloat = 18

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
            (Appearance.isDark ? NSColor.white.withAlphaComponent(0.6)
                               : NSColor.black.withAlphaComponent(0.55)).setStroke()
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

        // ⌘-drag anywhere moves the note. The 22pt title strip is a precise
        // target for the most common physical action; this is the easy path.
        // (A ⌘-click on a link is handled above and never reaches here.)
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            window?.performDrag(with: event)
            onCommandDragEnded?()
            return
        }
        super.mouseDown(with: event)
    }

    /// Called after a ⌘-drag finishes, so the controller can snap the note.
    var onCommandDragEnded: (() -> Void)?

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

        // Wiki links need the note store to resolve, which the text view has
        // no business knowing about — hand them to whoever is listening.
        if let target = WikiLink.target(of: url) {
            NotificationCenter.default.post(
                name: TodoTextView.didClickWikiLink,
                object: self,
                userInfo: ["target": target]
            )
            return true
        }
        // An attachment reference is relative to the note's folder, which only
        // the controller can resolve — it owns the store.
        if url.scheme == nil {
            guard let resolved = attachmentResolver?(url.relativeString) else { return false }
            NSWorkspace.shared.open(resolved)
            return true
        }
        NSWorkspace.shared.open(url)
        return true
    }

    /// Posted when a `[[wiki link]]` is clicked. `userInfo["target"]` is the
    /// note name it points at.
    static let didClickWikiLink = Notification.Name("TodoTextView.didClickWikiLink")

    /// Turn pasteboard contents into an attachment and return the markdown to
    /// insert, or nil to let the paste proceed normally. Set by the controller,
    /// which owns the store the file has to be written next to.
    var attachmentHandler: ((NSPasteboard) -> String?)?

    /// Turns a note-relative attachment path into a file URL. Set by the
    /// controller for the same reason as `attachmentHandler`.
    var attachmentResolver: ((String) -> URL?)?

    /// Paste handling, in order: a file or image becomes an attachment; a URL
    /// pasted over selected text wraps the selection in a markdown link, since
    /// that is the usual reason to paste a URL onto words; anything else
    /// pastes normally.
    override func paste(_ sender: Any?) {
        if let markdown = attachmentHandler?(NSPasteboard.general) {
            insertAsParagraph(markdown)
            return
        }
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

    /// Drop the reference on its own line — an image sitting mid-sentence
    /// reads as a mistake.
    private func insertAsParagraph(_ markdown: String) {
        let selection = selectedRange()
        let ns = string as NSString
        var prefix = ""
        if selection.location > 0, ns.character(at: selection.location - 1) != 0x0A {
            prefix = "\n"
        }
        let text = prefix + markdown + "\n"
        guard shouldChangeText(in: selection, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: selection, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: selection.location + (text as NSString).length, length: 0))
    }

    private func isLinkLike(_ candidate: String) -> Bool {
        guard !candidate.contains(" "), !candidate.contains("\n") else { return false }
        guard let url = URL(string: candidate), let scheme = url.scheme else { return false }
        return !scheme.isEmpty && url.host != nil
    }

    // MARK: - Markdown shortcuts

    /// ⌘B / ⌘I / ⌘E wrap the selection, ⌘↩ turns the current line into a task.
    /// Handled here rather than through the main menu so they only apply while
    /// this editor has focus: the key is offered to every view in the window, so
    /// the title field and the find bar must not have it act on the body.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }

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

    // MARK: - Accessibility

    /// A checkbox is painted over the text, so VoiceOver would only read the
    /// "- [ ]" under it. Each one is also offered as a check box that reports
    /// whether it is checked and can be pressed.
    override func accessibilityChildren() -> [Any]? {
        guard let storage = textStorage else { return super.accessibilityChildren() }
        var markers: [NSRange] = []
        storage.enumerateAttribute(.checkboxRange, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
            if value is NSValue { markers.append(range) }
        }
        // An element is kept for as long as its box stays where it is, so
        // VoiceOver's cursor does not jump when something else changes.
        var kept: [NSRange: CheckboxAccessibilityElement] = [:]
        let boxes = markers.map { marker -> CheckboxAccessibilityElement in
            let element = checkboxElements[marker] ?? CheckboxAccessibilityElement(textView: self, markerRange: marker)
            kept[marker] = element
            return element
        }
        checkboxElements = kept
        guard !boxes.isEmpty else { return super.accessibilityChildren() }
        return (super.accessibilityChildren() ?? []) + boxes
    }

    /// True when a painted checkbox marker still covers exactly `marker`: the
    /// text may have changed since an element was made.
    func hasCheckbox(at marker: NSRange) -> Bool {
        guard let storage = textStorage, marker.length > 0, NSMaxRange(marker) <= storage.length else { return false }
        var effective = NSRange()
        guard storage.attribute(
            .checkboxRange, at: marker.location, longestEffectiveRange: &effective,
            in: NSRange(location: 0, length: storage.length)
        ) is NSValue else {
            return false
        }
        return NSEqualRanges(effective, marker)
    }

    /// The box whose marker starts at `location`, as drawn now.
    func isCheckboxChecked(at location: Int) -> Bool {
        guard let storage = textStorage, location < storage.length else { return false }
        return (storage.attribute(.checkboxChecked, at: location, effectiveRange: nil) as? Bool) ?? false
    }

    /// What the line says after its marker, without the Markdown around words.
    func checkboxTitle(afterMarker marker: NSRange) -> String {
        let text = string as NSString
        guard marker.upperBound <= text.length else { return "" }
        let line = text.lineRange(for: NSRange(location: marker.location, length: 0))
        guard line.upperBound >= marker.upperBound else { return "" }
        let rest = text.substring(with: NSRange(location: marker.upperBound, length: line.upperBound - marker.upperBound))
        return ["**", "~~", "`"]
            .reduce(rest) { $0.replacingOccurrences(of: $1, with: "") }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where the box is on screen.
    func checkboxScreenFrame(of marker: NSRange) -> NSRect {
        guard hasCheckbox(at: marker), let lm = layoutManager, let tc = textContainer, let window = window else { return .zero }
        let inView = boundingRectInView(for: marker, lm: lm, tc: tc)
        return window.convertToScreen(convert(inView, to: nil))
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

/// What a checkbox element reads and does, on the main actor. Held by the
/// element, whose accessibility methods are not main-actor isolated in the SDK.
/// Only the main thread ever touches `textView`: VoiceOver asks on the main
/// thread, and every use goes through `MainActor.assumeIsolated`.
private final class CheckboxTarget: @unchecked Sendable {
    private weak var textView: TodoTextView?
    private let markerRange: NSRange

    @MainActor
    init(textView: TodoTextView, markerRange: NSRange) {
        self.textView = textView
        self.markerRange = markerRange
    }

    @MainActor var parent: TodoTextView? { textView }

    /// The text view, when the box this element stands for is still in it.
    @MainActor private var live: TodoTextView? {
        guard let textView = textView, textView.hasCheckbox(at: markerRange) else { return nil }
        return textView
    }

    @MainActor var frame: NSRect { textView?.checkboxScreenFrame(of: markerRange) ?? .zero }

    @MainActor var title: String? {
        guard let textView = live else { return nil }
        let title = textView.checkboxTitle(afterMarker: markerRange)
        return title.isEmpty ? "Task" : title
    }

    /// 1 when checked, 0 when not, nil when the box has moved.
    @MainActor var state: Int? {
        guard let textView = live else { return nil }
        return textView.isCheckboxChecked(at: markerRange.location) ? 1 : 0
    }

    @MainActor func toggle() -> Bool {
        guard let textView = live, let delegate = textView.todoDelegate else { return false }
        delegate.textViewDidToggleCheckbox(at: markerRange.location)
        return true
    }
}

/// One painted checkbox of a note, as VoiceOver sees it. It holds no state of
/// its own: the text view is asked each time, so it is right after an edit.
final class CheckboxAccessibilityElement: NSAccessibilityElement {
    private let target: CheckboxTarget

    @MainActor
    init(textView: TodoTextView, markerRange: NSRange) {
        target = CheckboxTarget(textView: textView, markerRange: markerRange)
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }

    override func accessibilityParent() -> Any? {
        let target = target
        return MainActor.assumeIsolated { target.parent }
    }

    override func accessibilityFrame() -> NSRect {
        let target = target
        return MainActor.assumeIsolated { target.frame }
    }

    override func accessibilityLabel() -> String? {
        let target = target
        return MainActor.assumeIsolated { target.title }
    }

    override func accessibilityValue() -> Any? {
        let target = target
        return MainActor.assumeIsolated { target.state }.map { NSNumber(value: $0) }
    }

    override func accessibilityPerformPress() -> Bool {
        let target = target
        guard MainActor.assumeIsolated({ target.toggle() }) else { return false }
        NSAccessibility.post(element: self, notification: .valueChanged)
        return true
    }
}
