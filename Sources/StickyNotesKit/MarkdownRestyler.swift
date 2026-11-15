import AppKit

/// Keeps one text storage styled while it is edited, restyling only the
/// paragraphs an edit touched.
///
/// Everything `MarkdownStyler` draws sits inside one paragraph, the text between
/// blank lines. After a single edit the paragraph it landed in, and the one on
/// each side, are styled again and the rest is left as it was. A full restyle is
/// the fallback whenever the edit could change how text elsewhere is read:
///
/// - a fenced code block or an HTML block that can run over blank lines is in the
///   text now, or was before the edit;
/// - a paragraph in the slice starts with a space or tab, so it may continue a
///   list item opened in an earlier paragraph (or be indented code);
/// - the restyler has not seen this storage styled yet.
///
/// The result is attribute for attribute what `MarkdownStyler.apply(to:)` gives
/// on the whole text; a test checks that over random edits.
@MainActor final class MarkdownRestyler {
    /// Edits answered by restyling a slice, and by restyling everything. Read by tests.
    private(set) var incrementalCount = 0
    private(set) var fullCount = 0

    /// Whether the text, as last styled, had a block that reads across blank lines.
    /// Nil until the first full restyle.
    private var hadSpanningBlocks: Bool?

    /// Restyle all of `storage`. Returns the range whose attributes were rewritten.
    @discardableResult
    func restyleAll(_ storage: NSTextStorage) -> NSRange {
        MarkdownStyler.apply(to: storage)
        hadSpanningBlocks = Self.hasSpanningBlocks(storage.string as NSString)
        fullCount += 1
        return NSRange(location: 0, length: storage.length)
    }

    /// Restyle after one edit. `editedRange` is where the changed text now is and
    /// `changeInLength` how much longer the text became, as `NSTextStorage` reports
    /// them. The text outside the returned range keeps its attributes, so the
    /// caller must have restyled before every other edit.
    @discardableResult
    func restyle(_ storage: NSTextStorage, edited editedRange: NSRange, changeInLength: Int) -> NSRange {
        let text = storage.string as NSString
        let spanning = Self.hasSpanningBlocks(text)
        guard storage.length > 0, hadSpanningBlocks == false, !spanning,
              editedRange.location >= 0, NSMaxRange(editedRange) <= text.length,
              let slice = Self.slice(of: text, around: editedRange),
              slice.length < text.length, !Self.hasIndentedParagraph(in: text, range: slice)
        else {
            return restyleAll(storage)
        }

        let sliceStorage = NSTextStorage(string: text.substring(with: slice))
        MarkdownStyler.apply(to: sliceStorage)
        Self.copyAttributes(from: sliceStorage, into: storage, at: slice.location)
        Self.moveScopes(in: storage, after: NSMaxRange(slice), by: changeInLength)
        incrementalCount += 1
        return slice
    }

    // MARK: - Copying

    private static func copyAttributes(from slice: NSTextStorage, into storage: NSTextStorage, at offset: Int) {
        var shifted: [ObjectIdentifier: MarkerScope] = [:]
        storage.beginEditing()
        defer { storage.endEditing() }
        slice.enumerateAttributes(in: NSRange(location: 0, length: slice.length), options: []) { attributes, run, _ in
            var attributes = attributes
            if let scope = attributes[.mdMarkerScope] as? MarkerScope {
                let moved = shifted[ObjectIdentifier(scope)] ?? {
                    let copy = MarkerScope(NSRange(location: scope.range.location + offset, length: scope.range.length))
                    shifted[ObjectIdentifier(scope)] = copy
                    return copy
                }()
                attributes[.mdMarkerScope] = moved
            }
            storage.setAttributes(attributes, range: NSRange(location: run.location + offset, length: run.length))
        }
    }

    /// Text typed before a marker moved its scope with it; the scope object has to
    /// say so. The objects are changed in place, which touches no attribute run,
    /// so the layout of the text after the edit stays valid.
    private static func moveScopes(in storage: NSTextStorage, after location: Int, by delta: Int) {
        guard delta != 0, location < storage.length else { return }
        var seen = Set<ObjectIdentifier>()
        storage.enumerateAttribute(
            .mdMarkerScope, in: NSRange(location: location, length: storage.length - location), options: []
        ) { value, _, _ in
            guard let scope = value as? MarkerScope, seen.insert(ObjectIdentifier(scope)).inserted else { return }
            scope.range.location += delta
        }
    }

    // MARK: - What can reach across blank lines

    /// True when the text holds a fenced code block marker, an HTML block that
    /// ends at something other than a blank line, or a carriage return that is
    /// not part of a Windows line break. Such text is always restyled whole.
    static func hasSpanningBlocks(_ text: NSString) -> Bool {
        let whole = NSRange(location: 0, length: text.length)
        for marker in ["```", "~~~"] where text.range(of: marker, options: .literal).location != NSNotFound {
            return true
        }
        var carriageReturn = text.range(of: "\r", options: .literal)
        while carriageReturn.location != NSNotFound {
            let after = carriageReturn.location + 1
            if after >= text.length || text.character(at: after) != newline { return true }
            carriageReturn = text.range(of: "\r", options: .literal, range: NSRange(location: after, length: text.length - after))
        }
        var search = whole
        while true {
            let found = text.range(of: "<", options: .literal, range: search)
            guard found.location != NSNotFound else { return false }
            let tail = NSRange(location: found.location + 1, length: min(10, text.length - found.location - 1))
            let following = text.substring(with: tail).lowercased()
            if following.hasPrefix("!") || following.hasPrefix("?") || following.hasPrefix("pre")
                || following.hasPrefix("script") || following.hasPrefix("style") || following.hasPrefix("textarea") {
                return true
            }
            let next = found.location + 1
            search = NSRange(location: next, length: text.length - next)
        }
    }

