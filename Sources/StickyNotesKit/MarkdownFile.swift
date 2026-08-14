import Foundation

/// Minimal YAML-frontmatter Markdown reader/writer. Schema is restricted to
/// flat string-keyed string values — enough for our note metadata, not a
/// general YAML implementation.
enum MarkdownFile {
    struct Document {
        var frontmatter: [(String, String)]
        var body: String

        func value(for key: String) -> String? {
            frontmatter.first(where: { $0.0 == key })?.1
        }
    }

    private static let separator = "---"

    static func parse(_ raw: String) -> Document {
        let lines = raw.components(separatedBy: "\n")
        // Trimming newlines as well as spaces keeps CRLF files working: a
        // vault edited on Windows leaves a `\r` on every line, which used to
        // stop `---` matching at all, so the metadata leaked into the body.
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == separator else {
            return Document(frontmatter: [], body: raw)
        }

        var i = 1
        var frontmatter: [(String, String)] = []
        var closed = false
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == separator {
                i += 1
                closed = true
                break
            }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    frontmatter.append((key, unquote(value)))
                }
            }
            i += 1
        }

        // No closing separator: this isn't frontmatter, it's a document that
        // happens to open with a horizontal rule. Consuming it as metadata
        // left an empty body that the next save would write back over the
        // user's real text.
        guard closed else { return Document(frontmatter: [], body: raw) }

        // Only a truly empty line (or a bare CR) is the cosmetic gap; a line
        // of spaces is content, and dropping it would edit the user's note.
        if i < lines.count, lines[i].isEmpty || lines[i] == "\r" { i += 1 }
        let body = lines[i...].joined(separator: "\n")
        return Document(frontmatter: frontmatter, body: body)
    }

    static func serialize(_ document: Document, forceQuoteKeys: Set<String> = []) -> String {
        var out = "\(separator)\n"
        for (key, value) in document.frontmatter {
            let serialized = forceQuoteKeys.contains(key) ? forceQuote(value) : quoteIfNeeded(value)
            out += "\(key): \(serialized)\n"
        }
        out += "\(separator)\n\n"
        out += document.body
        return out
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
