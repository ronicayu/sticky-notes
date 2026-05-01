import Foundation

/// Per-machine UI state for the singleton daily-note window. Lives in a
/// sidecar JSON next to the notes folder so it rides the same iCloud /
/// vault transport as the rest of the app's storage.
struct DailyNoteState: Codable {
    var positionX: Double
    var positionY: Double
    var width: Double
    var height: Double
    var colorRaw: String
    var visible: Bool

    var color: NoteColor {
        get { NoteColor(rawValue: colorRaw) ?? .yellow }
        set { colorRaw = newValue.rawValue }
    }

    static var defaultState: DailyNoteState {
        DailyNoteState(
            positionX: 220,
            positionY: 220,
            width: 340,
            height: 380,
            colorRaw: NoteColor.yellow.rawValue,
            visible: false
        )
    }
}

enum DailyNote {
    /// Expand `{YYYY}/{MM}/{DD}` style tokens in `pattern`. Unknown tokens
    /// pass through unchanged. Centralized so the menu-bar preview, the
    /// resolver, and the controller all agree on the encoding.
    static func render(_ pattern: String, date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let year = comps.year ?? 0
        let month = comps.month ?? 0
        let day = comps.day ?? 0

        let yyyy = String(format: "%04d", year)
        let yy = String(format: "%02d", year % 100)
        let mm = String(format: "%02d", month)
        let m = String(month)
        let dd = String(format: "%02d", day)
        let d = String(day)

        let weekdayIdx = (comps.weekday ?? 1) - 1
        let dddd: String = {
            let symbols = calendar.weekdaySymbols
            return symbols.indices.contains(weekdayIdx) ? symbols[weekdayIdx] : ""
        }()
        let ddd: String = {
            let symbols = calendar.shortWeekdaySymbols
            return symbols.indices.contains(weekdayIdx) ? symbols[weekdayIdx] : ""
        }()

        var out = pattern
        // Replace longer tokens first so `{YY}` doesn't eat half of `{YYYY}`.
        let replacements: [(String, String)] = [
            ("{YYYY}", yyyy),
            ("{YY}", yy),
            ("{MM}", mm),
            ("{M}", m),
            ("{DD}", dd),
            ("{D}", d),
            ("{dddd}", dddd),
            ("{ddd}", ddd)
        ]
        for (token, value) in replacements {
            out = out.replacingOccurrences(of: token, with: value)
        }
        return out
    }

    /// Absolute path of the daily note for `date`. Returns nil if the vault
    /// or pattern isn't configured.
    static func resolvedURL(for date: Date = Date()) -> URL? {
        guard let vault = Settings.shared.obsidianVaultPath,
              let pattern = Settings.shared.dailyNotesPattern,
              !pattern.isEmpty else { return nil }
        let rendered = render(pattern, date: date)
        guard !rendered.isEmpty else { return nil }
        return URL(fileURLWithPath: vault, isDirectory: true)
            .appendingPathComponent(rendered)
    }

    static var stateURL: URL? {
        guard let vault = Settings.shared.obsidianVaultPath else { return nil }
        return URL(fileURLWithPath: vault, isDirectory: true)
            .appendingPathComponent("StickyNotes/_daily.json")
    }

    static func loadState() -> DailyNoteState {
        guard let url = stateURL,
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(DailyNoteState.self, from: data) else {
            return DailyNoteState.defaultState
        }
        return state
    }

    static func saveState(_ state: DailyNoteState) {
        guard let url = stateURL else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
