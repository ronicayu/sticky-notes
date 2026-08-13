import XCTest
@testable import StickyNotesKit

final class NoteTests: XCTestCase {

    // MARK: - Backward-compatible decoding

    func testDecodesANoteMissingEveryOptionalField() throws {
        // The oldest on-disk shape: no title, collapsed, color, or labels.
        let legacy = """
        {
          "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "content": "hello",
          "positionX": 10, "positionY": 20,
          "width": 240, "height": 200,
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-02T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let note = try decoder.decode(Note.self, from: Data(legacy.utf8))

        XCTAssertEqual(note.content, "hello")
        XCTAssertEqual(note.title, "", "missing title should default to empty")
        XCTAssertFalse(note.collapsed)
        XCTAssertEqual(note.color, .yellow, "missing color should default to yellow")
        XCTAssertEqual(note.labels, [])
    }

    func testUnknownColorDecodesAsYellowRatherThanThrowing() throws {
        let raw = """
        {
          "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "content": "", "color": "chartreuse",
          "positionX": 0, "positionY": 0, "width": 1, "height": 1,
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Note.self, from: Data(raw.utf8)).color, .yellow)
    }

    func testDecodingFailsWhenARequiredFieldIsMissing() {
        // content is required — a file without it is corrupt, not merely old,
        // and should be skipped rather than silently loaded as blank.
        let raw = """
        {
          "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "positionX": 0, "positionY": 0, "width": 1, "height": 1,
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertThrowsError(try decoder.decode(Note.self, from: Data(raw.utf8)))
    }

    func testEncodeDecodeRoundTripPreservesEveryField() throws {
        let note = Note(
            id: UUID(), title: "Title", content: "Body\nwith lines",
            positionX: 1.5, positionY: 2.5, width: 300, height: 400,
            collapsed: true, color: .purple, labels: ["a", "b"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let back = try decoder.decode(Note.self, from: encoder.encode(note))
        XCTAssertEqual(back.id, note.id)
        XCTAssertEqual(back.title, note.title)
        XCTAssertEqual(back.content, note.content)
        XCTAssertEqual(back.collapsed, note.collapsed)
        XCTAssertEqual(back.color, note.color)
        XCTAssertEqual(back.labels, note.labels)
    }

    // MARK: - New notes

    private static let sampleFrame = CGRect(x: 100, y: 200, width: 240, height: 200)

    func testNewNoteStartsEmptyAndExpanded() {
        let note = Note.makeNew(frame: NoteTests.sampleFrame)
        XCTAssertTrue(note.content.isEmpty)
        XCTAssertTrue(note.title.isEmpty)
        XCTAssertFalse(note.collapsed)
        XCTAssertTrue(note.labels.isEmpty)
    }

    func testNewNoteUsesTheFrameItWasGiven() {
        let note = Note.makeNew(frame: NoteTests.sampleFrame)
        XCTAssertEqual(note.positionX, 100)
        XCTAssertEqual(note.positionY, 200)
        XCTAssertEqual(note.width, 240)
        XCTAssertEqual(note.height, 200)
    }

    func testEachNewNoteHasItsOwnIdentity() {
        let a = Note.makeNew(frame: NoteTests.sampleFrame)
        let b = Note.makeNew(frame: NoteTests.sampleFrame)
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - Colors

    func testEveryColorHasDistinctBodyAndHeaderHexValues() {
        let bodies = NoteColor.allCases.map(\.bodyHex)
        XCTAssertEqual(Set(bodies).count, bodies.count, "two colors share a body hex")

        let headers = NoteColor.allCases.map(\.headerHex)
        XCTAssertEqual(Set(headers).count, headers.count, "two colors share a header hex")
    }

    func testEveryColorHexIsWellFormed() {
        for color in NoteColor.allCases {
            for hex in [color.bodyHex, color.headerHex] {
                XCTAssertEqual(hex.count, 7, "\(color) hex \(hex) is not #RRGGBB")
                XCTAssertTrue(hex.hasPrefix("#"), "\(color) hex \(hex) missing #")
                XCTAssertNotNil(UInt32(hex.dropFirst(), radix: 16), "\(color) hex \(hex) is not hexadecimal")
            }
        }
    }

    func testEveryColorHasADisplayNameAndStableRawValue() {
        for color in NoteColor.allCases {
            XCTAssertFalse(color.displayName.isEmpty, "\(color) has no display name")
            // Raw values are persisted in JSON and YAML frontmatter — changing
            // one silently resets existing notes to yellow.
            XCTAssertEqual(NoteColor(rawValue: color.rawValue), color)
        }
    }

    func testColorRawValuesAreTheExpectedSet() {
        XCTAssertEqual(
            Set(NoteColor.allCases.map(\.rawValue)),
            ["yellow", "pink", "orange", "green", "blue", "purple", "gray"],
            "persisted color names changed — existing notes would reset to yellow"
        )
    }
}
