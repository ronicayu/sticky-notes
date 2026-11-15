import Foundation

/// Minimal YAML-frontmatter Markdown reader/writer. It reads the flat keys the
/// app owns, and carries every other line of the frontmatter (tags, aliases,
/// plugin keys, nested values, comments) through a read and a write unchanged,
/// so a file Obsidian has added to survives the app's next save.
enum MarkdownFile {
    /// One place in the frontmatter, in file order.
    enum Slot: Equatable {
        /// A key the caller owns. It is written from `Document.frontmatter`,
        /// where the file had it.
        case key(String)
        /// Lines the caller does not own, written back exactly as they were
        /// (without the final line break).
        case verbatim(String)
    }

    struct Document {
        /// The `key: value` entries read from the file, with the value unquoted:
        /// those of the owned keys, or all of them when none were named. A block
        /// list (`key:` then `- item` lines) is flattened to `[a, b]`. When
        /// writing, the owned keys and their values.
        var frontmatter: [(String, String)]
        var body: String
        /// The frontmatter as it sat in the file: the owned keys by name and
        /// everything else verbatim. Empty for a new document, which is written
        /// in `frontmatter` order. When writing, keys of `frontmatter` that the
        /// layout does not name follow it.
        var layout: [Slot] = []
        /// Keys whose value was a block list in the file.
        var blockListKeys: Set<String> = []

        func value(for key: String) -> String? {
            frontmatter.first(where: { $0.0 == key })?.1
        }
    }

    private static let separator = "---"

    /// `ownedKeys` are the keys the caller writes itself; they become `.key`
    /// slots (the first one of each name) and every other line is kept verbatim
    /// in `layout`. With none named there is no layout and every key is read.
    static func parse(_ raw: String, ownedKeys: Set<String> = []) -> Document {
        let lines = raw.components(separatedBy: "\n")
        // Trimming newlines as well as spaces keeps CRLF files working: a
        // vault edited on Windows leaves a `\r` on every line, which used to
        // stop `---` matching at all, so the metadata leaked into the body.
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == separator else {
            return Document(frontmatter: [], body: raw)
        }

        var i = 1
        var blocks: [Block] = []
        var closed = false
        while i < lines.count {
            let line = lines[i]
            // The closing fence starts the line. An indented `---` is text
            // inside a multi-line value.
            if line.first?.isWhitespace != true, line.trimmingCharacters(in: .whitespacesAndNewlines) == separator {
                i += 1
                closed = true
                break
            }
            if let key = topLevelKey(of: line) {
                blocks.append(Block(key: key, lines: [line]))
            } else if !blocks.isEmpty, blocks[blocks.count - 1].key != nil, continuesBlock(line) {
                blocks[blocks.count - 1].lines.append(line)
            } else {
                blocks.append(Block(key: nil, lines: [line]))
            }
            i += 1
        }

        // No closing separator: this isn't frontmatter, it's a document that
        // happens to open with a horizontal rule. Consuming it as metadata
        // left an empty body that the next save would write back over the
        // user's real text.
        guard closed else { return Document(frontmatter: [], body: raw) }

        var frontmatter: [(String, String)] = []
        var layout: [Slot] = []
        var blockListKeys: Set<String> = []
        var seenOwned: Set<String> = []
        for block in blocks {
            // Blank lines after a value are not part of it; each stays where it was.
            var body = block.lines
            var trailing: [String] = []
            while block.key != nil, body.count > 1, isBlank(body[body.count - 1]) {
                trailing.insert(body.removeLast(), at: 0)
            }
            if let key = block.key, ownedKeys.isEmpty || ownedKeys.contains(key) {
                let entry = entry(from: body)
                frontmatter.append((key, entry.value))
                if entry.isBlockList { blockListKeys.insert(key) }
                if !ownedKeys.isEmpty, seenOwned.insert(key).inserted { layout.append(.key(key)) }
            } else {
                layout.append(.verbatim(body.joined(separator: "\n")))
            }
            for line in trailing { layout.append(.verbatim(line)) }
        }

        // Only a truly empty line (or a bare CR) is the cosmetic gap; a line
        // of spaces is content, and dropping it would edit the user's note.
        if i < lines.count, lines[i].isEmpty || lines[i] == "\r" { i += 1 }
        let body = lines[i...].joined(separator: "\n")
        return Document(
            frontmatter: frontmatter, body: body, layout: ownedKeys.isEmpty ? [] : layout,
            blockListKeys: blockListKeys
        )
    }

