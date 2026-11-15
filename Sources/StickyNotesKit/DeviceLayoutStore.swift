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
        // A missing or unreadable file is a Mac that has laid nothing out yet.
        entries = url
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: NoteLayout].self, from: $0) } ?? [:]
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
