import Foundation

final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let useICloud = "useICloud"
        static let launchAtLogin = "launchAtLogin"
        static let obsidianVaultPath = "obsidianVaultPath"
        static let defaultNoteColor = "defaultNoteColor"
        static let dailyNotesPattern = "dailyNotesPattern"
        static let dailyTemplatePath = "dailyTemplatePath"
    }

    private init() {}

    var useICloud: Bool {
        get { defaults.bool(forKey: Keys.useICloud) }
        set { defaults.set(newValue, forKey: Keys.useICloud) }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set { defaults.set(newValue, forKey: Keys.launchAtLogin) }
    }

    /// Absolute filesystem path of the Obsidian vault root. When set, notes
    /// are written as `.md` files into `<vault>/StickyNotes/`. Takes priority
    /// over `useICloud`.
    var obsidianVaultPath: String? {
        get {
            let v = defaults.string(forKey: Keys.obsidianVaultPath)
            return (v?.isEmpty ?? true) ? nil : v
        }
        set { defaults.set(newValue, forKey: Keys.obsidianVaultPath) }
    }

    /// Path template (relative to the vault root) for the Obsidian daily
    /// note. Supports `{YYYY}` `{YY}` `{MM}` `{M}` `{DD}` `{D}` `{dddd}`
    /// `{ddd}` tokens — e.g. `Daily/{YYYY}-{MM}-{DD}.md`. Empty / nil means
    /// the daily-note feature is disabled.
    var dailyNotesPattern: String? {
        get {
            let v = defaults.string(forKey: Keys.dailyNotesPattern)
            return (v?.isEmpty ?? true) ? nil : v
        }
        set { defaults.set(newValue, forKey: Keys.dailyNotesPattern) }
    }

    /// Absolute or vault-relative path of the Obsidian template file used
    /// when the daily note for today doesn't exist yet. Token expansion
    /// (`{{date}}`, `{{date:FMT}}`, `{{time}}`, `{{title}}`, `{{yesterday}}`,
    /// `{{tomorrow}}`) is applied to the template body before writing.
    var dailyTemplatePath: String? {
        get {
            let v = defaults.string(forKey: Keys.dailyTemplatePath)
            return (v?.isEmpty ?? true) ? nil : v
        }
        set { defaults.set(newValue, forKey: Keys.dailyTemplatePath) }
    }

    /// Color applied to a newly-created note. Defaults to yellow.
    var defaultNoteColor: NoteColor {
        get {
            guard let raw = defaults.string(forKey: Keys.defaultNoteColor),
                  let color = NoteColor(rawValue: raw) else { return .yellow }
            return color
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.defaultNoteColor) }
    }

    static var iCloudAvailable: Bool {
        guard let url = iCloudRootURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static var iCloudRootURL: URL? {
        let fm = FileManager.default
        guard let home = fm.homeDirectoryForCurrentUser as URL? else { return nil }
        return home
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    static var localRootURL: URL {
        let fm = FileManager.default
        return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var preferredStorageRoot: URL {
        if let vault = shared.obsidianVaultPath {
            return URL(fileURLWithPath: vault, isDirectory: true)
                .appendingPathComponent("StickyNotes", isDirectory: true)
        }
        if shared.useICloud, let icloud = iCloudRootURL, FileManager.default.fileExists(atPath: icloud.path) {
            return icloud.appendingPathComponent("StickyNotes", isDirectory: true)
        }
        return localRootURL.appendingPathComponent("StickyNotes", isDirectory: true)
    }

    static var preferredFormat: StorageFormat {
        shared.obsidianVaultPath != nil ? .markdown : .json
    }
}
