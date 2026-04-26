import AppKit

final class NoteWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        isMovableByWindowBackground = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
    }

    /// Borderless windows don't always route ⌘-modified key events through
    /// `NSApp.mainMenu`, so dispatch the standard text editing actions directly
    /// to the responder chain.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command) else { return false }

        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let shift = mods.contains(.shift)

        let selector: Selector?
        switch key {
        case "c": selector = Selector(("copy:"))
        case "x": selector = Selector(("cut:"))
        case "v": selector = shift ? Selector(("pasteAsPlainText:")) : Selector(("paste:"))
        case "a": selector = Selector(("selectAll:"))
        case "z": selector = shift ? Selector(("redo:")) : Selector(("undo:"))
        default: selector = nil
        }

        guard let selector = selector else { return false }
        return NSApp.sendAction(selector, to: nil, from: self)
    }
}
