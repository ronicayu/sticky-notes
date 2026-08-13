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
        let normalized = shortcut.replacingOccurrences(of: " ", with: "")
        return knownConflicts[normalized]
    }

    /// Conflicts worth warning about: shortcuts that a *frontmost* app is
    /// likely to want, where a global hotkey silently wins and the user is
    /// left wondering why Save As stopped working.
    private static let knownConflicts: [String: String] = [
        "⌘⇧S": "Also “Save As…” in many apps",
        "⌘⇧F": "Also “Find in Project” in Xcode and editors",
        "⌘⇧L": "Also a sidebar or downloads shortcut in some browsers",
        "⌘⇧H": "Also “Hide Others” adjacent in Finder",
        "⌘⇧N": "Also “New Folder” in Finder",
        "⌘⇧D": "Also “Add Bookmark” or “Duplicate” in some apps",
        "⌘⇧T": "Also “Reopen Closed Tab” in browsers",
        "⌘⇧P": "Also “Command Palette” in editors"
    ]

    /// Whether the app can register global hotkeys at all. Without this
    /// permission the shortcuts silently do nothing, which looks exactly like
    /// a broken app in its first minute.
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Line appended to the welcome note when permission is missing, so the
    /// first thing a new user reads explains why nothing is happening.
    static let permissionChecklistLine =
        "- [ ] **Hotkeys need permission** — open System Settings → Privacy & Security → Accessibility and switch on Sticky Notes"

    static let permissionMenuTitle = "⚠︎ Hotkeys need Accessibility permission"

    /// Deep link to the exact settings pane, so the instruction is one click
    /// rather than a scavenger hunt through System Settings.
    static let accessibilitySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
}
