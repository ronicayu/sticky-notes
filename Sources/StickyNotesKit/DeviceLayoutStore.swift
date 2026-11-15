import CoreGraphics
import Foundation

/// Where one note's window sits on this Mac.
struct NoteLayout: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    /// The height the window has when expanded. A collapsed window is a bar
    /// whose origin is `x`, `y`; this is the height it opens back to.
    var height: Double
    var collapsed: Bool

    init(x: Double, y: Double, width: Double, height: Double, collapsed: Bool = false) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.collapsed = collapsed
    }

    init(frame: CGRect, collapsed: Bool = false) {
        self.init(
            x: Double(frame.origin.x), y: Double(frame.origin.y),
            width: Double(frame.size.width), height: Double(frame.size.height), collapsed: collapsed
        )
    }

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Every note's window layout on this Mac: where it sits, how big it is, and
/// whether it is collapsed, keyed by note id. It lives outside every storage
/// root and is never synced, so dragging a note writes no note file, and a
/// second Mac with a different screen keeps a layout of its own. The note's
/// float level is not here: it is the person's intent and stays in the note.
///
/// Changes stay in memory and reach the file at most once per `writeDelay`,
/// because a drag reports a new position many times a second. `flush` writes
/// at once. A store made without a file keeps everything in memory.
final class DeviceLayoutStore {
    static let writeDelay: TimeInterval = 0.5

    private let url: URL?
    private let scheduler: Scheduler
    private var entries: [String: NoteLayout]
    private var writeTask: ScheduledWork?
    private var hasUnwrittenChanges = false

    init(url: URL? = nil, scheduler: Scheduler = MainScheduler()) {
        self.url = url
        self.scheduler = scheduler
        entries = [:]
        guard let url, let data = try? Data(contentsOf: url) else { return }
        if let readable = Self.entries(in: data) {
            entries = readable
        } else {
            // Not a layout file. The first write would replace it, so keep it.
            let aside = url.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
        }
    }

    /// The entries a layout file holds, one by one, so a single bad entry costs
    /// that note its place and no other. Nil when the data is not a JSON object.
    private static func entries(in data: Data) -> [String: NoteLayout]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var result: [String: NoteLayout] = [:]
        for (key, value) in object where UUID(uuidString: key) != nil {
            guard JSONSerialization.isValidJSONObject(value),
                  let entry = try? JSONSerialization.data(withJSONObject: value),
                  let layout = try? JSONDecoder().decode(NoteLayout.self, from: entry) else { continue }
            result[key] = layout
        }
        return result
    }

    /// Whether `data` is a layout file in full, with every entry readable.
    static func isLayoutFile(_ data: Data) -> Bool {
        (try? JSONDecoder().decode([String: NoteLayout].self, from: data)) != nil
    }

    func layout(for id: UUID) -> NoteLayout? {
        entries[id.uuidString]
    }

    func set(_ layout: NoteLayout, for id: UUID) {
        guard entries[id.uuidString] != layout else { return }
        entries[id.uuidString] = layout
        hasUnwrittenChanges = true
        scheduleWrite()
    }

    /// Change the layout of a note that has one. Nothing to change otherwise.
    func update(_ id: UUID, _ change: (inout NoteLayout) -> Void) {
        guard var layout = entries[id.uuidString] else { return }
        change(&layout)
        set(layout, for: id)
    }

    func remove(_ id: UUID) {
        guard entries.removeValue(forKey: id.uuidString) != nil else { return }
        hasUnwrittenChanges = true
        scheduleWrite()
    }

    /// Forget the notes for which `isKnown` is false, for the ones that no longer
    /// exist anywhere. The caller must answer true for any note that may exist.
    func prune(keeping isKnown: (UUID) -> Bool) {
        for key in entries.keys {
            guard let id = UUID(uuidString: key), !isKnown(id) else { continue }
            remove(id)
        }
    }

    /// Write now whatever has not reached the file.
    func flush() {
        writeTask?.cancel()
        writeTask = nil
        guard hasUnwrittenChanges, let url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            hasUnwrittenChanges = false
        } catch {
            // A layout that cannot be written is cosmetic; the next change tries again.
        }
    }

    private func scheduleWrite() {
        guard url != nil, writeTask == nil else { return }
        writeTask = scheduler.schedule(after: Self.writeDelay) { [weak self] in
            self?.writeTask = nil
            self?.flush()
        }
    }
}
