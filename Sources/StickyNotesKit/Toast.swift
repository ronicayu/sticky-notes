import AppKit

/// A dismissible message with one undo action.
///
/// Kept separate from the window so the wording, expiry, and replacement
/// rules can be tested without a screen.
struct Toast {
    let message: String
    let undoTitle: String
    let expiry: Date
    let undo: () -> Void

    /// How long a toast stays up. Long enough to notice and react to, short
    /// enough not to become furniture.
    static let lifetime: TimeInterval = 6

    init(message: String, undoTitle: String = "Undo", now: Date = Date(), undo: @escaping () -> Void) {
        self.message = message
        self.undoTitle = undoTitle
        self.expiry = now.addingTimeInterval(Toast.lifetime)
        self.undo = undo
    }

    func hasExpired(at now: Date) -> Bool { now >= expiry }

    /// Phrasing for "you just archived something". Named notes read better
    /// than a count, but an untitled note has no name to use.
    static func archivedMessage(noteName: String) -> String {
        let trimmed = noteName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Note archived" : "Archived “\(shorten(trimmed))”"
    }

    static func hiddenMessage(count: Int, label: String?) -> String {
        let noun = count == 1 ? "note" : "notes"
        if let label = label {
            return "Hid \(count) #\(label) \(noun)"
        }
        return "Hid \(count) \(noun)"
    }

    /// Keep a long first line from pushing the undo button off the toast.
    static func shorten(_ text: String, limit: Int = 34) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}

/// Single floating toast, bottom-center of the screen under the pointer.
///
/// Only one is ever on screen: a second action replaces the first, because a
/// stack of undo offers is noise and only the most recent one is the thing
/// the user is reacting to.
final class ToastController {
    private var panel: NSPanel?
    private var current: Toast?
    private var dismissWorkItem: DispatchWorkItem?

    private let messageLabel = NSTextField(labelWithString: "")
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)

    /// The toast currently showing, if any. Exposed so its undo can be fired
    /// from a keyboard shortcut as well as the button.
    var visibleToast: Toast? { current }

    func show(_ toast: Toast) {
        current = toast
        messageLabel.stringValue = toast.message
        undoButton.title = toast.undoTitle

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView?.layoutSubtreeIfNeeded()
        sizeAndPosition(panel)
        panel.orderFront(nil)

        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Toast.lifetime, execute: work)
    }

    /// Run the pending undo, if there is one. Returns false when there was
    /// nothing to undo, so a caller can pass the keystroke along.
    @discardableResult
    func performUndo() -> Bool {
        guard let toast = current else { return false }
        dismiss()
        toast.undo()
        return true
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        current = nil
        panel?.orderOut(nil)
    }

    // MARK: - Window

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        // Never steal focus — a toast interrupting typing would be worse than
        // the silence it replaces.
        panel.becomesKeyOnlyIfNeeded = true

        let background = NSVisualEffectView()
        background.translatesAutoresizingMaskIntoConstraints = false
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = NSFont.systemFont(ofSize: 12)
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        undoButton.translatesAutoresizingMaskIntoConstraints = false
        undoButton.bezelStyle = .rounded
        undoButton.controlSize = .small
        undoButton.target = self
        undoButton.action = #selector(undoTapped)
        undoButton.setContentHuggingPriority(.required, for: .horizontal)
        undoButton.setAccessibilityLabel("Undo the last action")

        background.addSubview(messageLabel)
        background.addSubview(undoButton)
        panel.contentView = background

        NSLayoutConstraint.activate([
            messageLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            messageLabel.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            undoButton.leadingAnchor.constraint(equalTo: messageLabel.trailingAnchor, constant: 12),
            undoButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            undoButton.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
        return panel
    }

    @objc private func undoTapped() {
        performUndo()
    }

    private func sizeAndPosition(_ panel: NSPanel) {
        let fitting = panel.contentView?.fittingSize ?? NSSize(width: 320, height: 44)
        let size = NSSize(width: max(260, min(fitting.width, 460)), height: max(40, fitting.height))

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            panel.setContentSize(size)
            panel.center()
            return
        }
        panel.setFrame(
            NSRect(
                x: visible.midX - size.width / 2,
                y: visible.minY + 28,
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }
}
