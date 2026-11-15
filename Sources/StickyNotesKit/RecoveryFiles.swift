import Foundation

/// Where text goes when its file cannot be written: a folder beside the local
/// storage, not inside the folder that is failing.
struct RecoveryFiles {
    let settings: Settings
    let store: NoteStore
    let clock: AppClock

    var folder: URL {
        settings.localStorageRoot.appendingPathComponent("Recovered", isDirectory: true)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Copy a note's unsaved text out. False when the copy failed too.
    func write(_ note: Note) -> Bool {
        let stamp = RecoveryFiles.stamp.string(from: clock.now())
        return write(store.recoveryText(for: note), named: "\(note.id.uuidString) \(stamp).md")
    }

    func writeDaily(_ document: DailyDocument) -> Bool {
        writeDaily(body: document.body, day: document.day)
    }

    func writeDaily(body: String, day: Date) -> Bool {
        let stamp = RecoveryFiles.stamp.string(from: clock.now())
        let name = RecoveryFiles.stamp.string(from: day).prefix(10)
        return write(body, named: "Daily \(name) \(stamp).md")
    }

    private func write(_ text: String, named name: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
