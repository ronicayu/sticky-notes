import AppKit
import Markdown

extension NSAttributedString.Key {
    /// Marks a range as a markdown marker. Value is `NSValue(range:)` of the
    /// element's full scope (e.g. for `**bold**`, the value is the range covering
    /// both `**`s and the inner text). When the cursor / selection is inside the
    /// scope the markers stay visible; otherwise they get the `mdHidden` flag.
    static let mdMarkerScope = NSAttributedString.Key("mdMarkerScope")

    /// Set on glyph ranges that the layout manager should collapse to zero width.
    static let mdHidden = NSAttributedString.Key("mdHidden")
}

/// Colors and metrics shared by the styler and the views that host it.
extension MarkdownStyler {
    static let linkColor = NSColor(srgbRed: 0.13, green: 0.38, blue: 0.78, alpha: 1.0)
}

/// WYSIWYG markdown styling for an `NSTextView`. Applies live styling, tracks
/// marker ranges so the layout manager can hide them when the cursor is not
/// editing that element, à la Obsidian / TickTick live-preview.
///
/// Parsing is done by Apple's `swift-markdown` (CommonMark + GFM AST). The
/// regex-based approach this replaced mis-handled nested emphasis (`***x***`),
/// escaped markers (`\*x\*`), and markers inside code spans.
enum MarkdownStyler {
    static let baseFontSize: CGFloat = 13

    /// Exported so other views can match the body text tone (cursor, typing attrs).
    static let bodyTextColor = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)

    fileprivate static let markerColor = NSColor.black.withAlphaComponent(0.28)
    fileprivate static let bodyColor   = bodyTextColor
    fileprivate static let codeColor   = NSColor(srgbRed: 0.42, green: 0.18, blue: 0.32, alpha: 1.0)

    /// Re-style the entire text storage. Caller should subsequently call
    /// `updateMarkerVisibility(in:selection:)` to apply the hidden flag.
    static func apply(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        apply(to: storage)
    }

    /// Storage-level entry point. Split out from `apply(to:)` so styling can be
    /// exercised without a view hierarchy.
    static func apply(to storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }

        storage.beginEditing()
        defer { storage.endEditing() }

        // Reset baseline (clears prior markers/attributes).
        storage.setAttributes([
            .font: baseFont(),
            .foregroundColor: bodyColor
        ], range: full)

        let source = storage.string
        let document = Document(parsing: source)
        let table = LineOffsetTable(source)
        var visitor = StylingVisitor(storage: storage, source: source as NSString, table: table)
        visitor.visit(document)

        // Checkbox lines: tag the "- [ ] " / "- [x] " prefix so the editor can
        // hide the source markdown and overlay-draw a real checkbox. Kept as a
        // regex pass — it has app-specific kerning + foreground-clear semantics
        // that don't belong in the AST walk.
        applyCheckboxes(in: storage, full: full)

        // Bare URLs aren't links to CommonMark without the autolink extension,
        // but people type them constantly. Detect them separately, skipping
        // anything the AST already turned into a link.
        applyBareURLs(in: storage, full: full)
    }

    private static func applyBareURLs(in storage: NSTextStorage, full: NSRange) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return
        }
        for match in detector.matches(in: storage.string, range: full) {
            guard let url = match.url else { continue }
            if storage.attribute(.link, at: match.range.location, effectiveRange: nil) != nil { continue }
            // Inside a code span the text is deliberately literal.
            if let font = storage.attribute(.font, at: match.range.location, effectiveRange: nil) as? NSFont,
               font.fontDescriptor.symbolicTraits.contains(.monoSpace) { continue }
            storage.addAttributes([
                .link: url,
                .foregroundColor: linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: match.range)
        }
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

    // MARK: - Fonts

    fileprivate static func baseFont() -> NSFont {
        NSFont.systemFont(ofSize: baseFontSize)
    }

    fileprivate static func italicFont(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        if let descriptor = base.fontDescriptor.withSymbolicTraits(.italic) as NSFontDescriptor?,
           let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return base
    }
}

// MARK: - Source range mapping

