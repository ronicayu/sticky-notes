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

    private static var observer: NSKeyValueObservation?
}

extension NSColor {
    /// Resolve a hex string against the current appearance. Kept here so the
    /// call sites read as "the color for this note" rather than as a branch.
    static func note(_ hex: String) -> NSColor? { NSColor(hex: hex) }
}
