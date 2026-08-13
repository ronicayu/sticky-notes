import Foundation

enum StorageFormat {
    case json       // local Application Support / iCloud Drive (legacy)
    case markdown   // Obsidian vault — `.md` with YAML frontmatter
}

/// A write or move that failed twice. Surfaced to the user rather than
/// swallowed — a full disk or a revoked vault permission would otherwise look
/// exactly like a note that saved fine.
struct StorageFailure {
    let url: URL
    let error: Error
    let date: Date

    var fileName: String { url.lastPathComponent }
}

final class NoteStore {
    static let didChange = Notification.Name("NoteStore.didChange")

    /// Posted when `lastFailure` changes in either direction — a new failure,
    /// or a later write succeeding and clearing it.
    static let healthDidChange = Notification.Name("NoteStore.healthDidChange")

    /// The most recent unrecovered storage failure, or nil when writes are
    /// landing. Read by the menu bar to decide whether to show a warning.
    private(set) var lastFailure: StorageFailure?

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

    /// Ids we've seen on disk in this process. If a save() targets a known
    /// id whose active file has since vanished — an external agent or
    /// another machine deleted it — we bail instead of resurrecting it.
    /// Cleared in discardActive / deleteForever.
    private var knownIds = Set<UUID>()

    /// Decoded notes keyed by directory path. Without it every panel refresh,
    /// window reconcile, and `allLabels()` call re-reads and re-parses the
    /// whole tree — `allLabels()` alone read it twice.
    ///
    /// Dropped wholesale by `notifyChange()`, which runs for both our own
    /// writes and external ones. FSEvents reports changes per directory rather
    /// than per file, so a whole-tree rescan is the granularity we'd get
    /// anyway; the win is skipping the rescan while nothing is changing.
    ///
    /// Everything here is main-queue only: `FileWatcher` sets its FSEvents
    /// dispatch queue to main, so the invalidation and the reads that
    /// repopulate it can't interleave.
    private var cache: [String: [Note]] = [:]

    /// Directory paths whose `markdownPathIndex` entries are known to be
    /// complete, because we've read every file in them. Lets a lookup miss be
    /// trusted instead of triggering another full scan — without it, saving
    /// the Nth note in a vault re-reads the other N-1 looking for an id that
    /// isn't there. Dropped alongside `cache` whenever the tree changes
    /// underneath us.
    private var indexedDirs: Set<String> = []

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
        if knownIds.contains(note.id), existingURL(for: note.id, in: activeURL) == nil {
            // Seen before but no active file now — externally deleted (or
            // archived). Don't resurrect it here.
            markdownPathIndex.removeValue(forKey: note.id)
            return
        }
        let url = existingURL(for: note.id, in: activeURL) ?? generateURL(for: note, in: activeURL)
        // Nothing reached disk — don't record the path or cache the note as
        // saved, so the next attempt retries from a clean slate.
        guard write(note, to: url) else { return }
        markdownPathIndex[note.id] = url
        knownIds.insert(note.id)

