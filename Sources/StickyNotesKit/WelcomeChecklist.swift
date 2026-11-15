import Foundation

/// Ticks the welcome note's tasks as the person does each thing, then says it
/// is done and stops.
///
/// The note is never made here and never written behind the window's back: a
/// task is ticked through the open window's text, as a click on its box would,
/// so the tick is saved like any edit of the person's and meets an outside
/// edit the way theirs does. With no window for the note, it has been archived
/// or deleted, and the checklist stops for good.
@MainActor final class WelcomeChecklist {
    private let defaults: UserDefaults
    private let windowFor: (UUID) -> NoteWindowController?

    init(defaults: UserDefaults, windowFor: @escaping (UUID) -> NoteWindowController?) {
        self.defaults = defaults
        self.windowFor = windowFor
    }

    /// The welcome note while its checklist is still open.
    var noteID: UUID? { defaults.string(forKey: WelcomeNote.noteIDKey).flatMap(UUID.init(uuidString:)) }

    var isListening: Bool { noteID != nil }

    /// The person did `step`.
    func did(_ step: WelcomeNote.Step) {
        guard let id = noteID else { return }
        guard let window = windowFor(id) else {
            stop()
            return
        }
        let text = window.textView.string
        if let task = WelcomeNote.taskLine(for: step, in: text), !task.isChecked {
            window.replaceBody(range: task.box, with: "x")
        }
        finishIfDone(in: window)
    }

    private func finishIfDone(in window: NoteWindowController) {
        let text = window.textView.string
        guard WelcomeNote.allTasksChecked(in: text) else { return }
        stop()
        guard !text.contains(WelcomeNote.doneLine) else { return }
        let lastTask = WelcomeNote.Step.allCases
            .compactMap { WelcomeNote.taskLine(for: $0, in: text)?.line }
            .map { $0.location + $0.length }
            .max() ?? (text as NSString).length
        window.replaceBody(range: NSRange(location: lastTask, length: 0), with: "\n\n" + WelcomeNote.doneLine)
    }

    private func stop() {
        defaults.removeObject(forKey: WelcomeNote.noteIDKey)
    }
}
