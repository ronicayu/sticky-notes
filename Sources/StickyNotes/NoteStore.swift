import Foundation

enum StorageFormat {
    case json       // local Application Support / iCloud Drive (legacy)
    case markdown   // Obsidian vault — `.md` with YAML frontmatter
}

final class NoteStore {
    static let didChange = Notification.Name("NoteStore.didChange")

    private(set) var rootURL: URL
    private(set) var format: StorageFormat
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var watcher: FileWatcher?
    private let iso8601 = ISO8601DateFormatter()

    /// In Markdown mode the filename is creation-timestamp based (not derivable
    /// from the UUID), so we need an in-memory map to relocate files for
    /// archive/restore/delete. Populated by every load + save.
    private var markdownPathIndex: [UUID: URL] = [:]

    var activeURL: URL { rootURL.appendingPathComponent("notes", isDirectory: true) }
    var archiveURL: URL { rootURL.appendingPathComponent("archive", isDirectory: true) }

    private var fileExtension: String { format == .json ? "json" : "md" }

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    init(rootURL: URL = Settings.preferredStorageRoot, format: StorageFormat = Settings.preferredFormat) {
        self.rootURL = rootURL
        self.format = format
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        ensureDirectories()
        startWatching()
    }

    func save(_ note: Note) {
        let url = existingURL(for: note.id, in: activeURL) ?? generateURL(for: note, in: activeURL)
        write(note, to: url)
        markdownPathIndex[note.id] = url
        notifyChange()
    }

    func loadActive() -> [Note] {
        loadAll(from: activeURL)
    }

