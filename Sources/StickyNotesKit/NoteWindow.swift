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

    /// Bring a saved frame onto a screen when no screen lets the person take hold
    /// of it: a note left next to an external display that is gone must have its
    /// drag zone reachable when the app reopens. A frame the person can still
    /// grab stays as it is, even when it hangs over the edge of a screen or lies
    /// across two of them.
    static func clampToVisibleScreen(_ rect: NSRect) -> NSRect {
        fit(rect, into: NSScreen.screens.map(\.visibleFrame))
    }

    /// `clampToVisibleScreen` for the given visible frames, one per screen.
    static func fit(_ rect: NSRect, into screens: [NSRect]) -> NSRect {
        isGrabbable(rect, on: screens) ? rect : clamp(rect, into: screens)
    }

    /// Whether the top strip of a note, the part that drags it, lies on a screen
    /// in full height and wide enough to take hold of, and the note is not larger
    /// than that screen, whose edge would hide its far corner.
    static func isGrabbable(_ rect: NSRect, on screens: [NSRect]) -> Bool {
        let strip = min(rect.height, NoteWindowController.collapsedHeight)
        let drag = NSRect(x: rect.minX, y: rect.maxY - strip, width: rect.width, height: strip)
        let wide = min(rect.width, minimumGrabWidth)
        return screens.contains { screen in
            let shown = screen.intersection(drag)
            return shown.height >= strip - 0.5 && shown.width >= wide - 0.5
                && rect.width <= screen.width + 0.5 && rect.height <= screen.height + 0.5
        }
    }

    private static let minimumGrabWidth: CGFloat = 80

    /// Move a frame wholly onto the screen it overlaps most, shrinking it to fit.
    static func clamp(_ rect: NSRect, into screens: [NSRect]) -> NSRect {
        func area(_ r: NSRect) -> CGFloat { max(0, r.width) * max(0, r.height) }
        guard let v = screens.max(by: { area($0.intersection(rect)) < area($1.intersection(rect)) }) else { return rect }
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
