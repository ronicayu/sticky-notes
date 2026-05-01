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

    // MARK: - Template

    /// Resolve the template file. Accepts either an absolute path or a
    /// vault-relative path (with or without a `.md` suffix), matching how
    /// Obsidian itself stores `template` in `daily-notes.json`.
    static func resolvedTemplateURL() -> URL? {
        guard let raw = Settings.shared.dailyTemplatePath, !raw.isEmpty else { return nil }
        let fm = FileManager.default

        if raw.hasPrefix("/") {
            let direct = URL(fileURLWithPath: raw)
            if fm.fileExists(atPath: direct.path) { return direct }
        }
        guard let vault = Settings.shared.obsidianVaultPath else { return nil }
        let vaultURL = URL(fileURLWithPath: vault, isDirectory: true)
        let candidates = [raw, raw + ".md"]
        for candidate in candidates {
            let url = vaultURL.appendingPathComponent(candidate)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Load the template body for `date`, expanding the supported subset of
    /// Obsidian Daily Notes / Templates tokens. Returns nil when no template
    /// is configured or the file can't be read.
    static func renderedTemplate(for date: Date, fileURL: URL) -> String? {
        guard let templateURL = resolvedTemplateURL(),
              let raw = try? String(contentsOf: templateURL, encoding: .utf8) else { return nil }
        return expandTokens(in: raw, for: date, fileURL: fileURL)
    }

    /// Expand `{{date}}`, `{{date:FMT}}`, `{{time}}`, `{{time:FMT}}`,
    /// `{{title}}`, `{{yesterday}}`, `{{yesterday:FMT}}`, `{{tomorrow}}`,
    /// `{{tomorrow:FMT}}`. Whitespace and case are tolerated inside the
    /// braces (`{{ Date : YYYY-MM-DD }}` works). Unknown tokens pass
    /// through so the user can spot them and fix the template.
    static func expandTokens(in template: String, for date: Date, fileURL: URL) -> String {
        let regex = try? NSRegularExpression(pattern: #"\{\{\s*([^{}]*?)\s*\}\}"#)
        guard let regex = regex else { return template }
        let ns = template as NSString
        let range = NSRange(location: 0, length: ns.length)

        var matches = regex.matches(in: template, options: [], range: range)
        matches.reverse()  // splice from the back so earlier ranges stay valid

        var out = template as NSString
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        let title = fileURL.deletingPathExtension().lastPathComponent

        for match in matches {
            let inner = ns.substring(with: match.range(at: 1))
            let replacement = expandSingleToken(inner, date: date, yesterday: yesterday, tomorrow: tomorrow, title: title)
            guard let replacement = replacement else { continue }
            out = out.replacingCharacters(in: match.range, with: replacement) as NSString
        }
        return out as String
    }

    private static func expandSingleToken(
        _ raw: String,
        date: Date,
        yesterday: Date,
        tomorrow: Date,
        title: String
    ) -> String? {
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        let arg = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil

        switch name {
        case "date":      return formatMoment(date, momentFormat: arg ?? "YYYY-MM-DD")
        case "time":      return formatMoment(date, momentFormat: arg ?? "HH:mm")
        case "yesterday": return formatMoment(yesterday, momentFormat: arg ?? "YYYY-MM-DD")
        case "tomorrow":  return formatMoment(tomorrow, momentFormat: arg ?? "YYYY-MM-DD")
        case "title":     return title
        default:          return nil
        }
    }

    private static func formatMoment(_ date: Date, momentFormat: String) -> String {
        let f = DateFormatter()
        f.locale = Locale.autoupdatingCurrent
        f.dateFormat = momentToICU(momentFormat)
        return f.string(from: date)
    }

    /// Translate a moment.js format string (used by Obsidian) to a Unicode
    /// TR35 pattern (used by Foundation's `DateFormatter`). Handles the
    /// tokens commonly found in Daily Notes templates; `[literal]` escapes
    /// pass through; bare letters that aren't recognized tokens get quoted
    /// so DateFormatter doesn't reinterpret them.
    static func momentToICU(_ pattern: String) -> String {
        // Order matters: longest match per letter family first.
        let mapping: [(String, String)] = [
            ("YYYY", "yyyy"), ("YY", "yy"),
            ("MMMM", "MMMM"), ("MMM", "MMM"), ("MM", "MM"), ("M", "M"),
            ("DDDD", "DDD"),  ("DDD", "DDD"),  // day-of-year (rare)
            ("DD", "dd"),     ("Do", "d"),     ("D", "d"),
            ("dddd", "EEEE"), ("ddd", "EEE"),  ("dd", "EE"), ("d", "e"),
            ("HH", "HH"),     ("H", "H"),
            ("hh", "hh"),     ("h", "h"),
            ("mm", "mm"),     ("m", "m"),
            ("ss", "ss"),     ("s", "s"),
            ("A", "a"),       ("a", "a")
        ]

        var result = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let c = pattern[index]
            // Moment escape: `[literal text]` passes through unchanged.
            if c == "[" {
                if let close = pattern[index...].firstIndex(of: "]") {
                    let literal = pattern[pattern.index(after: index)..<close]
                    result += "'\(literal.replacingOccurrences(of: "'", with: "''"))'"
                    index = pattern.index(after: close)
                    continue
                }
            }

            var matched = false
            for (moment, icu) in mapping {
                let end = pattern.index(index, offsetBy: moment.count, limitedBy: pattern.endIndex)
                guard let end = end else { continue }
                if pattern[index..<end] == moment {
                    result += icu
                    index = end
                    matched = true
                    break
                }
            }
            if !matched {
                if c.isLetter {
                    // Quote stray letters so DateFormatter renders them as-is.
                    result += "'\(c)'"
                } else {
                    result.append(c)
                }
                index = pattern.index(after: index)
            }
        }
        return result
    }
}
