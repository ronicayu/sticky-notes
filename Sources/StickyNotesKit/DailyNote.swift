import Foundation

/// Per-machine UI state for the singleton daily-note window. Lives in
/// Application Support: it describes this Mac's screen, so syncing it with
/// the vault only let two machines fight over one window position.
struct DailyNoteState: Codable {
    var positionX: Double
    var positionY: Double
    var width: Double
    var height: Double
    var colorRaw: String
    var visible: Bool
    var collapsed: Bool

    var color: NoteColor {
        get { NoteColor(rawValue: colorRaw) ?? .yellow }
        set { colorRaw = newValue.rawValue }
    }

    init(
        positionX: Double,
        positionY: Double,
        width: Double,
        height: Double,
        colorRaw: String,
        visible: Bool,
        collapsed: Bool
    ) {
        self.positionX = positionX
        self.positionY = positionY
        self.width = width
        self.height = height
        self.colorRaw = colorRaw
        self.visible = visible
        self.collapsed = collapsed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        positionX = try c.decode(Double.self, forKey: .positionX)
        positionY = try c.decode(Double.self, forKey: .positionY)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        colorRaw = try c.decode(String.self, forKey: .colorRaw)
        visible = (try? c.decode(Bool.self, forKey: .visible)) ?? false
        collapsed = (try? c.decode(Bool.self, forKey: .collapsed)) ?? false
    }

    static var defaultState: DailyNoteState {
        DailyNoteState(
            positionX: 220,
            positionY: 220,
            width: 340,
            height: 380,
            colorRaw: NoteColor.yellow.rawValue,
            visible: false,
            collapsed: false
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

    /// Window geometry and visibility are per-machine, so they belong in
    /// Application Support rather than in the vault. Sharing one file over
    /// iCloud meant hiding the note on one Mac hid it on the other, and each
    /// machine's window position kept overwriting the other's.
    static var stateURL: URL? {
        Settings.localRootURL
            .appendingPathComponent("StickyNotes", isDirectory: true)
            .appendingPathComponent("_daily.json")
    }

    /// Where the state used to live. Read once, to carry a user's existing
    /// window position over instead of resetting it.
    private static var legacyStateURL: URL? {
        guard let vault = Settings.shared.obsidianVaultPath else { return nil }
        return URL(fileURLWithPath: vault, isDirectory: true)
            .appendingPathComponent("StickyNotes/_daily.json")
    }

    static func loadState() -> DailyNoteState {
        if let url = stateURL,
           let data = try? Data(contentsOf: url),
           let state = try? JSONDecoder().decode(DailyNoteState.self, from: data) {
            return state
        }
        if let legacy = legacyStateURL,
           let data = try? Data(contentsOf: legacy),
           let state = try? JSONDecoder().decode(DailyNoteState.self, from: data) {
            saveState(state)
            // Only drop the old copy once the new one is definitely written,
            // or a failed save would lose the window's position outright.
            if let new = stateURL, FileManager.default.fileExists(atPath: new.path) {
                try? FileManager.default.removeItem(at: legacy)
            }
            return state
        }
        return DailyNoteState.defaultState
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

    // MARK: - Duplicate healing

    /// iCloud's name for a losing copy: `2026-08-26 2.md` sitting beside
    /// `2026-08-26.md`. This is *not* an `NSFileVersion` conflict — the two
    /// files were created independently on two Macs, so iCloud never links
    /// them as versions of one document — which is why `NoteStore`'s
    /// conflict sweep can't see it and it needs healing by name.
    private static let duplicateSuffix = try? NSRegularExpression(pattern: #"^(.+) (\d+)$"#)

    /// Fold iCloud's numbered duplicates back into the notes they were
    /// copied from, for every `.md` in `directory`.
    ///
    /// A file only counts as a duplicate when the note it shadows sits right
    /// beside it, so one the user deliberately named "Groceries 2" is left
    /// alone unless "Groceries" is there too. Nothing is discarded: the
    /// duplicate's text is merged in first, and the file itself goes to the
    /// Trash rather than being deleted, so a wrong guess is recoverable.
    ///
    /// Returns how many duplicates were folded in.
    @discardableResult
    static func healDuplicates(
        in directory: URL,
        now: Date = Date(),
        dispose: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var healed = 0

        // Sorted so "note 2" merges before "note 3": each one lands on top of
        // the previous merge instead of racing it.
        for name in names.sorted() {
            let duplicate = directory.appendingPathComponent(name)
            guard duplicate.pathExtension.lowercased() == "md",
                  let base = duplicateBase(of: duplicate.deletingPathExtension().lastPathComponent)
            else { continue }

            let original = directory
                .appendingPathComponent(base)
                .appendingPathExtension(duplicate.pathExtension)
            guard fm.fileExists(atPath: original.path),
                  let duplicateBody = try? String(contentsOf: duplicate, encoding: .utf8),
                  let originalBody = try? String(contentsOf: original, encoding: .utf8)
            else { continue }

            let merged = ConflictResolver.mergeBodies(
                local: originalBody,
                external: duplicateBody,
                externalDate: modificationDate(of: duplicate) ?? now,
                now: now
            )
            if merged != originalBody {
                // A failed write means the duplicate is still the only copy
                // of its text, so leave it where it is.
                do { try merged.write(to: original, atomically: true, encoding: .utf8) }
                catch { continue }
            }
            do { try dispose(duplicate) } catch { continue }
            healed += 1
        }
        return healed
    }

    /// `"2026-08-26 2"` -> `"2026-08-26"`. Nil when the name isn't one of
    /// iCloud's numbered copies.
    static func duplicateBase(of name: String) -> String? {
        guard let regex = duplicateSuffix else { return nil }
        let ns = name as NSString
        guard let match = regex.firstMatch(
            in: name, options: [], range: NSRange(location: 0, length: ns.length)
        ) else { return nil }

        let base = ns.substring(with: match.range(at: 1))
        // iCloud starts at 2 — "note 1" is a name somebody chose.
        guard let index = Int(ns.substring(with: match.range(at: 2))), index >= 2 else { return nil }
        return base.isEmpty ? nil : base
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
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
