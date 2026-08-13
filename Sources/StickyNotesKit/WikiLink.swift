import AppKit

/// `[[Some Note]]` links.
///
/// The styler turns the target into a `stickynotes-wiki:` URL so it can ride
/// the normal `.link` attribute. Resolution happens at click time, because
/// what a target points at changes as notes are created and renamed.
enum WikiLink {
    static let scheme = "stickynotes-wiki"

    static func url(for target: String) -> URL? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = ""
        components.queryItems = [URLQueryItem(name: "target", value: trimmed)]
        return components.url
    }

    /// The note name a wiki URL points at, or nil if this isn't one.
    static func target(of url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "target" })?.value
    }

    /// Obsidian's own URL scheme, used when the target isn't one of our notes
    /// but the user has a vault that might contain it.
    static func obsidianURL(vaultPath: String, target: String) -> URL? {
        let vaultName = (vaultPath as NSString).lastPathComponent
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "vault", value: vaultName),
            URLQueryItem(name: "file", value: target)
        ]
        return components.url
    }

    /// Find the note a target names. Titles are matched case-insensitively,
    /// and a note with no title falls back to its first line — which is what
    /// the panel and switcher display as its name too.
    static func resolve(_ target: String, in notes: [Note]) -> Note? {
        let wanted = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }

        if let exact = notes.first(where: {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
        }) {
            return exact
        }
        return notes.first(where: { NoteSearch.summary(of: $0).lowercased() == wanted })
    }
}
