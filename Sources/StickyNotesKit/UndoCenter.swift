import AppKit

/// The undo offers the app makes after an action that makes notes vanish:
/// archiving, hiding, a close that could not save. One toast at a time, and ⌘Z
/// fires it.
@MainActor final class UndoCenter: NSObject {
    private let toasts = ToastController()
    private let clock: AppClock
    /// Set when text is edited while a toast is up: from then on ⌘Z belongs to
    /// that text, and the toast keeps its button.
    private var textEditedSinceOffer = false

    init(clock: AppClock) {
        self.clock = clock
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange(_:)), name: NSText.didChangeNotification, object: nil
        )
    }

    private func show(_ toast: Toast) {
        textEditedSinceOffer = false
        toasts.show(toast)
    }

    @objc private func textDidChange(_ notification: Notification) {
        // An edit the app makes itself, such as ticking a welcome task, is not
        // typing, and ⌘Z has nothing in the text to take.
        let editor = (notification.object as? NSTextView)?.delegate as? MarkdownEditorController
        guard editor?.isEditingProgrammatically != true else { return }
        textEditedSinceOffer = true
    }

    /// Archiving makes a note vanish with no recourse short of opening the
    /// panel and hunting for it. Offer to put it back.
    func offerUndoForArchive(of note: Note, restore: @escaping () -> Void) {
        show(Toast(message: Toast.archivedMessage(noteName: NoteSearch.summary(of: note)), undo: restore))
    }

    /// Hiding notes looks identical to them crashing. Same treatment.
    func offerUndoForHiding(count: Int, label: String?, restore: @escaping () -> Void) {
        guard count > 0 else { return }
        show(Toast(
            message: Toast.hiddenMessage(count: count, label: label),
            undoTitle: "Show",
            undo: restore
        ))
    }

    /// A label came off with one press of its chip.
    func offerUndoForLabelRemoval(_ label: String, restore: @escaping () -> Void) {
        show(Toast(message: Toast.labelRemovedMessage(label: label), now: clock.now(), undo: restore))
    }

    /// A close was refused because the text could not be saved.
    func offerRetryAfterRefusedClose(_ retry: @escaping () -> Void) {
        show(Toast(
            message: "Couldn't save — note kept open",
            undoTitle: "Retry",
            now: clock.now(),
            undo: retry
        ))
    }

    /// Text typed into a note that vanished was kept; say where.
    func tellRecoveredCopy(in place: String) {
        show(Toast(notice: "Note disappeared — recovered copy in \(place)", now: clock.now()))
    }

    /// The note was deleted from under the window; its text went to the trash.
    func tellDeletedElsewhere() {
        show(Toast(notice: "Note was deleted — your typing is in Trash", now: clock.now()))
    }

    /// An untouched note was swept up when focus left it. Say so, and offer it back.
    func offerUndoForEmptyNoteRemoval(restore: @escaping () -> Void) {
        show(Toast(message: "Empty note removed", now: clock.now(), undo: restore))
    }

    /// What a switch of storage carried over. One message, nothing to undo.
    func tellStorageMoved(_ report: StorageSwitchReport) {
        guard let message = Toast.storageMovedMessage(report) else { return }
        show(Toast(notice: message, now: clock.now()))
    }

    /// Whether a toast is waiting for an answer.
    var hasPendingOffer: Bool { toasts.visibleToast != nil }

    func dismiss() {
        toasts.dismiss()
    }

    /// ⌘Z with an undo toast on screen undoes that action, until the person
    /// types: then it is the typing they mean. Routed through the main menu so
    /// it works no matter which of our windows has focus.
    @objc func undoLastAction(_ sender: Any?) {
        if let toast = toasts.visibleToast, toast.takesUndoShortcut, !textEditedSinceOffer {
            toasts.performUndo()
            return
        }
        // Nothing for ⌘Z to take — let the focused text view handle its own undo.
        NSApp.sendAction(Selector(("undo:")), to: nil, from: sender)
    }
}
