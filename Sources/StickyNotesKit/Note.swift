import Foundation
import CoreGraphics

enum NoteColor: String, Codable, CaseIterable {
    case yellow, pink, orange, green, blue, purple, gray

    /// Body / paper color — bright, clean, high-luminosity pastels (TickTick-style).
    var bodyHex: String {
        Appearance.isDark ? darkBodyHex : lightBodyHex
    }

    /// Header strip — same hue, slightly more saturated so the title bar reads
    /// like the top of a real paper sticky.
    var headerHex: String {
        Appearance.isDark ? darkHeaderHex : lightHeaderHex
    }

    /// Text tone that stays legible on this note's paper.
    var textHex: String {
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

struct Note: Codable, Identifiable {
    let id: UUID
    var title: String
    var content: String
    var positionX: Double
    var positionY: Double
    var width: Double
    var height: Double
    var collapsed: Bool
    var color: NoteColor
    var labels: [String]
    var floatLevel: NoteFloatLevel
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        title: String = "",
        content: String,
        positionX: Double,
        positionY: Double,
        width: Double,
        height: Double,
        collapsed: Bool,
        color: NoteColor,
        labels: [String] = [],
        floatLevel: NoteFloatLevel = .floating,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.positionX = positionX
        self.positionY = positionY
        self.width = width
        self.height = height
        self.collapsed = collapsed
        self.color = color
        self.labels = labels
        self.floatLevel = floatLevel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Custom decoder so notes saved before newer fields existed still decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        content = try c.decode(String.self, forKey: .content)
        positionX = try c.decode(Double.self, forKey: .positionX)
        positionY = try c.decode(Double.self, forKey: .positionY)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        collapsed = (try? c.decode(Bool.self, forKey: .collapsed)) ?? false
        color = (try? c.decode(NoteColor.self, forKey: .color)) ?? .yellow
        labels = (try? c.decode([String].self, forKey: .labels)) ?? []
        floatLevel = (try? c.decode(NoteFloatLevel.self, forKey: .floatLevel)) ?? .floating
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    static func makeNew() -> Note {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let w = 240.0, h = 200.0
        let x = Double.random(in: 80...(screen.width - w - 80))
        let y = Double.random(in: 120...(screen.height - h - 120))
        let now = Date()
        return Note(
            id: UUID(),
            title: "",
            content: "",
            positionX: x,
            positionY: y,
            width: w,
            height: h,
            collapsed: false,
            color: Settings.shared.defaultNoteColor,
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