        // A save touches exactly one known file, so patch the cache rather
        // than dropping it. Debounced saves fire on every keystroke; throwing
        // the tree away each time would make the cache useless while typing.
        upsertInCache(note, dir: activeURL)
        notifyObservers()
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
        guard moveFile(from: from, to: to) else { return }
        markdownPathIndex[note.id] = to
        notifyChange()
    }

    func discardActive(_ note: Note) {
        if let url = existingURL(for: note.id, in: activeURL) {
            try? FileManager.default.removeItem(at: url)
        }
        markdownPathIndex.removeValue(forKey: note.id)
        knownIds.remove(note.id)
        notifyChange()
    }

    func restore(_ note: Note) {
        guard let from = existingURL(for: note.id, in: archiveURL) else { return }
        let to = generateURL(for: note, in: activeURL)
        guard moveFile(from: from, to: to) else { return }
        markdownPathIndex[note.id] = to

        // Force-expand on restore so the content is immediately visible.
        if var restored = read(to), restored.collapsed {
            restored.collapsed = false
            write(restored, to: to)
        }
        notifyChange()
    }

    /// Union of every label across active + archived notes, normalized and
     /// sorted alphabetically. Used by autocomplete + the chrome label menu.
    func allLabels() -> [String] {
        var seen = Set<String>()
        for note in loadActive() { seen.formUnion(note.labels) }
        for note in loadArchived() { seen.formUnion(note.labels) }
        return seen.sorted()
    }

    func deleteForever(_ note: Note) {
        if let url = existingURL(for: note.id, in: archiveURL) {
            try? FileManager.default.removeItem(at: url)
        }
        markdownPathIndex.removeValue(forKey: note.id)
        knownIds.remove(note.id)
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

    /// Drop the cache before telling anyone, so observers that immediately
    /// call `loadActive()` read fresh data rather than what we just replaced.
    /// Used for changes that move or remove files, and for external changes
    /// reported by the watcher, where we can't know what else shifted.
    private func notifyChange() {
        invalidateCache()
        notifyObservers()
    }

    private func invalidateCache() {
        cache.removeAll()
        indexedDirs.removeAll()
    }

    private func notifyObservers() {
        NotificationCenter.default.post(name: NoteStore.didChange, object: self)
    }

    /// Replace-or-append a note in a warm cache. A cold cache is left cold —
    /// a single note is not a directory listing.
    private func upsertInCache(_ note: Note, dir: URL) {
        guard var notes = cache[dir.path] else { return }
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else {
            notes.append(note)
        }
        cache[dir.path] = notes
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
            // The index covers this directory, so a miss is the answer — the
            // note isn't here. (The `fileExists` check above still catches an
            // entry whose file was deleted since we indexed it, which is what
            // keeps the no-resurrect guard working.)
            if indexedDirs.contains(dir.path) { return nil }
            // Cold index: scan and rebuild for this dir.
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

    /// Read every file in `dir` to locate `id`, indexing all of them on the
    /// way so the next lookup here is free.
    private func scanForId(_ id: UUID, in dir: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        var match: URL?
        for url in files where url.pathExtension == fileExtension {
            guard let note = read(url) else { continue }
            markdownPathIndex[note.id] = url
            if note.id == id { match = url }
        }
        indexedDirs.insert(dir.path)
        return match
    }

    private func loadAll(from dir: URL) -> [Note] {
        if let cached = cache[dir.path] { return cached }

        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var notes: [Note] = []
        for url in files where url.pathExtension == fileExtension {
            guard let note = read(url) else { continue }
            if format == .markdown {
                markdownPathIndex[note.id] = url
            }
            knownIds.insert(note.id)
            notes.append(note)
        }
        cache[dir.path] = notes
        indexedDirs.insert(dir.path)
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

    /// Write a note, retrying once. Most failures here are transient — a sync
    /// agent holding the file, or the containing directory having just been
    /// moved — so a second attempt after recreating the directory usually
    /// lands. A failure that survives the retry is reported, not dropped.
    @discardableResult
    private func write(_ note: Note, to url: URL) -> Bool {
        do {
            try writeOnce(note, to: url)
            recordSuccess()
            return true
        } catch {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try writeOnce(note, to: url)
                recordSuccess()
                return true
            } catch {
                recordFailure(url: url, error: error)
                return false
            }
        }
    }

    private func writeOnce(_ note: Note, to url: URL) throws {
        switch format {
        case .json:
            try encoder.encode(note).write(to: url, options: .atomic)
        case .markdown:
            try renderMarkdown(note).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @discardableResult
    private func moveFile(from: URL, to: URL) -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: to)
        do {
            try fm.moveItem(at: from, to: to)
            recordSuccess()
            return true
        } catch {
            recordFailure(url: to, error: error)
            return false
        }
    }

    // MARK: - Health

    private func recordFailure(url: URL, error: Error) {
        lastFailure = StorageFailure(url: url, error: error, date: Date())
        NotificationCenter.default.post(name: NoteStore.healthDidChange, object: self)
    }

    private func recordSuccess() {
        guard lastFailure != nil else { return }
        lastFailure = nil
        NotificationCenter.default.post(name: NoteStore.healthDidChange, object: self)
    }

    // MARK: - Markdown serialization

    private func renderMarkdown(_ note: Note) -> String {
        let labelsField = "[" + note.labels.joined(separator: ", ") + "]"
        let frontmatter: [(String, String)] = [
            ("id", note.id.uuidString),
            ("title", note.title),
            ("color", note.color.rawValue),
            ("labels", labelsField),
            ("positionX", String(format: "%.2f", note.positionX)),
            ("positionY", String(format: "%.2f", note.positionY)),
            ("width", String(format: "%.2f", note.width)),
            ("height", String(format: "%.2f", note.height)),
            ("collapsed", note.collapsed ? "true" : "false"),
            ("created", iso8601.string(from: note.createdAt)),
            ("updated", iso8601.string(from: note.updatedAt))
        ]
        let document = MarkdownFile.Document(frontmatter: frontmatter, body: note.content)
        return MarkdownFile.serialize(document, forceQuoteKeys: ["title"])
    }

    private func parseMarkdown(_ raw: String, fallbackId: UUID?) -> Note? {
        let doc = MarkdownFile.parse(raw)
        let id: UUID = doc.value(for: "id").flatMap(UUID.init(uuidString:)) ?? fallbackId ?? UUID()
        let title = doc.value(for: "title") ?? ""
        let color = doc.value(for: "color").flatMap(NoteColor.init(rawValue:)) ?? .yellow
        let labels = parseLabelsList(doc.value(for: "labels"))
        let positionX = Double(doc.value(for: "positionX") ?? "") ?? 200
        let positionY = Double(doc.value(for: "positionY") ?? "") ?? 200
        let width = Double(doc.value(for: "width") ?? "") ?? 240
        let height = Double(doc.value(for: "height") ?? "") ?? 200
        let collapsed = (doc.value(for: "collapsed") ?? "false") == "true"
        let createdAt = doc.value(for: "created").flatMap(iso8601.date(from:)) ?? Date()
        let updatedAt = doc.value(for: "updated").flatMap(iso8601.date(from:)) ?? createdAt
        return Note(
            id: id,
            title: title,
            content: doc.body,
            positionX: positionX,
            positionY: positionY,
            width: width,
            height: height,
            collapsed: collapsed,
            color: color,
            labels: labels,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Parse a flat YAML inline-list value like `[a, b, c]`. Tolerates missing
    /// brackets and stray quotes — frontmatter is hand-edited often.
    private func parseLabelsList(_ raw: String?) -> [String] {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return [] }
        if s.hasPrefix("[") { s.removeFirst() }
        if s.hasSuffix("]") { s.removeLast() }
        return s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .compactMap { token -> String? in
                let n = NoteLabel.normalize(token)
                return n.isEmpty ? nil : n
            }
    }

    private func idFromFilename(_ url: URL) -> UUID? {
        UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }
}
