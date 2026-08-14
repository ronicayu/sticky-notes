import AppKit

/// Whether the app is currently drawing in dark mode, and a way to be told
/// when that changes.
///
/// Note windows are borderless and paint their own paper color, so AppKit's
/// automatic appearance handling doesn't reach them — every color has to be
/// re-derived by hand when the system flips.
enum Appearance {
    /// Posted after the system appearance changes, once `isDark` already
    /// reflects the new value.
    static let didChange = Notification.Name("Appearance.didChange")

    static var isDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Start watching for appearance changes. Safe to call more than once.
    static func startObserving() {
        guard observer == nil else { return }
        observer = NSApp?.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            // The observation fires while AppKit is mid-update; let it settle
            // so `isDark` and any colors read from it agree.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Appearance.didChange, object: nil)
            }
        }
    }

    /// Ink for the chrome buttons drawn on a note's paper. Dark papers need
    /// light ink; a fixed black tint is invisible on them.
    static var chromeInk: NSColor {
        (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.55)
    }

    /// Quieter ink, for supporting text like the footer date and label chips.
    static var secondaryInk: NSColor {
        (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.40)
    }

    /// A wash that reads as a raised chip on either paper.
    static var chipFill: NSColor {
        (isDark ? NSColor.white : NSColor.black).withAlphaComponent(isDark ? 0.13 : 0.08)
    }

    static var chipInk: NSColor {
        (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.65)
    }

    /// True when the user has asked for less animation. Fades still happen —
    /// they just happen instantly, which is what Reduce Motion asks for.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Duration for a decorative fade, respecting Reduce Motion.
    static func animationDuration(_ preferred: TimeInterval) -> TimeInterval {
        reduceMotion ? 0 : preferred
    }

    /// Notes fade when they lose focus. Under Reduce Transparency that reads
    /// as a rendering bug, so stay fully opaque instead.
    static var allowsFadedNotes: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    private static var observer: NSKeyValueObservation?
}

extension NSColor {
    /// Resolve a hex string against the current appearance. Kept here so the
    /// call sites read as "the color for this note" rather than as a branch.
    static func note(_ hex: String) -> NSColor? { NSColor(hex: hex) }
}
