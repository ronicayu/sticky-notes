import AppKit
import XCTest
@testable import StickyNotesKit

@MainActor final class NoteColorAppearanceTests: XCTestCase {

    /// Chrome ink used to be a fixed black, which is invisible on the dark
    /// papers — the buttons, the footer date and the label chips all vanished.
    func testChromeInkFlipsWithTheAppearance() throws {
        // Touching `shared` is what installs NSApp, which `Appearance` reads.
        let app = NSApplication.shared
        let original = app.appearance
        defer { app.appearance = original }

        app.appearance = NSAppearance(named: .aqua)
        let lightInks = [Appearance.chromeInk, Appearance.secondaryInk, Appearance.chipInk]
        app.appearance = NSAppearance(named: .darkAqua)
        let darkInks = [Appearance.chromeInk, Appearance.secondaryInk, Appearance.chipInk]

        for (light, dark) in zip(lightInks, darkInks) {
            let lightWhite = try XCTUnwrap(light.usingColorSpace(.genericGray)).whiteComponent
            let darkWhite = try XCTUnwrap(dark.usingColorSpace(.genericGray)).whiteComponent
            XCTAssertGreaterThan(darkWhite, lightWhite,
                                 "ink on dark paper has to be lighter, not darker")
        }
    }

    func testEveryColorDefinesBothLightAndDarkVariants() {
        for color in NoteColor.allCases {
            for hex in [color.lightBodyHex, color.lightHeaderHex, color.darkBodyHex, color.darkHeaderHex] {
                XCTAssertEqual(hex.count, 7, "\(color): \(hex) is not #RRGGBB")
                XCTAssertNotNil(UInt32(hex.dropFirst(), radix: 16), "\(color): \(hex) is not hexadecimal")
            }
        }
    }

    func testDarkVariantsAreActuallyDarkerThanLightOnes() {
        for color in NoteColor.allCases {
            guard let light = NSColor(hex: color.lightBodyHex)?.usingColorSpace(.sRGB),
                  let dark = NSColor(hex: color.darkBodyHex)?.usingColorSpace(.sRGB) else {
                return XCTFail("\(color) hex did not parse")
            }
            XCTAssertLessThan(dark.brightnessComponent, light.brightnessComponent,
                              "\(color)'s dark paper is not darker than its light paper")
        }
    }

    /// A dark note that glows is worse than no dark mode at all.
    func testDarkPaperIsDarkEnoughNotToGlow() {
        for color in NoteColor.allCases {
            guard let dark = NSColor(hex: color.darkBodyHex)?.usingColorSpace(.sRGB) else {
                return XCTFail("\(color) dark hex did not parse")
            }
            XCTAssertLessThan(dark.brightnessComponent, 0.40,
                              "\(color)'s dark paper is too bright against a dark desktop")
        }
    }

    func testHeadersStayDistinctFromTheirBodyInBothAppearances() {
        for color in NoteColor.allCases {
            XCTAssertNotEqual(color.lightBodyHex, color.lightHeaderHex, "\(color) light")
            XCTAssertNotEqual(color.darkBodyHex, color.darkHeaderHex, "\(color) dark")
        }
    }

    func testDarkVariantsAreDistinctFromEachOther() {
        let bodies = NoteColor.allCases.map(\.darkBodyHex)
        XCTAssertEqual(Set(bodies).count, bodies.count, "two colors share a dark paper")
    }

    /// The colour menu is drawn on the system's own background, so in dark mode
    /// a swatch in the dark paper colour is near black and the seven look alike.
    func testMenuSwatchesKeepTheirLightColorInDarkMode() throws {
        let app = NSApplication.shared
        let original = app.appearance
        defer { app.appearance = original }

        func centre(of image: NSImage) throws -> NSColor {
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 14, pixelsHigh: 14, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: 14, height: 14))
            return try XCTUnwrap(rep.colorAt(x: 7, y: 7)?.usingColorSpace(.sRGB))
        }

        app.appearance = NSAppearance(named: .darkAqua)
        var seen: Set<String> = []
        for color in NoteColor.allCases {
            let pixel = try centre(of: NoteWindowController.colorSwatch(for: color))
            let light = try XCTUnwrap(NSColor(hex: color.lightBodyHex)?.usingColorSpace(.sRGB))
            XCTAssertEqual(pixel.brightnessComponent, light.brightnessComponent, accuracy: 0.02, "\(color)")
            seen.insert(String(format: "%.2f-%.2f-%.2f", pixel.redComponent, pixel.greenComponent, pixel.blueComponent))
        }
        XCTAssertEqual(seen.count, NoteColor.allCases.count)
    }

    /// The stored value is a color name, so adding dark variants must not have
    /// changed what lands in a file.
    func testAppearanceDoesNotAffectPersistedValues() {
        for color in NoteColor.allCases {
            XCTAssertEqual(NoteColor(rawValue: color.rawValue), color)
        }
    }
}

final class NoteFloatLevelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloatLevelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func note(floatLevel: NoteFloatLevel) -> Note {
        Note(
            id: UUID(), title: "", content: "x",
            width: 240, height: 200, color: .yellow, labels: [],
            floatLevel: floatLevel,
            createdAt: Date(), updatedAt: Date()
        )
    }

    func testNewNotesFloatAboveEverything() {
        XCTAssertEqual(Note.makeNew(frame: CGRect(x: 0, y: 0, width: 240, height: 200)).floatLevel, .floating)
    }

    func testFloatLevelSurvivesASaveAndLoad() throws {
        let store = NoteStore(rootURL: root)
        store.save(note(floatLevel: .desktop))
        XCTAssertEqual(try XCTUnwrap(store.loadActive().first).floatLevel, .desktop)
    }

    /// Notes written before the field existed have to keep opening.
    func testNotesWithoutAFloatLevelDefaultToFloating() throws {
        let legacy = """
        {
          "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "content": "old note",
          "positionX": 0, "positionY": 0, "width": 240, "height": 200,
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Note.self, from: Data(legacy.utf8)).floatLevel, .floating)
    }

    func testMarkdownFrontmatterWithoutFloatDefaultsToFloating() throws {
        let store = NoteStore(rootURL: root)
        let raw = """
        ---
        id: 3F2504E0-4F89-11D3-9A0C-0305E82C3301
        title: Hand written
        color: blue
        ---

        body
        """
        try raw.write(to: store.activeURL.appendingPathComponent("hand.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try XCTUnwrap(store.loadActive().first).floatLevel, .floating)
    }

    func testFloatLevelIsWrittenToFrontmatter() throws {
        let store = NoteStore(rootURL: root)
        store.save(note(floatLevel: .desktop))
        let file = try XCTUnwrap(try FileManager.default
            .contentsOfDirectory(at: store.activeURL, includingPropertiesForKeys: nil).first)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("float: desktop"))
    }

    func testEveryLevelHasADisplayName() {
        for level in NoteFloatLevel.allCases {
            XCTAssertFalse(level.displayName.isEmpty)
            XCTAssertEqual(NoteFloatLevel(rawValue: level.rawValue), level)
        }
    }
}