/// Converts swift-markdown `SourceRange` (1-based line/column where column is
/// a UTF-8 byte offset within the line) into the `NSRange` (UTF-16 offsets)
/// that NSAttributedString uses.
private struct LineOffsetTable {
    private let source: String
    /// UTF-8 byte offset of the first character of each line. Index 0 unused;
    /// index N corresponds to line N (1-based, matching swift-markdown).
    private let utf8LineStarts: [Int]
    /// UTF-16 unit offset of the first character of each line, parallel to
    /// `utf8LineStarts`.
    private let utf16LineStarts: [Int]

    init(_ source: String) {
        self.source = source
        var u8: [Int] = [0, 0]
        var u16: [Int] = [0, 0]
        var u8Cursor = 0
        var u16Cursor = 0
        for scalar in source.unicodeScalars {
            let isNewline = scalar == "\n"
            u8Cursor += UTF8.width(scalar)
            u16Cursor += UTF16.width(scalar)
            if isNewline {
                u8.append(u8Cursor)
                u16.append(u16Cursor)
            }
        }
        self.utf8LineStarts = u8
        self.utf16LineStarts = u16
    }

    func nsRange(_ range: SourceRange) -> NSRange? {
        guard let start = utf16Offset(line: range.lowerBound.line, column: range.lowerBound.column),
              let end   = utf16Offset(line: range.upperBound.line, column: range.upperBound.column) else {
            return nil
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    private func utf16Offset(line: Int, column: Int) -> Int? {
        guard line >= 1 && line < utf16LineStarts.count else { return nil }
        if column <= 1 { return utf16LineStarts[line] }

        let lineU8Start = utf8LineStarts[line]
        let targetU8 = lineU8Start + (column - 1)

        // Walk unicode scalars within this line, summing UTF-8 and UTF-16
        // widths in lockstep, until we've consumed `column - 1` UTF-8 bytes.
        let utf8 = source.utf8
        guard let lineStartUtf8 = utf8.index(utf8.startIndex, offsetBy: lineU8Start, limitedBy: utf8.endIndex),
              let lineStartScalar = lineStartUtf8.samePosition(in: source.unicodeScalars) else {
            return nil
        }

        var u8 = lineU8Start
        var u16 = utf16LineStarts[line]
        var i = lineStartScalar
        while u8 < targetU8 && i < source.unicodeScalars.endIndex {
            let scalar = source.unicodeScalars[i]
            u8 += UTF8.width(scalar)
            u16 += UTF16.width(scalar)
            source.unicodeScalars.formIndex(after: &i)
        }
        return u16
    }
}

// MARK: - AST walker

/// Walks a swift-markdown `Document` and applies live-preview styling to the
/// underlying `NSTextStorage`. Block-level nodes (Heading, ListItem) are styled
/// from the source line because their AST `range` includes child paragraphs
/// that we don't want to repaint. Inline nodes (Strong, Emphasis, Strikethrough,
/// InlineCode) get their full marker-and-content range from the AST.
private struct StylingVisitor: MarkupWalker {
    let storage: NSTextStorage
    let source: NSString
    let table: LineOffsetTable

    // MARK: Block

    mutating func visitHeading(_ heading: Heading) {
        guard let range = heading.range, let nsr = table.nsRange(range) else {
            descendInto(heading)
            return
        }
        let lineRange = trimmedLineRange(at: nsr.location)
        guard lineRange.length > 0 else {
            descendInto(heading)
            return
        }
        let line = source.substring(with: lineRange)
        // Only style ATX headings (# / ## / ###). Setext headings (=== / ---)
        // aren't part of the app's UX surface; leave them alone.
        let markerLen: Int
        let fontSize: CGFloat
        let weight: NSFont.Weight
        if line.hasPrefix("# ") {
            markerLen = 2; fontSize = MarkdownStyler.baseFontSize + 7; weight = .bold
        } else if line.hasPrefix("## ") {
            markerLen = 3; fontSize = MarkdownStyler.baseFontSize + 4; weight = .semibold
        } else if line.hasPrefix("### ") {
            markerLen = 4; fontSize = MarkdownStyler.baseFontSize + 1; weight = .semibold
        } else {
            descendInto(heading)
            return
        }

        let markerRange = NSRange(location: lineRange.location, length: min(markerLen, lineRange.length))
        storage.addAttributes([
            .foregroundColor: MarkdownStyler.markerColor,
            .font: MarkdownStyler.baseFont(),
            .mdMarkerScope: NSValue(range: lineRange)
        ], range: markerRange)

        let textStart = lineRange.location + markerLen
        let textLen = max(0, lineRange.length - markerLen)
        if textLen > 0 {
            storage.addAttribute(
                .font,
                value: NSFont.systemFont(ofSize: fontSize, weight: weight),
                range: NSRange(location: textStart, length: textLen)
            )
        }

        descendInto(heading)
    }

    mutating func visitListItem(_ item: ListItem) {
        // Checkbox items are owned by `applyCheckboxes` — skip the marker
        // styling but still descend so any nested emphasis / code gets styled.
        if item.checkbox != nil {
            descendInto(item)
            return
        }
        guard let range = item.range, let nsr = table.nsRange(range) else {
            descendInto(item)
            return
        }
        let lineRange = trimmedLineRange(at: nsr.location)
        guard lineRange.length > 0 else {
            descendInto(item)
            return
        }
        let line = source.substring(with: lineRange)
        let leadingWhitespace = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        let body = line.dropFirst(leadingWhitespace)

        if body.hasPrefix("- ") || body.hasPrefix("* ") {
            applyListMarker(
                lineRange: lineRange,
                markerStart: lineRange.location + leadingWhitespace,
                markerLength: 2,
                headIndent: 14
            )
        } else if let markerLen = orderedListMarkerLength(body) {
            applyListMarker(
                lineRange: lineRange,
                markerStart: lineRange.location + leadingWhitespace,
                markerLength: markerLen,
                headIndent: CGFloat(markerLen) * 8
            )
        }
        descendInto(item)
    }

    private func applyListMarker(lineRange: NSRange, markerStart: Int, markerLength: Int, headIndent: CGFloat) {
        let markerRange = NSRange(location: markerStart, length: markerLength)
        storage.addAttribute(.foregroundColor, value: MarkdownStyler.markerColor, range: markerRange)

        let para = NSMutableParagraphStyle()
        para.headIndent = headIndent
        para.firstLineHeadIndent = 0
        storage.addAttribute(.paragraphStyle, value: para, range: lineRange)
    }

    private func orderedListMarkerLength(_ text: Substring) -> Int? {
        var digits = 0
        for ch in text {
            if ch.isNumber { digits += 1 } else { break }
        }
        guard digits > 0 else { return nil }
        let after = text.index(text.startIndex, offsetBy: digits)
        guard after < text.endIndex, text[after] == "." else { return nil }
        let space = text.index(after: after)
        guard space < text.endIndex, text[space] == " " else { return nil }
        return digits + 2
    }

    // MARK: Inline

    mutating func visitStrong(_ strong: Strong) {
        applyInlineMarker(node: strong, markerLen: 2, fontTraits: .bold)
        descendInto(strong)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        applyInlineMarker(node: emphasis, markerLen: 1, fontTraits: .italic)
        descendInto(emphasis)
    }

    mutating func visitStrikethrough(_ strike: Strikethrough) {
        applyInlineMarker(node: strike, markerLen: 2, innerAttrs: [
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: MarkdownStyler.bodyTextColor
        ])
        descendInto(strike)
    }

    /// `[text](url)` — the visible text keeps link styling, while the brackets
    /// and the destination hide together when the caret is elsewhere, so a
    /// note reads as prose until you go to edit the link.
    mutating func visitLink(_ link: Markdown.Link) {
        guard let range = link.range, let nsr = table.nsRange(range) else {
            descendInto(link)
            return
        }
        let text = source.substring(with: nsr)
        guard text.hasPrefix("["), let closeBracket = text.range(of: "](") else {
            descendInto(link)
            return
        }

        let leadLength = 1
        let trailStart = text.distance(from: text.startIndex, to: closeBracket.lowerBound)
        let trailLength = (text as NSString).length - trailStart
        guard trailLength > 0, nsr.length > leadLength + trailLength else {
            descendInto(link)
            return
        }

        let scope = NSValue(range: nsr)
        markMarker(NSRange(location: nsr.location, length: leadLength), scope: scope)
        markMarker(NSRange(location: nsr.location + trailStart, length: trailLength), scope: scope)

        let inner = NSRange(location: nsr.location + leadLength, length: trailStart - leadLength)
        if inner.length > 0 {
            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: MarkdownStyler.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
            if let destination = link.destination, let url = URL(string: destination) {
                attrs[.link] = url
            }
            storage.addAttributes(attrs, range: inner)
        }
        descendInto(link)
    }

    private func markMarker(_ range: NSRange, scope: NSValue) {
        storage.addAttributes([
            .foregroundColor: MarkdownStyler.markerColor,
            .mdMarkerScope: scope
        ], range: range)
    }

    mutating func visitInlineCode(_ code: InlineCode) {
        // Backtick spans can be opened with ``one``, ``two``, etc. Recover
        // marker length from the source rather than assuming 1.
        guard let range = code.range, let nsr = table.nsRange(range) else { return }
        let text = source.substring(with: nsr)
        let backticks = text.prefix(while: { $0 == "`" }).count
        guard backticks > 0, nsr.length >= backticks * 2 else { return }
        applyInlineMarkerRange(
            nsr,
            markerLen: backticks,
            innerAttrs: [
                .font: NSFont.monospacedSystemFont(ofSize: MarkdownStyler.baseFontSize - 1, weight: .regular),
                .foregroundColor: MarkdownStyler.codeColor
            ]
        )
    }

    private func applyInlineMarker(
        node: Markup,
        markerLen: Int,
        innerAttrs: [NSAttributedString.Key: Any] = [:],
        fontTraits: NSFontDescriptor.SymbolicTraits = []
    ) {
        guard let range = node.range, let nsr = table.nsRange(range) else { return }
        guard nsr.length >= markerLen * 2 else { return }
        applyInlineMarkerRange(nsr, markerLen: markerLen, innerAttrs: innerAttrs, fontTraits: fontTraits)
    }

    private func applyInlineMarkerRange(
        _ nsr: NSRange,
        markerLen: Int,
        innerAttrs: [NSAttributedString.Key: Any] = [:],
        fontTraits: NSFontDescriptor.SymbolicTraits = []
    ) {
        let scope = NSValue(range: nsr)
        let lead  = NSRange(location: nsr.location, length: markerLen)
        let trail = NSRange(location: nsr.location + nsr.length - markerLen, length: markerLen)
        storage.addAttributes([
            .foregroundColor: MarkdownStyler.markerColor,
            .mdMarkerScope: scope
        ], range: lead)
        storage.addAttributes([
            .foregroundColor: MarkdownStyler.markerColor,
            .mdMarkerScope: scope
        ], range: trail)

        let innerLen = nsr.length - markerLen * 2
        guard innerLen > 0 else { return }
        let inner = NSRange(location: nsr.location + markerLen, length: innerLen)
        if !innerAttrs.isEmpty {
            storage.addAttributes(innerAttrs, range: inner)
        }
        if !fontTraits.isEmpty {
            addFontTraits(fontTraits, in: inner)
        }
    }

    /// Merge symbolic traits into whatever font each sub-run already carries,
    /// rather than overwriting it. Nested emphasis (`***x***`) visits Strong
    /// then Emphasis over the same text; replacing the font would drop the
    /// outer trait and render bold-italic as italic.
    private func addFontTraits(_ traits: NSFontDescriptor.SymbolicTraits, in range: NSRange) {
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let current = (value as? NSFont) ?? MarkdownStyler.baseFont()
            var merged = current.fontDescriptor.symbolicTraits
            merged.formUnion(traits)
            let descriptor = current.fontDescriptor.withSymbolicTraits(merged)
            if let font = NSFont(descriptor: descriptor, size: current.pointSize) {
                storage.addAttribute(.font, value: font, range: subrange)
            }
        }
    }

    // MARK: Line range helper

    /// Returns the range of the line containing `location`, *excluding* the
    /// trailing newline. Matches the geometry of `NSString.enumerateSubstrings(.byLines)`
    /// that the previous regex-based block styler used.
    private func trimmedLineRange(at location: Int) -> NSRange {
        let probe = NSRange(location: max(0, min(location, source.length)), length: 0)
        let lr = source.lineRange(for: probe)
        var len = lr.length
        if len > 0 {
            let last = source.character(at: lr.location + len - 1)
            if last == 0x0A {
                len -= 1
                if len > 0 && source.character(at: lr.location + len - 1) == 0x0D {
                    len -= 1
                }
            }
        }
        return NSRange(location: lr.location, length: len)
    }
}
