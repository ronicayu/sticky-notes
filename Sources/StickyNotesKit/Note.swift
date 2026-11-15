import Foundation
import CoreGraphics

enum NoteColor: String, Codable, CaseIterable {
    case yellow, pink, orange, green, blue, purple, gray

    /// Body / paper color — bright, clean, high-luminosity pastels (TickTick-style).
    @MainActor var bodyHex: String {
        Appearance.isDark ? darkBodyHex : lightBodyHex
    }

    /// Header strip — same hue, slightly more saturated so the title bar reads
    /// like the top of a real paper sticky.
    @MainActor var headerHex: String {
        Appearance.isDark ? darkHeaderHex : lightHeaderHex
    }

    /// Text tone that stays legible on this note's paper.
    @MainActor var textHex: String {
        Appearance.isDark ? "#ECECEE" : "#1A1A1F"
    }

    var lightBodyHex: String {
        switch self {
        case .yellow: return "#FFF1A8"
        case .pink:   return "#FFD8E2"
        case .orange: return "#FFE0B7"
        case .green:  return "#D8F0BB"
        case .blue:   return "#D2E8FB"
        case .purple: return "#E5D5F5"
        case .gray:   return "#F0EFE9"
        }
    }

    var lightHeaderHex: String {
        switch self {
        case .yellow: return "#FFE680"
        case .pink:   return "#FFC2D2"
        case .orange: return "#FFCB87"
        case .green:  return "#C2E5A2"
        case .blue:   return "#BAD9F3"
        case .purple: return "#D1B9EE"
        case .gray:   return "#E5E3D9"
        }
    }

    /// Dark-mode paper. Deep, desaturated versions of the same hues rather
    /// than dimmed pastels — a lightly darkened pastel reads as muddy, and a
    /// bright one glows against a dark desktop.
    var darkBodyHex: String {
        switch self {
        case .yellow: return "#3E3616"
        case .pink:   return "#42222C"
        case .orange: return "#432F16"
        case .green:  return "#26381D"
        case .blue:   return "#1E3145"
        case .purple: return "#332745"
        case .gray:   return "#2E2E30"
        }
    }

    var darkHeaderHex: String {
        switch self {
        case .yellow: return "#4E441C"
        case .pink:   return "#542B38"
        case .orange: return "#553C1D"
        case .green:  return "#314726"
        case .blue:   return "#274058"
        case .purple: return "#413259"
        case .gray:   return "#3B3B3E"
        }
    }

    var displayName: String {
        switch self {
        case .yellow: return "Yellow"
        case .pink:   return "Pink"
        case .orange: return "Orange"
        case .green:  return "Green"
        case .blue:   return "Blue"
        case .purple: return "Purple"
        case .gray:   return "Gray"
        }
    }
}

/// How a note sits relative to other apps' windows.
enum NoteFloatLevel: String, Codable, CaseIterable {
    /// Above everything — the app's original behavior.
    case floating
    /// Behind other apps, visible with the desktop. Classic Stickies.
    case desktop

    var displayName: String {
        switch self {
        case .floating: return "Float Above All"
        case .desktop:  return "Stick to Desktop"
        }
    }
}

/// What the file's frontmatter holds that the app does not own, and how the
/// file laid it out: every other key (tags, aliases, plugin properties,
/// comments) as the lines it was read from, and where the app's own keys sat
/// among them. Written back as it was; the app never edits any of it, so it is
/// not part of a note's text and a merge takes it from the file.
struct PreservedFrontmatter: Equatable {
    var layout: [MarkdownFile.Slot] = []
    /// The file wrote `labels` as a block list, so it is written back that way.
    var labelsAsBlock = false
    /// What the file had for each key the app owns, so a value the app did not
    /// change is written as the file had it.
    var originals: [String: MarkdownFile.Original] = [:]
}

