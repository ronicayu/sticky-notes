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

        // stickynotes://new and stickynotes:new both reach people's muscle
        // memory; take the action from whichever part carries it.
        let action = (url.host?.isEmpty == false ? url.host : nil)
            ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let query = queryItems(of: url)

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
    private static func queryItems(of url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return [:] }
        var out: [String: String] = [:]
        for item in items {
            guard let value = item.value else { continue }
            out[item.name.lowercased()] = value.replacingOccurrences(of: "+", with: " ")
        }
        return out
    }
}
