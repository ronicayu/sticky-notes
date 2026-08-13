import AppKit
import UniformTypeIdentifiers

/// Files pasted or dropped into a note.
///
/// They live in an `attachments/` folder beside `notes/`, and notes reference
/// them with a path relative to the note's own directory (`../attachments/x.png`).
/// That is what a Markdown link means to Obsidian, so a vault note renders the
/// image there too rather than showing a broken link.
enum Attachments {
    static let directoryName = "attachments"

    /// Where attachments for `store` are kept, created on demand.
    static func directory(for store: NoteStore) -> URL {
        let url = store.rootURL.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The reference to write into a note body, relative to `notes/`.
    static func relativePath(fileName: String) -> String {
        "../\(directoryName)/\(fileName)"
    }

    /// Resolve a note-relative reference back to a file on disk. Absolute
    /// paths and URLs are returned untouched.
    static func resolve(_ reference: String, for store: NoteStore) -> URL? {
        if let url = URL(string: reference), url.scheme != nil { return url }
        if reference.hasPrefix("/") { return URL(fileURLWithPath: reference) }
        return URL(fileURLWithPath: reference, relativeTo: store.activeURL).standardizedFileURL
    }

    /// Write image data next to the notes and return the reference to insert.
    /// Returns nil when the data can't be written, so the caller can fall back
    /// to a normal paste rather than silently dropping the image.
    static func save(imageData: Data, fileExtension: String, for store: NoteStore, now: Date = Date()) -> String? {
        let directory = directory(for: store)
        let name = uniqueName(extension: fileExtension, in: directory, now: now)
        let destination = directory.appendingPathComponent(name)
        do {
            try imageData.write(to: destination, options: .atomic)
        } catch {
            return nil
        }
        return relativePath(fileName: name)
    }

    /// Copy a file the user dropped in, keeping its original name when that
    /// name is still free.
    static func copy(fileAt source: URL, for store: NoteStore, now: Date = Date()) -> String? {
        let directory = directory(for: store)
        var name = source.lastPathComponent
        if name.isEmpty || FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = uniqueName(extension: source.pathExtension.isEmpty ? "dat" : source.pathExtension,
                              in: directory, now: now)
        }
        do {
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
        } catch {
            return nil
        }
        return relativePath(fileName: name)
    }

    /// Markdown for an image reference, or a plain link for anything else —
    /// an `![](…)` pointing at a PDF renders as a broken image in Obsidian.
    static func markdown(for reference: String, isImage: Bool) -> String {
        let name = (reference as NSString).lastPathComponent
        return isImage ? "![\(name)](\(reference))" : "[\(name)](\(reference))"
    }

    /// Handle a paste that carries a file or an image. Returns the markdown to
    /// insert, or nil when the pasteboard holds nothing worth saving — in
    /// which case the caller should paste normally.
    static func handlePaste(_ pasteboard: NSPasteboard, for store: NoteStore) -> String? {
        // A dragged or copied file: keep the original, including its name.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let fileURL = urls.first(where: { $0.isFileURL }) {
            guard let reference = copy(fileAt: fileURL, for: store) else { return nil }
            return markdown(for: reference, isImage: isImageExtension(fileURL.pathExtension))
        }

        // Raw image data — a screenshot, or a copy out of another app. Prefer
        // PNG, which is lossless and what macOS screenshots already are.
        guard pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) else { return nil }
        if let png = pasteboard.data(forType: .png),
           let reference = save(imageData: png, fileExtension: "png", for: store) {
            return markdown(for: reference, isImage: true)
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
           let reference = save(imageData: png, fileExtension: "png", for: store) {
            return markdown(for: reference, isImage: true)
        }
        return nil
    }

    static func isImageExtension(_ ext: String) -> Bool {
        guard let type = UTType(filenameExtension: ext.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    /// Timestamped names read well in a file listing and sort chronologically.
    /// A counter breaks ties within the same second.
    private static func uniqueName(extension ext: String, in directory: URL, now: Date) -> String {
        let stamp = nameFormatter.string(from: now)
        let fm = FileManager.default
        var candidate = "\(stamp).\(ext)"
        var counter = 2
        while fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(stamp)-\(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
