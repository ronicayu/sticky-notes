import KeyboardShortcuts
import Foundation

/// The note a brand-new install opens with.
///
/// A first launch that shows an empty screen is indistinguishable from one
/// that failed. This is a real note — editable, archivable, deletable like any
/// other — that happens to explain the hotkeys.
enum WelcomeNote {
    /// Written once ever, tracked in `UserDefaults` rather than by looking for
    /// notes on disk: a user who deletes it should not get it back, and one
    /// who already has notes should never have seen it.
    private static let shownKey = "didShowWelcomeNote"

    /// Create the welcome note if this install has never shown one and the
    /// store is empty. Returns it, or nil when nothing should be created.
    static func makeIfNeeded(
        store: NoteStore,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> Note? {
        guard !defaults.bool(forKey: shownKey) else { return nil }
        defaults.set(true, forKey: shownKey)

        // Someone upgrading from an older build already has notes; dropping a
        // welcome note on their desk would be noise.
        guard store.loadActive().isEmpty, store.loadArchived().isEmpty else { return nil }

        let note = Note(
            id: UUID(),
            title: "Welcome",
            content: body,
            positionX: 120, positionY: 260,
            width: 320, height: 340,
            collapsed: false,
            color: .yellow,
            labels: [],
            floatLevel: .floating,
            createdAt: now,
            updatedAt: now
        )
        store.save(note)
        return note
    }

    /// Exposed so a test can check the shortcuts stay in sync with the ones
    /// the app actually registers. Chords are read from the live bindings
    /// rather than spelled out, so a rebind before first launch can't leave
    /// the note describing keys that do nothing.
    static var body: String { bodyText() }

    static func bodyText(
        newNote: String = describe(.newNote, default: "⌘⇧S"),
        find: String = describe(.quickSwitcher, default: "⌘⇧F")
    ) -> String {
        """
    This is a real note — edit it, or throw it away.

    - [ ] Press **\(newNote)** to make a new note
    - [ ] Press **\(find)** to find any note by typing
    - [ ] Try a `#label`, then hide it from the menu bar
    - [ ] Double-click this note's top bar to collapse it

    **⌘B** bolds, **⌘↩** turns a line into a task, and **⇥** indents a list.

    Everything lives in plain files you can open anywhere — point Settings at \
    an Obsidian vault and these become Markdown.
    """
    }

    private static func describe(_ name: KeyboardShortcuts.Name, default fallback: String) -> String {
        KeyboardShortcuts.getShortcut(for: name).map(String.init(describing:)) ?? fallback
    }
}
