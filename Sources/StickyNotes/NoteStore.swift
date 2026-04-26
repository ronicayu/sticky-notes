import Foundation

final class NoteStore {
    static let didChange = Notification.Name("NoteStore.didChange")

    private(set) var rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    var activeURL: URL { rootURL.appendingPathComponent("notes", isDirectory: true) }
    var archiveURL: URL { rootURL.appendingPathComponent("archive", isDirectory: true) }

    init(rootURL: URL = Settings.preferredStorageRoot) {
        self.rootURL = rootURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        ensureDirectories()
    }

    func save(_ note: Note) {
        let url = activeURL.appendingPathComponent("\(note.id.uuidString).json")
        write(note, to: url)
        notifyChange()
    }

    func loadActive() -> [Note] {
        loadAll(from: activeURL)
    }

    func loadArchived() -> [Note] {
        loadAll(from: archiveURL).sorted { $0.updatedAt > $1.updatedAt }
    }

    func archive(_ note: Note) {
        let from = activeURL.appendingPathComponent("\(note.id.uuidString).json")
        let to = archiveURL.appendingPathComponent("\(note.id.uuidString).json")
        moveFile(from: from, to: to)
        notifyChange()
    }

    func discardActive(_ note: Note) {
        let url = activeURL.appendingPathComponent("\(note.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        notifyChange()
    }

    func restore(_ note: Note) {
        let from = archiveURL.appendingPathComponent("\(note.id.uuidString).json")
        let to = activeURL.appendingPathComponent("\(note.id.uuidString).json")
        moveFile(from: from, to: to)

        // Force-expand on restore so the content is immediately visible.
        if let data = try? Data(contentsOf: to),
           var restored = try? decoder.decode(Note.self, from: data),
           restored.collapsed {
            restored.collapsed = false
            write(restored, to: to)
        }
        notifyChange()
    }

    func deleteForever(_ note: Note) {
        let url = archiveURL.appendingPathComponent("\(note.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        notifyChange()
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: NoteStore.didChange, object: self)
    }

    /// Move all notes/ and archive/ files from current rootURL to a new location, then update rootURL.
    /// Returns true on success.
    @discardableResult
    func relocate(to newRoot: URL) -> Bool {
        let fm = FileManager.default
        let oldRoot = rootURL
        if oldRoot == newRoot { return true }

        let newActive = newRoot.appendingPathComponent("notes", isDirectory: true)
        let newArchive = newRoot.appendingPathComponent("archive", isDirectory: true)
        try? fm.createDirectory(at: newActive, withIntermediateDirectories: true)
        try? fm.createDirectory(at: newArchive, withIntermediateDirectories: true)

        moveAllFiles(from: activeURL, to: newActive)
        moveAllFiles(from: archiveURL, to: newArchive)

        rootURL = newRoot
        ensureDirectories()
        return true
    }

    private func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: activeURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: archiveURL, withIntermediateDirectories: true)
    }

    private func loadAll(from dir: URL) -> [Note] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.compactMap { url -> Note? in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(Note.self, from: data)
        }
    }

    private func write(_ note: Note, to url: URL) {
        guard let data = try? encoder.encode(note) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func moveFile(from: URL, to: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: to)
        try? fm.moveItem(at: from, to: to)
    }

    private func moveAllFiles(from src: URL, to dst: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            let target = dst.appendingPathComponent(file.lastPathComponent)
            try? fm.removeItem(at: target)
            try? fm.moveItem(at: file, to: target)
        }
    }
}
