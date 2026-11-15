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

    /// How a note joins Spaces and full-screen apps. A floating note follows you
    /// to every Space and shows over a full-screen app, as the quick switcher does.
    /// A desktop note belongs to the desk it is on, so it does neither.
    static func collectionBehavior(for level: NoteFloatLevel) -> NSWindow.CollectionBehavior {
        switch level {
        case .floating: return [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        case .desktop: return [.stationary]
        }
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
        collectionBehavior = NoteWindow.collectionBehavior(for: .floating)
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
    }

    /// A borderless window may not offer key equivalents to `NSApp.mainMenu`
    /// itself, so offer them here. The Edit, Note and View menus carry every
    /// shortcut a note answers; the text view's own ⌘B / ⌘I / ⌘E / ⌘↩ are tried
    /// first, through `super`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }
}
