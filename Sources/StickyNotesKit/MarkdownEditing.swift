import Foundation

/// Text transformations behind the editor's keyboard shortcuts.
///
/// Every operation is a pure function from (text, selection) to (text,
/// selection), so the behavior can be tested without standing up an
/// `NSTextView` — and so the tricky part, keeping the caret where the user
/// expects it, is pinned by tests rather than tried by hand.
enum MarkdownEditing {

    struct Edit: Equatable {
        var text: String
        var selection: NSRange
    }

    /// One level of list indentation. Two spaces keeps a nested item's content
    /// aligned under a `- ` marker, which is what CommonMark needs to read it
    /// as a child rather than a sibling.
    static let indentUnit = "  "

    // MARK: - Indent / outdent

    /// Prefix every line the selection touches with one indent level.
    static func indent(_ text: String, selection: NSRange) -> Edit {
        transformLines(text, selection: selection) { line in
            indentUnit + line
        }
    }

    /// Remove one indent level from every line the selection touches. Lines
    /// with no leading whitespace are left alone.
    static func outdent(_ text: String, selection: NSRange) -> Edit {
        transformLines(text, selection: selection) { line in
            if line.hasPrefix(indentUnit) { return String(line.dropFirst(indentUnit.count)) }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            if line.hasPrefix(" ") { return String(line.dropFirst()) }
            return line
        }
    }

    /// True when the caret sits on a list item — bullet, ordered, or checkbox.
    /// Tab only steals focus from the field when there's a list to indent.
    static func isListLine(_ text: String, selection: NSRange) -> Bool {
        let line = currentLineText(text, selection: selection)
        return line.range(of: #"^[ \t]*([-*+]|\d+\.)(\s|$)"#, options: .regularExpression) != nil
    }

    // MARK: - Emphasis

    /// Wrap the selection in `marker`, or unwrap it if it's already wrapped —
    /// so the same chord turns bold on and off.
    ///
    /// With an empty selection this inserts the pair and puts the caret
    /// between them, ready to type.
    static func toggleWrap(_ text: String, selection: NSRange, marker: String) -> Edit {
        let ns = text as NSString
        let markerLength = (marker as NSString).length

        // Selection already carries the markers on the inside.
        if selection.length >= markerLength * 2 {
            let selected = ns.substring(with: selection)
            if selected.hasPrefix(marker) && selected.hasSuffix(marker) {
                let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
                let updated = ns.replacingCharacters(in: selection, with: inner)
                return Edit(text: updated,
                            selection: NSRange(location: selection.location, length: (inner as NSString).length))
            }
        }

        // Markers sit just outside the selection.
        let outerStart = selection.location - markerLength
        let outerEnd = selection.location + selection.length + markerLength
        if outerStart >= 0 && outerEnd <= ns.length {
            let outer = NSRange(location: outerStart, length: selection.length + markerLength * 2)
            let outerText = ns.substring(with: outer)
            if outerText.hasPrefix(marker) && outerText.hasSuffix(marker) {
                let inner = ns.substring(with: selection)
                let updated = ns.replacingCharacters(in: outer, with: inner)
                return Edit(text: updated,
                            selection: NSRange(location: outerStart, length: selection.length))
            }
        }

        let selected = ns.substring(with: selection)
        let wrapped = marker + selected + marker
        let updated = ns.replacingCharacters(in: selection, with: wrapped)
        return Edit(text: updated,
                    selection: NSRange(location: selection.location + markerLength, length: selection.length))
    }

    // MARK: - Checkboxes

    /// Cycle the current line through the task states: plain text gains an
    /// unchecked box, an unchecked box becomes checked, and a checked box
    /// becomes unchecked again. A bullet keeps its indentation on the way.
    static func toggleCheckbox(_ text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        var line = ns.substring(with: lineRange)
        let hadNewline = line.hasSuffix("\n")
        if hadNewline { line.removeLast() }

        let replacement: String
        // Same grammar the styler renders, tab separators included —
        // otherwise a line that looks like a checkbox gets a second
        // checkbox prefixed onto it.
        if let match = firstMatch(#"^([ \t]*)-[ \t]\[([ xX])\][ \t]?(.*)$"#, in: line) {
            let indent = match[1], state = match[2], rest = match[3]
            let nowChecked = state == " "
            replacement = "\(indent)- [\(nowChecked ? "x" : " ")] \(rest)"
        } else if let match = firstMatch(#"^([ \t]*)[-*+] (.*)$"#, in: line) {
            replacement = "\(match[1])- [ ] \(match[2])"
        } else if let match = firstMatch(#"^([ \t]*)(.*)$"#, in: line) {
            replacement = "\(match[1])- [ ] \(match[2])"
        } else {
            return Edit(text: text, selection: selection)
        }

        let delta = (replacement as NSString).length - (line as NSString).length
        let updated = ns.replacingCharacters(
            in: NSRange(location: lineRange.location, length: (line as NSString).length),
            with: replacement
        )
        // Keep the caret at the same spot in the text, not the same offset —
        // adding "- [ ] " should carry it along rather than leave it behind.
        let caret = max(lineRange.location, selection.location + delta)
        return Edit(text: updated, selection: NSRange(location: caret, length: 0))
    }

    /// Completed and total checkbox counts, or nil when the note has no tasks.
    static func checkboxProgress(in text: String) -> (done: Int, total: Int)? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^[ \t]*-[ \t]\[([ xX])\](?:[ \t]|$)"#,
            options: [.anchorsMatchLines]
        ) else { return nil }

        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        let done = matches.filter { ns.substring(with: $0.range(at: 1)).lowercased() == "x" }.count
        return (done, matches.count)
    }

    // MARK: - Helpers

    /// Apply `transform` to every line the selection touches, and return a
    /// selection covering the same lines afterwards.
    private static func transformLines(
        _ text: String,
        selection: NSRange,
        _ transform: (String) -> String
    ) -> Edit {
        let ns = text as NSString
        let blockRange = ns.lineRange(for: selection)
        let block = ns.substring(with: blockRange)

        let hadTrailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hadTrailingNewline { lines.removeLast() }

        let transformed = lines.map(transform)
        var replacement = transformed.joined(separator: "\n")
        if hadTrailingNewline { replacement += "\n" }

        let updated = ns.replacingCharacters(in: blockRange, with: replacement)
        let firstLineDelta = (transformed.first as NSString?)?.length ?? 0
        let originalFirstLength = (lines.first as NSString?)?.length ?? 0

        if selection.length == 0 {
            // Caret-only: move it by however much this line grew or shrank,
            // clamped so outdenting past the margin doesn't push it backwards
            // into the previous line.
            let delta = firstLineDelta - originalFirstLength
            let caret = max(blockRange.location, selection.location + delta)
            return Edit(text: updated, selection: NSRange(location: caret, length: 0))
        }
        return Edit(text: updated,
                    selection: NSRange(location: blockRange.location, length: (replacement as NSString).length))
    }

    private static func currentLineText(_ text: String, selection: NSRange) -> String {
        let ns = text as NSString
        let location = min(max(0, selection.location), ns.length)
        return ns.substring(with: ns.lineRange(for: NSRange(location: location, length: 0)))
    }

    /// Capture groups of the first match, with index 0 as the whole match.
    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
    }
}