    /// `blockListKeys` are written as a block list when their value is a flow
    /// list, which is how the file had them.
    static func serialize(
        _ document: Document, forceQuoteKeys: Set<String> = [], blockListKeys: Set<String> = []
    ) -> String {
        var out = "\(separator)\n"
        var written: Set<String> = []
        func write(_ key: String, _ value: String) {
            written.insert(key)
            if blockListKeys.contains(key), let items = flowListItems(value), !items.isEmpty {
                out += "\(key):\n" + items.map { "  - \(blockItem($0))\n" }.joined()
                return
            }
            let serialized = forceQuoteKeys.contains(key) ? forceQuote(value) : quoteIfNeeded(value)
            out += "\(key): \(serialized)\n"
        }
        for slot in document.layout {
            switch slot {
            case let .verbatim(text):
                out += text + "\n"
            case let .key(key):
                if !written.contains(key), let value = document.value(for: key) { write(key, value) }
            }
        }
        for (key, value) in document.frontmatter where !written.contains(key) {
            write(key, value)
        }
        out += "\(separator)\n\n"
        out += document.body
        return out
    }

    // MARK: - Reading blocks

    private struct Block {
        var key: String?
        var lines: [String]
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The key of a line that starts a new entry: it begins in the first column,
    /// is not a comment or a list item, and has a name before its first colon.
    private static func topLevelKey(of line: String) -> String? {
        guard let first = line.first, !first.isWhitespace, first != "#",
              !(line.hasPrefix("-") && (line.count == 1 || line[line.index(after: line.startIndex)].isWhitespace)),
              let colon = line.firstIndex(of: ":")
        else { return nil }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    /// A line that belongs to the entry above it: indented, blank, or an item of
    /// a list that sits in the key's own column.
    private static func continuesBlock(_ line: String) -> Bool {
        guard let first = line.first else { return true }
        if first.isWhitespace { return true }
        return first == "-" && (line.count == 1 || line[line.index(after: line.startIndex)].isWhitespace)
    }

    private static func entry(from lines: [String]) -> (value: String, isBlockList: Bool) {
        let first = lines[0]
        let colon = first.firstIndex(of: ":")!
        let rest = String(first[first.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let more = lines.dropFirst()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if more.isEmpty { return (unquote(rest), false) }

        if rest.isEmpty, more.allSatisfy({ $0 == "-" || $0.hasPrefix("- ") }) {
            let items = more.map { unquote(String($0.dropFirst()).trimmingCharacters(in: .whitespaces)) }
            return ("[" + items.joined(separator: ", ") + "]", true)
        }
        // A block scalar's text is on the lines below its `|` or `>`.
        if rest.range(of: #"^[|>][+-]?[0-9]*$"#, options: .regularExpression) != nil {
            return (more.joined(separator: rest.hasPrefix("|") ? "\n" : " "), false)
        }
        // A value folded over several lines reads as one line.
        return (unquote(([rest] + more).filter { !$0.isEmpty }.joined(separator: " ")), false)
    }

    private static func flowListItems(_ value: String) -> [String]? {
        guard value.first == "[", value.last == "]" else { return nil }
        return value.dropFirst().dropLast().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func blockItem(_ item: String) -> String {
        item.rangeOfCharacter(from: CharacterSet(charactersIn: ":#\"'[]{}&*!|>%@`,")) == nil
            && item.first != "-" && item.first != "?"
            ? item : forceQuote(item)
    }

    private static func unquote(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        let first = raw.first!
        let last = raw.last!
        if first == "\"" && last == "\"" {
            return unescapeDoubleQuoted(String(raw.dropFirst().dropLast()))
        }
        if first == "'" && last == "'" {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    private static func unescapeDoubleQuoted(_ inner: String) -> String {
        var out = ""
        out.reserveCapacity(inner.count)
        var iter = inner.makeIterator()
        while let ch = iter.next() {
            if ch == "\\" {
                if let next = iter.next() {
                    switch next {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    default:  out.append(next)
                    }
                }
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static func forceQuote(_ value: String) -> String {
        // Frontmatter is parsed line by line, so a raw newline in a value
        // would split the record and corrupt everything after it. The reader
        // already understands these escapes.
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        if value.isEmpty { return "\"\"" }
        // Values shaped like a YAML flow list (`[a, b, c]`) and flow map
        // (`{a: 1}`) are valid raw YAML — pass them through verbatim instead
        // of escaping into a string. Everything else with risky punctuation
        // gets the quote treatment.
        if value.first == "[" && value.last == "]" { return value }
        if value.first == "{" && value.last == "}" { return value }
        let needsQuote = value.contains(":")
            || value.contains("#")
            || value.first == " "
            || value.last == " "
            || value.first == "-"
            || value.first == "{"
            || value.first == "["
        if needsQuote {
            let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return value
    }
}