/// Where an older build kept a note's window, in the note's own file. This
/// build keeps the window per Mac (see `DeviceLayoutStore`) and no longer writes
/// these keys, but a file that still has them places the note once, on a Mac
/// that has no layout for it.
struct LegacyPlacement: Equatable {
    var x: Double
    var y: Double
    var collapsed: Bool
}

struct Note: Codable, Identifiable {
    let id: UUID
    var title: String
    var content: String
    /// The size the note was last saved at: a hint for a Mac that has never
    /// shown it. Where the window sits, and its size on a Mac that has shown it,
    /// are that Mac's own and live in `DeviceLayoutStore`.
    var width: Double
    var height: Double
    var color: NoteColor
    var labels: [String]
    var floatLevel: NoteFloatLevel
    let createdAt: Date
    var updatedAt: Date
    var preserved = PreservedFrontmatter()
    /// What the file's retired geometry keys held, when it still has them. Read
    /// to place the note once. Their lines stay in the file as an older build
    /// left them; a later release removes them.
    var legacyPlacement: LegacyPlacement?

    private enum CodingKeys: String, CodingKey {
        case id, title, content, positionX, positionY, width, height, collapsed, color, labels
        case floatLevel, createdAt, updatedAt
    }

    init(
        id: UUID,
        title: String = "",
        content: String,
        width: Double,
        height: Double,
        color: NoteColor,
        labels: [String] = [],
        floatLevel: NoteFloatLevel = .floating,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.width = width
        self.height = height
        self.color = color
        self.labels = labels
        self.floatLevel = floatLevel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Custom decoder so legacy JSON notes saved before newer fields existed still
    /// decode. Only the conversion to Markdown reads JSON notes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        content = try c.decode(String.self, forKey: .content)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        color = (try? c.decode(NoteColor.self, forKey: .color)) ?? .yellow
        labels = (try? c.decode([String].self, forKey: .labels)) ?? []
        floatLevel = (try? c.decode(NoteFloatLevel.self, forKey: .floatLevel)) ?? .floating
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        if let x = try? c.decode(Double.self, forKey: .positionX),
           let y = try? c.decode(Double.self, forKey: .positionY) {
            legacyPlacement = LegacyPlacement(
                x: x, y: y, collapsed: (try? c.decode(Bool.self, forKey: .collapsed)) ?? false
            )
        }
    }

    /// The JSON shape older builds read, which only a test of the conversion needs.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(content, forKey: .content)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(color, forKey: .color)
        try c.encode(labels, forKey: .labels)
        try c.encode(floatLevel, forKey: .floatLevel)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        let placement = legacyPlacement ?? LegacyPlacement(x: 0, y: 0, collapsed: false)
        try c.encode(placement.x, forKey: .positionX)
        try c.encode(placement.y, forKey: .positionY)
        try c.encode(placement.collapsed, forKey: .collapsed)
    }

    /// A new note sized as `frame`. The note's window is placed by the caller
    /// in `DeviceLayoutStore`; callers pass real screen geometry, because this
    /// used to invent a 1440x900 screen, which put notes off screen on other
    /// displays. See `NotePlacement`.
    static func makeNew(
        frame: CGRect,
        color: NoteColor = .yellow,
        now: Date = Date()
    ) -> Note {
        return Note(
            id: UUID(),
            title: "",
            content: "",
            width: Double(frame.size.width),
            height: Double(frame.size.height),
            color: color,
            labels: [],
            floatLevel: .floating,
            createdAt: now,
            updatedAt: now
        )
    }
}

/// Label name normalization shared between the autocomplete pipeline, the
/// label menu, and the persisted frontmatter.
enum NoteLabel {
    /// Trim, drop a leading `#`, lowercase, collapse whitespace into `-`.
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        s = s.lowercased()
        s = s.replacingOccurrences(
            of: #"\s+"#,
            with: "-",
            options: .regularExpression
        )
        s = s.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return s
    }
}
