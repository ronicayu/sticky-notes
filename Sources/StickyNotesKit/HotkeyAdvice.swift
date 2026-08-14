import AppKit
import KeyboardShortcuts

/// Known collisions between our default hotkeys and shortcuts people already
/// have muscle memory for.
///
/// Purely informational — nothing here changes behavior. The recorder in
/// Settings already lets any shortcut be rebound; what was missing was any
/// hint that a chord is contested, so the fix is a line of text rather than
/// a heuristic that guesses when to suppress a hotkey.
enum HotkeyAdvice {

    /// A human-readable description of a shortcut, e.g. "⌘⇧S".
    @MainActor
    static func describe(_ name: KeyboardShortcuts.Name) -> String? {
        KeyboardShortcuts.getShortcut(for: name)?.description
    }

    /// What else commonly uses this chord, or nil when it's uncontested.
    static func conflictNote(for shortcut: String?) -> String? {
        guard let shortcut = shortcut else { return nil }
        return knownConflicts[normalize(shortcut)]
    }

    /// Modifier glyphs in the order macOS renders them, so a chord matches
    /// however it was spelled. The table used to be keyed "⌘⇧S" while the
    /// shortcut recorder produces "⇧⌘S", and every lookup silently missed.
    private static let modifierOrder: [Character] = ["⌃", "⌥", "⇧", "⌘"]

    private static func normalize(_ shortcut: String) -> String {
        var modifiers: Set<Character> = []
        var key = ""
        for character in shortcut where !character.isWhitespace {
            if modifierOrder.contains(character) {
                modifiers.insert(character)
            } else {
                key.append(character)
            }
        }
        return String(modifierOrder.filter(modifiers.contains)) + key.uppercased()
    }

    /// Conflicts worth warning about: shortcuts that a *frontmost* app is
    /// likely to want, where a global hotkey silently wins and the user is
    /// left wondering why Save As stopped working.
    private static let knownConflicts: [String: String] = [
        "⇧⌘S": "Also “Save As…” in many apps",
        "⇧⌘F": "Also “Find in Project” in Xcode and editors",
        "⇧⌘L": "Also a sidebar or downloads shortcut in some browsers",
        "⇧⌘H": "Also “Hide Others” adjacent in Finder",
        "⇧⌘N": "Also “New Folder” in Finder",
        "⇧⌘D": "Also “Add Bookmark” or “Duplicate” in some apps",
        "⇧⌘T": "Also “Reopen Closed Tab” in browsers",
        "⇧⌘P": "Also “Command Palette” in editors"
    ]

    /// Global hotkeys are registered through Carbon's `RegisterEventHotKey`,
    /// which needs no Accessibility permission — the app used to warn about a
    /// permission it never required, on every launch, forever.
}
