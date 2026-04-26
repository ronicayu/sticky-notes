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
        guard lines.first?.trimmingCharacters(in: .whitespaces) == separator else {
            return Document(frontmatter: [], body: raw)
        }

        var i = 1
        var frontmatter: [(String, String)] = []
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == separator {
                i += 1
                break
            }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    frontmatter.append((key, unquote(value)))
                }
            }
            i += 1
        }

        // Drop a single blank line after the closing separator (cosmetic gap)
        if i < lines.count && lines[i].isEmpty { i += 1 }
        let body = lines[i...].joined(separator: "\n")
        return Document(frontmatter: frontmatter, body: body)
    }

    static func serialize(_ document: Document) -> String {
        var out = "\(separator)\n"
        for (key, value) in document.frontmatter {
            out += "\(key): \(quoteIfNeeded(value))\n"
        }
        out += "\(separator)\n\n"
        out += document.body
        return out
    }

    private static func unquote(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        let first = raw.first!
        let last = raw.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        if value.isEmpty { return "\"\"" }
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
