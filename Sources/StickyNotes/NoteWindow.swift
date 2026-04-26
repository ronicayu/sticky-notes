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
}
