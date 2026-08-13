import AppKit

final class NoteWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Don't let AppKit auto-fit the window when the display configuration
    /// changes (e.g. an external monitor is plugged in). The default
    /// implementation can resize a borderless+resizable window — including
    /// snapping it to the new screen's full width — which trashes the
    /// user-chosen size of a collapsed sticky note.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    /// Clamp a saved frame into the visible region of whichever screen it
     /// overlaps most, so a note saved next to an external display still has
     /// its drag zone reachable when the app reopens with that display gone.
    static func clampToVisibleScreen(_ rect: NSRect) -> NSRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return rect }
        func area(_ r: NSRect) -> CGFloat { max(0, r.width) * max(0, r.height) }
        let best = screens.max(by: { area($0.visibleFrame.intersection(rect)) < area($1.visibleFrame.intersection(rect)) })
            ?? NSScreen.main ?? screens[0]
        let v = best.visibleFrame
        var r = rect
        r.size.width = min(r.size.width, v.size.width)
        r.size.height = min(r.size.height, v.size.height)
        r.origin.x = min(max(r.origin.x, v.minX), v.maxX - r.size.width)
        r.origin.y = min(max(r.origin.y, v.minY), v.maxY - r.size.height)
        return r
    }

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
        // Undo goes to the app delegate first so a pending undo toast wins;
        // it falls back to the text view's own undo when there isn't one.
        case "z": selector = shift ? Selector(("redo:")) : Selector(("undoLastAction:"))
        default: selector = nil
        }

        guard let selector = selector else { return false }
        return NSApp.sendAction(selector, to: nil, from: self)
    }
}
