import Foundation
import CoreGraphics

enum NoteColor: String, Codable, CaseIterable {
    case yellow, pink, orange, green, blue, purple, gray

    /// Body / paper color — bright, clean, high-luminosity pastels (TickTick-style).
    var bodyHex: String {
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

    /// Header strip — same hue, slightly more saturated so the title bar reads
    /// like the top of a real paper sticky.
    var headerHex: String {
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

struct Note: Codable, Identifiable {
    let id: UUID
    var content: String
    var positionX: Double
    var positionY: Double
    var width: Double
    var height: Double
    var collapsed: Bool
    var color: NoteColor
    let createdAt: Date
    var updatedAt: Date

    static func makeNew() -> Note {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let w = 240.0, h = 200.0
        let x = Double.random(in: 80...(screen.width - w - 80))
        let y = Double.random(in: 120...(screen.height - h - 120))
        let now = Date()
        return Note(
            id: UUID(),
            content: "",
            positionX: x,
            positionY: y,
            width: w,
            height: h,
            collapsed: false,
            color: .yellow,
            createdAt: now,
            updatedAt: now
        )
    }
}
