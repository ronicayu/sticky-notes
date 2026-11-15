import AppKit

/// The undo offers the app makes after an action that makes notes vanish:
/// archiving, hiding, a close that could not save. One toast at a time, and ⌘Z
/// fires it.
@MainActor final class UndoCenter: NSObject {
    private let toasts = ToastController()
    private let clock: AppClock

    init(clock: AppClock) {
        self.clock = clock
    }

    /// Archiving makes a note vanish with no recourse short of opening the
    /// panel and hunting for it. Offer to put it back.
    func offerUndoForArchive(of note: Note, restore: @escaping () -> Void) {
        toasts.show(Toast(message: Toast.archivedMessage(noteName: NoteSearch.summary(of: note)), undo: restore))
    }

    /// Hiding notes looks identical to them crashing. Same treatment.
    func offerUndoForHiding(count: Int, label: String?, restore: @escaping () -> Void) {
        guard count > 0 else { return }
        toasts.show(Toast(
            message: Toast.hiddenMessage(count: count, label: label),
            undoTitle: "Show",
            undo: restore
        ))
    }

    /// A close was refused because the text could not be saved.
    func offerRetryAfterRefusedClose(_ retry: @escaping () -> Void) {
        toasts.show(Toast(
            message: "Couldn't save — note kept open",
            undoTitle: "Retry",
            now: clock.now(),
            undo: retry
        ))
    }

    /// Whether a toast is waiting for an answer.
    var hasPendingOffer: Bool { toasts.visibleToast != nil }

    func dismiss() {
        toasts.dismiss()
    }

    /// ⌘Z with a toast on screen undoes that action. Routed through the main
    /// menu so it works no matter which of our windows has focus.
    @objc func undoLastAction(_ sender: Any?) {
        if toasts.performUndo() { return }
        // Nothing pending — let the focused text view handle its own undo.
        NSApp.sendAction(Selector(("undo:")), to: nil, from: sender)
    }
}
