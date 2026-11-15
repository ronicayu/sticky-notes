import AppKit

/// What VoiceOver says for a row of the notes panel or the quick switcher: the
/// heading and the rest of the row as one sentence, instead of every text field
/// in it on its own.
enum NoteRowAccessibility {
    static func label(
        heading: String, progress: (done: Int, total: Int)?, detail: String, trailing: String
    ) -> String {
        var parts = [heading.isEmpty ? "Empty note" : heading]
        if let progress = progress { parts.append("\(progress.done) of \(progress.total) tasks done") }
        for extra in [detail, trailing] where !extra.isEmpty { parts.append(extra) }
        return parts.joined(separator: ", ")
    }

    /// Make `cell` one element that reads `label`, with its text fields hidden
    /// from VoiceOver so nothing is read twice.
    @MainActor
    static func apply(
        to cell: NSView, heading: String, progress: (done: Int, total: Int)?, detail: String, trailing: String
    ) {
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.cell)
        cell.setAccessibilityChildren([])
        cell.setAccessibilityLabel(label(heading: heading, progress: progress, detail: detail, trailing: trailing))
    }
}
