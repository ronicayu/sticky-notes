import CoreGraphics
import Foundation

/// Every user preference, over an injected `UserDefaults` so a test can use a
/// throwaway suite. The two folder roots are injected too: they are where this
/// machine keeps per-Mac files and where iCloud Drive lives, and a test must
/// never reach the real ones.
final class Settings {
    let defaults: UserDefaults
    let localRootURL: URL
    let iCloudRootURL: URL?

    init(
        defaults: UserDefaults,
        localRootURL: URL = Settings.systemLocalRootURL,
        iCloudRootURL: URL? = Settings.systemICloudRootURL
    ) {
        self.defaults = defaults
        self.localRootURL = localRootURL
        self.iCloudRootURL = iCloudRootURL
    }

    private enum Keys {
        static let useICloud = "useICloud"
        static let launchAtLogin = "launchAtLogin"
        static let obsidianVaultPath = "obsidianVaultPath"
        static let defaultNoteColor = "defaultNoteColor"
        static let dailyNotesPattern = "dailyNotesPattern"
        static let dailyTemplatePath = "dailyTemplatePath"
        static let hiddenLabels = "hiddenLabels"
        static let bodyFontSize = "bodyFontSize"
    }

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

    /// Labels whose note windows are kept off screen, so you can put `#work`
    /// away in the evening without archiving anything. Stored normalized.
    var hiddenLabels: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.hiddenLabels) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Keys.hiddenLabels) }
    }

    /// Whether a note should currently be on screen. A note is hidden when any
    /// of its labels is hidden — the narrower intent wins, so hiding `#work`
    /// puts away a note tagged both `#work` and `#home`.
    func isHiddenByLabel(_ note: Note) -> Bool {
        let hidden = hiddenLabels
        guard !hidden.isEmpty else { return false }
        return note.labels.contains { hidden.contains($0) }
    }

    /// Body text size, shared by every note. The one preference here that
    /// earns its place: reading comfort is an accessibility need, and the
    /// ⌘+ / ⌘- convention already exists on the platform.
    var bodyFontSize: CGFloat {
        get {
            let stored = defaults.double(forKey: Keys.bodyFontSize)
            guard stored > 0 else { return Settings.defaultBodyFontSize }
            return Settings.clampFontSize(CGFloat(stored))
        }
        set { defaults.set(Double(Settings.clampFontSize(newValue)), forKey: Keys.bodyFontSize) }
    }

    static let defaultBodyFontSize: CGFloat = 13
    static let minBodyFontSize: CGFloat = 11
    static let maxBodyFontSize: CGFloat = 18

    static func clampFontSize(_ size: CGFloat) -> CGFloat {
        min(max(size, minBodyFontSize), maxBodyFontSize)
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

    static var systemICloudRootURL: URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    static var systemLocalRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    var iCloudAvailable: Bool {
        guard let url = iCloudRootURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Where notes live in the local, non-synced mode.
    var localStorageRoot: URL {
        localRootURL.appendingPathComponent("StickyNotes", isDirectory: true)
    }

    /// Where this Mac keeps the files that are its own and must not sync: the
    /// local storage folder, which only this app uses. The store reads only the
    /// `notes`, `archive`, `.trash` and `attachments` folders under a root, never
    /// the files beside them, and a vault or iCloud root is a different folder, so
    /// nothing here reaches another Mac.
    var machineFilesFolder: URL { localStorageRoot }

    /// Where this Mac keeps the layout of its note windows.
    var layoutURL: URL {
        machineFilesFolder.appendingPathComponent("layout.json")
    }

    /// Where this Mac keeps what it wrote to each note file, so that an older copy
    /// of its own text that turns up after a relaunch is still recognised.
    var writeLineageURL: URL {
        machineFilesFolder.appendingPathComponent("write-lineage.json")
    }

    /// Where a storage switch remembers what each root held when it was left.
    var switchRecordsURL: URL {
        machineFilesFolder.appendingPathComponent("storage-switch-records.json")
    }

    /// An earlier build wrote the two machine files straight into the Application
    /// Support folder that every app shares. Move each one into the app's own
    /// folder, once, if it is ours (it reads as this app's format); anything else
    /// found there is left alone.
    func migrateMachineFiles() {
        let fm = FileManager.default
        func move(_ name: String, to destination: URL, isOurs: (Data) -> Bool) {
            let old = localRootURL.appendingPathComponent(name)
            guard !fm.fileExists(atPath: destination.path), let data = try? Data(contentsOf: old), isOurs(data) else { return }
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? data.write(to: destination, options: .atomic)) != nil else { return }
            try? fm.removeItem(at: old)
        }
        move("layout.json", to: layoutURL, isOurs: DeviceLayoutStore.isLayoutFile)
        move("storage-switch-records.json", to: switchRecordsURL) {
            (try? JSONDecoder().decode([String: [String: String]].self, from: $0)) != nil
        }
    }

    var preferredStorageRoot: URL {
        if let vault = obsidianVaultPath {
            return URL(fileURLWithPath: vault, isDirectory: true)
                .appendingPathComponent("StickyNotes", isDirectory: true)
        }
        if useICloud, let icloud = iCloudRootURL, FileManager.default.fileExists(atPath: icloud.path) {
            return icloud.appendingPathComponent("StickyNotes", isDirectory: true)
        }
        return localStorageRoot
    }
}