    func loadArchived() -> [Note] {
        loadAll(from: archiveURL).sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadNote(id: UUID, archived: Bool = false) -> Note? {
        let dir = archived ? archiveURL : activeURL
        guard let url = existingURL(for: id, in: dir) else { return nil }
        return read(url)
    }

    func archive(_ note: Note) {
        guard let from = existingURL(for: note.id, in: activeURL) else { return }
        let to = generateURL(for: note, in: archiveURL)
        moveFile(from: from, to: to)
        markdownPathIndex[note.id] = to
        notifyChange()
    }

    func discardActive(_ note: Note) {
        if let url = existingURL(for: note.id, in: activeURL) {
            try? FileManager.default.removeItem(at: url)
        }
        markdownPathIndex.removeValue(forKey: note.id)
        notifyChange()
    }

    func restore(_ note: Note) {
        guard let from = existingURL(for: note.id, in: archiveURL) else { return }
        let to = generateURL(for: note, in: activeURL)
        moveFile(from: from, to: to)
        markdownPathIndex[note.id] = to

        // Force-expand on restore so the content is immediately visible.
        if var restored = read(to), restored.collapsed {
            restored.collapsed = false
            write(restored, to: to)
        }
        notifyChange()
    }

    func deleteForever(_ note: Note) {
        if let url = existingURL(for: note.id, in: archiveURL) {
            try? FileManager.default.removeItem(at: url)
        }
        markdownPathIndex.removeValue(forKey: note.id)
        notifyChange()
    }

    /// Switch to a new root and/or format. Migrates all existing notes by
    /// re-writing them in the new location/format. Old files are left alone.
    @discardableResult
    func reconfigure(rootURL newRoot: URL, format newFormat: StorageFormat) -> Bool {
        let active = loadActive()
        let archived = loadArchived()

        watcher?.stop()
        rootURL = newRoot
        format = newFormat
        markdownPathIndex.removeAll()
        ensureDirectories()

        for note in active {
            let url = generateURL(for: note, in: activeURL)
            write(note, to: url)
            markdownPathIndex[note.id] = url
        }
        for note in archived {
            let url = generateURL(for: note, in: archiveURL)
            write(note, to: url)
            markdownPathIndex[note.id] = url
        }

        startWatching()
        notifyChange()
        return true
    }

    // MARK: - Internal

    private func notifyChange() {
        NotificationCenter.default.post(name: NoteStore.didChange, object: self)
    }

    private func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: activeURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: archiveURL, withIntermediateDirectories: true)
    }

    private func startWatching() {
        watcher = FileWatcher { [weak self] in
            self?.notifyChange()
        }
        watcher?.watch([activeURL, archiveURL])
    }

    /// Returns the on-disk URL for a note that already exists in the given
    /// directory, or nil if not found. JSON mode uses deterministic
    /// `<uuid>.json` paths; Markdown mode looks up the cached path and falls
    /// back to scanning the directory by frontmatter id.
    private func existingURL(for id: UUID, in dir: URL) -> URL? {
        switch format {
        case .json:
            let url = dir.appendingPathComponent("\(id.uuidString).json")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        case .markdown:
            if let cached = markdownPathIndex[id], cached.deletingLastPathComponent().path == dir.path,
               FileManager.default.fileExists(atPath: cached.path) {
                return cached
            }
            // Cold cache or stale entry: scan and rebuild for this dir.
            return scanForId(id, in: dir)
        }
    }

    /// Builds a fresh URL for a new save into the given directory.
    private func generateURL(for note: Note, in dir: URL) -> URL {
        switch format {
        case .json:
            return dir.appendingPathComponent("\(note.id.uuidString).json")
        case .markdown:
            let stamp = NoteStore.filenameFormatter.string(from: note.createdAt)
            let suffix = String(note.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased())
            let base = "\(stamp)-\(suffix)"
            return dir.appendingPathComponent("\(base).md")
        }
    }

    private func scanForId(_ id: UUID, in dir: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        for url in files where url.pathExtension == fileExtension {
            if let note = read(url), note.id == id {
                markdownPathIndex[id] = url
                return url
            }
        }
        return nil
    }

    private func loadAll(from dir: URL) -> [Note] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var notes: [Note] = []
        for url in files where url.pathExtension == fileExtension {
            guard let note = read(url) else { continue }
            if format == .markdown {
                markdownPathIndex[note.id] = url
            }
            notes.append(note)
        }
        return notes
    }

    private func read(_ url: URL) -> Note? {
        switch format {
        case .json:
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(Note.self, from: data)
        case .markdown:
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return parseMarkdown(raw, fallbackId: idFromFilename(url))
        }
    }

    private func write(_ note: Note, to url: URL) {
        switch format {
        case .json:
            guard let data = try? encoder.encode(note) else { return }
            try? data.write(to: url, options: .atomic)
        case .markdown:
            let raw = renderMarkdown(note)
            try? raw.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func moveFile(from: URL, to: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: to)
        try? fm.moveItem(at: from, to: to)
    }

    // MARK: - Markdown serialization

    private func renderMarkdown(_ note: Note) -> String {
        let frontmatter: [(String, String)] = [
            ("id", note.id.uuidString),
            ("color", note.color.rawValue),
            ("positionX", String(format: "%.2f", note.positionX)),
            ("positionY", String(format: "%.2f", note.positionY)),
            ("width", String(format: "%.2f", note.width)),
            ("height", String(format: "%.2f", note.height)),
            ("collapsed", note.collapsed ? "true" : "false"),
            ("created", iso8601.string(from: note.createdAt)),
            ("updated", iso8601.string(from: note.updatedAt))
        ]
        let document = MarkdownFile.Document(frontmatter: frontmatter, body: note.content)
        return MarkdownFile.serialize(document)
    }

    private func parseMarkdown(_ raw: String, fallbackId: UUID?) -> Note? {
        let doc = MarkdownFile.parse(raw)
        let id: UUID = doc.value(for: "id").flatMap(UUID.init(uuidString:)) ?? fallbackId ?? UUID()
        let color = doc.value(for: "color").flatMap(NoteColor.init(rawValue:)) ?? .yellow
        let positionX = Double(doc.value(for: "positionX") ?? "") ?? 200
        let positionY = Double(doc.value(for: "positionY") ?? "") ?? 200
        let width = Double(doc.value(for: "width") ?? "") ?? 240
        let height = Double(doc.value(for: "height") ?? "") ?? 200
        let collapsed = (doc.value(for: "collapsed") ?? "false") == "true"
        let createdAt = doc.value(for: "created").flatMap(iso8601.date(from:)) ?? Date()
        let updatedAt = doc.value(for: "updated").flatMap(iso8601.date(from:)) ?? createdAt
        return Note(
            id: id,
            content: doc.body,
            positionX: positionX,
            positionY: positionY,
            width: width,
            height: height,
            collapsed: collapsed,
            color: color,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func idFromFilename(_ url: URL) -> UUID? {
        UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }
}
