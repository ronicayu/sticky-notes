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

    /// The note made on this Mac, kept while its checklist is still being
    /// ticked off. Removed once all four tasks are done, or the note is gone.
    static let noteIDKey = "welcomeNoteID"

    /// Create the welcome note if this install has never shown one and the
    /// store is empty. Returns it, or nil when nothing should be created.
    static func makeIfNeeded(
        store: NoteStore,
        defaults: UserDefaults,
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
            width: 320, height: 340,
            color: .yellow,
            labels: [],
            floatLevel: .floating,
            createdAt: now,
            updatedAt: now
        )
        store.save(note)
        defaults.set(note.id.uuidString, forKey: noteIDKey)
        return note
    }

    /// The four things the checklist asks for.
    enum Step: CaseIterable {
        case newNote, findNote, hideLabel, collapse

        /// Words of the task's line that no chord or edit of the rest changes.
        var phrase: String {
            switch self {
            case .newNote: return "make a new note"
            case .findNote: return "find any note"
            case .hideLabel: return "hide it from the menu bar"
            case .collapse: return "to collapse it"
            }
        }
    }

    /// Where a step's task is in `text`: the line without its newline, the one
    /// character between the brackets, and whether it is ticked.
    struct TaskLine: Equatable {
        let line: NSRange
        let box: NSRange
        let isChecked: Bool
    }

    static func taskLine(for step: Step, in text: String) -> TaskLine? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^([ \t]*-[ \t]\[)([ xX])(\][ \t]?)(.*)$"#, options: [.anchorsMatchLines]
        ) else { return nil }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard ns.substring(with: match.range(at: 4)).contains(step.phrase) else { continue }
            let box = match.range(at: 2)
            return TaskLine(line: match.range, box: box, isChecked: ns.substring(with: box) != " ")
        }
        return nil
    }

    /// True when every one of the four tasks is in the note and ticked.
    static func allTasksChecked(in text: String) -> Bool {
        Step.allCases.allSatisfy { taskLine(for: $0, in: text)?.isChecked == true }
    }

    /// The offer made once the checklist is done. A line in the note, so there
    /// is no window to answer and nothing to miss.
    static let doneLine = "All four done. Archive this note whenever you like (⌘W)."

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