    // MARK: - Paragraphs

    private static let tab = unichar(UInt8(ascii: "\t"))
    private static let space = unichar(UInt8(ascii: " "))
    private static let newline = unichar(UInt8(ascii: "\n"))
    private static let carriageReturn = unichar(UInt8(ascii: "\r"))

    /// Where the line that holds `location` starts. Only `\n` and `\r` end a line:
    /// that is what Markdown does, and `NSString` also splits at U+2028 and U+0085.
    static func lineStart(in text: NSString, at location: Int) -> Int {
        var start = min(max(location, 0), text.length)
        while start > 0 {
            let before = text.character(at: start - 1)
            if before == newline || before == carriageReturn { break }
            start -= 1
        }
        return start
    }

    /// The start of the line after the one starting at `start`, and whether that
    /// line holds nothing but spaces and tabs.
    private static func line(in text: NSString, at start: Int) -> (next: Int, blank: Bool) {
        var index = start
        var blank = true
        while index < text.length {
            let char = text.character(at: index)
            if char == newline {
                return (index + 1, blank)
            }
            if char == carriageReturn {
                let next = index + 1 < text.length && text.character(at: index + 1) == newline ? index + 2 : index + 1
                return (next, blank)
            }
            if char != space && char != tab { blank = false }
            index += 1
        }
        return (text.length, blank)
    }

    private static func previousLineStart(in text: NSString, before start: Int) -> Int? {
        guard start > 0 else { return nil }
        var terminator = start - 1
        if text.character(at: terminator) == newline, terminator > 0, text.character(at: terminator - 1) == carriageReturn {
            terminator -= 1
        }
        return lineStart(in: text, at: terminator)
    }

    private static func isBlank(in text: NSString, lineAt start: Int) -> Bool {
        line(in: text, at: start).blank
    }

    /// Start of the paragraph that ends just before the line at `start`: skips
    /// the blank lines above it, then the lines of the paragraph. Nil at the top.
    private static func paragraphStart(above start: Int, in text: NSString) -> Int? {
        var cursor = start
        var found: Int?
        while let previous = previousLineStart(in: text, before: cursor) {
            let blank = isBlank(in: text, lineAt: previous)
            if found != nil && blank { break }
            if !blank { found = previous }
            cursor = previous
        }
        return found
    }

    /// End of the paragraph that starts at or below the line at `start`: skips
    /// blank lines, then takes the lines of the paragraph. The end is just after
    /// its last line break.
    private static func paragraphEnd(below start: Int, in text: NSString) -> Int? {
        var cursor = start
        var foundEnd: Int?
        while cursor < text.length {
            let (next, blank) = line(in: text, at: cursor)
            if foundEnd != nil && blank { break }
            if !blank { foundEnd = next }
            cursor = next
        }
        return foundEnd
    }

    /// The paragraphs of `text`: runs of lines that are not blank, each with its
    /// line breaks.
    static func paragraphRanges(in text: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var start: Int?
        var cursor = 0
        while cursor < text.length {
            let (next, blank) = line(in: text, at: cursor)
            if blank {
                if let begin = start {
                    result.append(NSRange(location: begin, length: cursor - begin))
                    start = nil
                }
            } else if start == nil {
                start = cursor
            }
            cursor = next
        }
        if let begin = start { result.append(NSRange(location: begin, length: text.length - begin)) }
        return result
    }

    /// The whole lines to restyle for an edit: the paragraphs the edit touched and
    /// one on each side. Nil when the text has no such paragraph to restyle.
    static func slice(of text: NSString, around edit: NSRange) -> NSRange? {
        guard text.length > 0 else { return nil }
        var low = lineStart(in: text, at: min(edit.location, text.length - 1))
        if !isBlank(in: text, lineAt: low) {
            while let previous = previousLineStart(in: text, before: low), !isBlank(in: text, lineAt: previous) {
                low = previous
            }
        }
        if let above = paragraphStart(above: low, in: text) { low = above }
        // Include what follows the edit, and the blank lines between it and the
        // paragraph below.
        var high = lineStart(in: text, at: min(NSMaxRange(edit), text.length - 1))
        for _ in 0..<2 {
            if let end = paragraphEnd(below: high, in: text) { high = end }
        }
        high = max(high, NSMaxRange(edit))
        return NSRange(location: low, length: min(text.length, high) - low)
    }

    /// True when some paragraph in `range` starts with a space or a tab.
    private static func hasIndentedParagraph(in text: NSString, range: NSRange) -> Bool {
        var cursor = range.location
        var previousBlank = true
        while cursor < NSMaxRange(range) {
            let (next, blank) = line(in: text, at: cursor)
            if previousBlank && !blank {
                let first = text.character(at: cursor)
                if first == space || first == tab { return true }
            }
            previousBlank = blank
            cursor = next
        }
        return false
    }
}
