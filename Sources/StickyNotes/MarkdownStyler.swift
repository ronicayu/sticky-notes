import AppKit

extension NSAttributedString.Key {
    /// Marks a range as a markdown marker. Value is `NSValue(range:)` of the
    /// element's full scope (e.g. for `**bold**`, the value is the range covering
    /// both `**`s and the inner text). When the cursor / selection is inside the
    /// scope the markers stay visible; otherwise they get the `mdHidden` flag.
    static let mdMarkerScope = NSAttributedString.Key("mdMarkerScope")

    /// Set on glyph ranges that the layout manager should collapse to zero width.
    static let mdHidden = NSAttributedString.Key("mdHidden")
}

/// WYSIWYG markdown styling for an `NSTextView`. Applies live styling, tracks
/// marker ranges so the layout manager can hide them when the cursor is not
/// editing that element, à la Obsidian / TickTick live-preview.
enum MarkdownStyler {
    static let baseFontSize: CGFloat = 13

    /// Exported so other views can match the body text tone (cursor, typing attrs).
    static let bodyTextColor = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)

    private static let markerColor = NSColor.black.withAlphaComponent(0.28)
    private static let bodyColor   = bodyTextColor
    private static let codeColor   = NSColor(srgbRed: 0.42, green: 0.18, blue: 0.32, alpha: 1.0)

    /// Re-style the entire text storage. Caller should subsequently call
    /// `updateMarkerVisibility(in:selection:)` to apply the hidden flag.
    static func apply(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }

        let nsString = storage.string as NSString
        storage.beginEditing()
        defer { storage.endEditing() }

        // Reset baseline (clears prior markers/attributes).
        storage.setAttributes([
            .font: baseFont(),
            .foregroundColor: bodyColor
        ], range: full)

        // Block-level (per line).
        nsString.enumerateSubstrings(in: full, options: .byLines) { _, lineRange, _, _ in
            let line = nsString.substring(with: lineRange)
            applyBlock(line: line, range: lineRange, in: storage)
        }

        // Checkbox lines: tag the "- [ ] " / "- [x] " prefix so the editor
        // can hide it and overlay-draw a real checkbox.
        applyCheckboxes(in: storage, full: full)

        // Inline runs. Order matters: bold first so italic regex skips `**`.
        applyInline(
            pattern: #"\*\*([^*\n]+?)\*\*"#,
            markerLen: 2,
            in: storage,
            full: full,
            innerAttrs: [.font: NSFont.systemFont(ofSize: baseFontSize, weight: .bold)]
        )
        applyInline(
            pattern: #"(?<!\*)\*([^*\n]+?)\*(?!\*)"#,
            markerLen: 1,
            in: storage,
            full: full,
            innerAttrs: [.font: italicFont(size: baseFontSize)]
        )
        applyInline(
            pattern: #"~~([^~\n]+?)~~"#,
            markerLen: 2,
            in: storage,
            full: full,
            innerAttrs: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: bodyColor
            ]
        )
        applyInline(
            pattern: #"`([^`\n]+)`"#,
            markerLen: 1,
            in: storage,
            full: full,
            innerAttrs: [
                .font: NSFont.monospacedSystemFont(ofSize: baseFontSize - 1, weight: .regular),
                .foregroundColor: codeColor
            ]
        )
    }

    /// Sets/removes `mdHidden` on every tagged marker range based on whether the
    /// caret/selection currently sits inside the marker's scope.
    static func updateMarkerVisibility(in storage: NSTextStorage, selection: NSRange) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }

        storage.beginEditing()
        defer { storage.endEditing() }

        storage.removeAttribute(.mdHidden, range: full)

        storage.enumerateAttribute(.mdMarkerScope, in: full, options: []) { value, markerRange, _ in
            guard let scopeValue = value as? NSValue else { return }
            let scope = scopeValue.rangeValue
            if !selectionTouches(scope: scope, selection: selection) {
                storage.addAttribute(.mdHidden, value: true, range: markerRange)
            }
        }
    }

    private static func selectionTouches(scope: NSRange, selection: NSRange) -> Bool {
        let selStart = selection.location
        let selEnd = selection.location + selection.length
        let scopeEnd = scope.location + scope.length
        return selStart <= scopeEnd && selEnd >= scope.location
    }

    // MARK: - Checkboxes

    private static func applyCheckboxes(in storage: NSTextStorage, full: NSRange) {
        guard let regex = try? NSRegularExpression(
            pattern: #"^[ \t]*-\s\[([ xX])\]\s"#,
            options: [.anchorsMatchLines]
        ) else { return }

        let plain = storage.string
        let nsstring = plain as NSString
        let matches = regex.matches(in: plain, range: full)

        // The bracket char ("x"/"X" or " ") has different glyph widths in
        // SF, so checked vs unchecked markers normally consume different
        // horizontal space — making body text after them visually
        // misaligned. Compensate with negative kerning on the wider char.
        let attrFont = baseFont()
        let xWidth = ("x" as NSString).size(withAttributes: [.font: attrFont]).width
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: attrFont]).width
        let widthDelta = xWidth - spaceWidth

        for match in matches {
            let bracketRange = match.range(at: 1)
            let bracket = nsstring.substring(with: bracketRange)
            let isChecked = bracket.lowercased() == "x"

            storage.addAttribute(.checkboxRange, value: NSValue(range: match.range), range: match.range)
            storage.addAttribute(.checkboxChecked, value: isChecked, range: match.range)
            // Make the markdown source itself invisible (still counted in
            // layout for natural width). The TodoTextView paints a real
            // checkbox over the same span.
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: match.range)

            // Compress the trailing kern of "x" so its effective width
            // matches a literal space — keeps body text aligned across
            // checked/unchecked rows.
            if isChecked && widthDelta > 0 {
                storage.addAttribute(.kern, value: -widthDelta, range: bracketRange)
            }
        }
    }

    // MARK: - Block

    private static func applyBlock(line: String, range: NSRange, in storage: NSTextStorage) {
        if line.hasPrefix("# ") {
            applyHeading(markerLen: 2, fontSize: baseFontSize + 7, weight: .bold, lineRange: range, storage: storage)
        } else if line.hasPrefix("## ") {
            applyHeading(markerLen: 3, fontSize: baseFontSize + 4, weight: .semibold, lineRange: range, storage: storage)
        } else if line.hasPrefix("### ") {
            applyHeading(markerLen: 4, fontSize: baseFontSize + 1, weight: .semibold, lineRange: range, storage: storage)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            // Checkbox prefix is handled separately so it can render as a real
            // checkbox; let applyCheckboxes own that range.
            let isCheckboxLine = line.range(
                of: #"^[ \t]*-\s\[([ xX])\]\s"#,
                options: .regularExpression
            ) != nil
            if !isCheckboxLine {
                applyListItem(lineRange: range, storage: storage)
            }
        } else if let prefixLen = orderedListMarkerLength(line) {
            applyOrderedItem(lineRange: range, markerLength: prefixLen, storage: storage)
        }
    }

    private static func applyHeading(markerLen: Int, fontSize: CGFloat, weight: NSFont.Weight, lineRange: NSRange, storage: NSTextStorage) {
        let markerRange = NSRange(location: lineRange.location, length: min(markerLen, lineRange.length))
        storage.addAttributes([
            .foregroundColor: markerColor,
            .font: baseFont(),
            .mdMarkerScope: NSValue(range: lineRange)
        ], range: markerRange)

        let textStart = lineRange.location + markerLen
        let textLen = max(0, lineRange.length - markerLen)
        guard textLen > 0 else { return }
        let textRange = NSRange(location: textStart, length: textLen)
        storage.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize, weight: weight), range: textRange)
    }

    private static func applyListItem(lineRange: NSRange, storage: NSTextStorage) {
        // Marker is "- " / "* " — keep the dash/star visible (it acts as the bullet),
        // hide only the trailing space after the cursor leaves the line.
        let markerRange = NSRange(location: lineRange.location, length: 2)
        storage.addAttribute(.foregroundColor, value: markerColor, range: markerRange)

        let para = NSMutableParagraphStyle()
        para.headIndent = 14
        para.firstLineHeadIndent = 0
        storage.addAttribute(.paragraphStyle, value: para, range: lineRange)
    }

    /// Returns the number of characters in an ordered-list marker like
    /// "1. " / "23. " at the start of `line`, or nil if there is none.
    private static func orderedListMarkerLength(_ line: String) -> Int? {
        guard let match = line.range(
            of: #"^\d+\.\s"#,
            options: .regularExpression
        ) else { return nil }
        return line.distance(from: match.lowerBound, to: match.upperBound)
    }

    private static func applyOrderedItem(lineRange: NSRange, markerLength: Int, storage: NSTextStorage) {
        let markerRange = NSRange(location: lineRange.location, length: markerLength)
        storage.addAttribute(.foregroundColor, value: markerColor, range: markerRange)

        let para = NSMutableParagraphStyle()
        para.headIndent = CGFloat(markerLength) * 8 // approximate; aligns wrap to text
        para.firstLineHeadIndent = 0
        storage.addAttribute(.paragraphStyle, value: para, range: lineRange)
    }

    // MARK: - Inline

    private static func applyInline(
        pattern: String,
        markerLen: Int,
        in storage: NSTextStorage,
        full: NSRange,
        innerAttrs: [NSAttributedString.Key: Any]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let matches = regex.matches(in: storage.string, range: full)
        for match in matches {
            let r = match.range
            guard r.length >= markerLen * 2 else { continue }

            let scopeValue = NSValue(range: r)
            let leadMarker = NSRange(location: r.location, length: markerLen)
            let trailMarker = NSRange(location: r.location + r.length - markerLen, length: markerLen)
            storage.addAttributes([
                .foregroundColor: markerColor,
                .mdMarkerScope: scopeValue
            ], range: leadMarker)
            storage.addAttributes([
                .foregroundColor: markerColor,
                .mdMarkerScope: scopeValue
            ], range: trailMarker)

            let innerStart = r.location + markerLen
            let innerLen = r.length - markerLen * 2
            guard innerLen > 0 else { continue }
            let innerRange = NSRange(location: innerStart, length: innerLen)
            storage.addAttributes(innerAttrs, range: innerRange)
        }
    }

    // MARK: - Fonts

    private static func baseFont() -> NSFont {
        NSFont.systemFont(ofSize: baseFontSize)
    }

    private static func italicFont(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        if let descriptor = base.fontDescriptor.withSymbolicTraits(.italic) as NSFontDescriptor?,
           let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return base
    }
}
