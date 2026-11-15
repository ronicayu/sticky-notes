import AppKit
import KeyboardShortcuts

/// Every way a note gets made from outside a window: the global hotkeys, the
/// clipboard, a Service from another app, a `stickynotes://` URL. All of them
/// end in the desk's `makeNote`.
final class CaptureCoordinator: NSObject {
    private let desk: DeskController
    private let store: NoteStore

    init(desk: DeskController, store: NoteStore) {
        self.desk = desk
        self.store = store
        super.init()
    }

    /// URL handling has to be registered before launch finishes, or a URL that
    /// launched the app is delivered before anyone is listening.
    func registerURLHandlerAndServices() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        NSApp.servicesProvider = self
    }

    func registerHotkeys() {
        KeyboardShortcuts.onKeyDown(for: .newNote) { [weak self] in
            self?.desk.newNote()
        }
        KeyboardShortcuts.onKeyDown(for: .notesPanel) { [weak self] in
            self?.desk.showNotesPanel()
        }
        KeyboardShortcuts.onKeyDown(for: .hideAll) { [weak self] in
            self?.desk.toggleHideAll()
        }
        KeyboardShortcuts.onKeyDown(for: .quickSwitcher) { [weak self] in
            self?.desk.toggleQuickSwitcher()
        }
        KeyboardShortcuts.onKeyDown(for: .newFromClipboard) { [weak self] in
            self?.newNoteFromClipboard()
        }
    }

    /// New note pre-filled from the clipboard. Pasted images and files are
    /// saved as attachments the same way an in-editor paste would.
    @objc func newNoteFromClipboard() {
        let pasteboard = NSPasteboard.general
        if let markdown = Attachments.handlePaste(pasteboard, for: store) {
            desk.makeNote(text: markdown)
            return
        }
        let text = pasteboard.string(forType: .string) ?? ""
        desk.makeNote(text: text)
    }

    // MARK: - Services

    /// Wired up by the `NSServices` entry in Info.plist, so any app's
    /// right-click menu can send a selection straight into a new note.
    @objc func makeNoteFromService(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            error?.pointee = "No text was selected." as NSString
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        desk.makeNote(text: text)
    }

    // MARK: - URL scheme

    /// Handles `stickynotes://` URLs. Registered in
    /// `applicationWillFinishLaunching`, which is early enough to catch a URL
    /// that launched the app.
    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string),
              let command = CaptureCommand.parse(url) else { return }
        perform(command)
    }

    func perform(_ command: CaptureCommand) {
        switch command {
        case let .new(title, text, color, labels):
            NSApp.activate(ignoringOtherApps: true)
            desk.makeNote(title: title, text: text, color: color, labels: labels)

        case let .search(query):
            desk.showQuickSwitcher(query: query)

        case .daily:
            NSApp.activate(ignoringOtherApps: true)
            desk.openTodaysDailyNote()
        }
    }
}
