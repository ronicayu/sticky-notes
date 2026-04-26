import Foundation

final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let useICloud = "useICloud"
        static let launchAtLogin = "launchAtLogin"
        static let obsidianVaultPath = "obsidianVaultPath"
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
