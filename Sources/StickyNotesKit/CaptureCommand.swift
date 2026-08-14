import Foundation

/// A `stickynotes://` URL, parsed.
///
/// The scheme exists so Raycast, Alfred, Shortcuts, and shell scripts can
/// drive the app without any of them needing an integration written for them.
enum CaptureCommand: Equatable {
    /// `stickynotes://new?text=…&title=…&color=…&labels=a,b`
    case new(title: String?, text: String, color: NoteColor?, labels: [String])
    /// `stickynotes://search?q=…` — opens the quick switcher, pre-filled.
    case search(query: String)
    /// `stickynotes://daily` — opens today's daily note.
    case daily

    /// Parse a URL into a command, or nil when it isn't one we handle.
    /// Unknown parameters are ignored rather than rejected, so callers can
    /// pass extras without breaking.
    static func parse(_ url: URL) -> CaptureCommand? {
        guard url.scheme?.lowercased() == "stickynotes" else { return nil }

        // Read the action out of the raw string rather than from `host` or
        // `path`. Foundation disagrees across macOS versions about where the
        // action in `stickynotes:new?text=hi` (no slashes) surfaces: macOS 15+
        // reports it as `path`, macOS 14 treats the URL as opaque and reports
        // neither, which made that spelling silently do nothing there.
        let raw = url.absoluteString
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        var remainder = raw[raw.index(after: colon)...]
        if remainder.hasPrefix("//") { remainder = remainder.dropFirst(2) }

        let actionPart: Substring
        let queryPart: Substring
        if let mark = remainder.firstIndex(of: "?") {
            actionPart = remainder[..<mark]
            queryPart = remainder[remainder.index(after: mark)...]
        } else {
            actionPart = remainder
            queryPart = ""
        }

        let action = actionPart.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let query = queryItems(from: String(queryPart))

        switch action.lowercased() {
        case "new":
            let text = query["text"] ?? query["body"] ?? ""
            let title = query["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let color = query["color"].flatMap { NoteColor(rawValue: $0.lowercased()) }
            let labels = (query["labels"] ?? "")
                .split(separator: ",")
                .map { NoteLabel.normalize(String($0)) }
                .filter { !$0.isEmpty }
            return .new(title: (title?.isEmpty ?? true) ? nil : title,
                        text: text,
                        color: color,
                        labels: labels)

        case "search", "find":
            return .search(query: query["q"] ?? query["query"] ?? "")

        case "daily", "today":
            return .daily

        default:
            return nil
        }
    }

    /// `+` means a space in a query string, which `URLComponents` doesn't
    /// decode — a note captured from a shell script would otherwise arrive
    /// full of plus signs.
    ///
    /// Parsed through a synthesized hierarchical URL so percent-decoding
    /// behaves the same regardless of how the original URL was spelled.
    private static func queryItems(from query: String) -> [String: String] {
        // Substitute before decoding, not after: a caller that correctly
        // encoded a literal plus as `%2B` means a plus, and rewriting the
        // decoded value would turn "C++" into "C  ".
        let normalized = query.replacingOccurrences(of: "+", with: "%20")
        guard !normalized.isEmpty,
              let components = URLComponents(string: "scheme://host?\(normalized)"),
              let items = components.queryItems else { return [:] }
        var out: [String: String] = [:]
        for item in items {
            guard let value = item.value else { continue }
            out[item.name.lowercased()] = value
        }
        return out
    }
}
