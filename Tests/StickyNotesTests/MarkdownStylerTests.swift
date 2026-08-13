import AppKit
import XCTest
@testable import StickyNotesKit

final class MarkdownStylerTests: XCTestCase {

    // MARK: - Helpers

    private func styled(_ source: String) -> NSTextStorage {
        let storage = NSTextStorage(string: source)
        MarkdownStyler.apply(to: storage)
        return storage
    }

    /// Ranges tagged as markdown markers, in document order.
    private func markerRanges(_ storage: NSTextStorage) -> [NSRange] {
        var out: [NSRange] = []
        storage.enumerateAttribute(.mdMarkerScope, in: fullRange(storage)) { value, range, _ in
            if value != nil { out.append(range) }
        }
        return out
    }

    private func markerSubstrings(_ storage: NSTextStorage) -> [String] {
        let ns = storage.string as NSString
        return markerRanges(storage).map { ns.substring(with: $0) }
    }

    private func fullRange(_ storage: NSTextStorage) -> NSRange {
        NSRange(location: 0, length: storage.length)
    }

    private func traits(_ storage: NSTextStorage, at index: Int) -> NSFontDescriptor.SymbolicTraits {
        let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
        return font?.fontDescriptor.symbolicTraits ?? []
    }

    private func isMonospaced(_ storage: NSTextStorage, at index: Int) -> Bool {
        let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
        return font?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false
    }

    /// UTF-16 index of `needle` — what NSAttributedString ranges are measured in.
    private func index(of needle: String, in haystack: String) -> Int {
        (haystack as NSString).range(of: needle).location
    }

    // MARK: - Basic inline styling

    func testBoldMarkersAreTaggedAndInnerTextIsBold() {
        let storage = styled("**bold**")
        XCTAssertEqual(markerSubstrings(storage), ["**", "**"])
        XCTAssertTrue(traits(storage, at: 2).contains(.bold))
    }

    func testItalicMarkersAreTaggedAndInnerTextIsItalic() {
        let storage = styled("*slanted*")
        XCTAssertEqual(markerSubstrings(storage), ["*", "*"])
        XCTAssertTrue(traits(storage, at: 1).contains(.italic))
    }

    func testStrikethroughIsApplied() {
        let storage = styled("~~gone~~")
        XCTAssertEqual(markerSubstrings(storage), ["~~", "~~"])
        XCTAssertNotNil(storage.attribute(.strikethroughStyle, at: 2, effectiveRange: nil))
    }

    func testInlineCodeUsesAMonospacedFont() {
        let storage = styled("run `swift build` now")
        XCTAssertEqual(markerSubstrings(storage), ["`", "`"])
        XCTAssertTrue(isMonospaced(storage, at: index(of: "swift", in: storage.string)))
    }

    func testPlainTextGetsNoMarkers() {
        XCTAssertTrue(markerRanges(styled("just some ordinary words")).isEmpty)
    }

    func testEmptyStorageIsLeftAlone() {
        let storage = NSTextStorage(string: "")
        MarkdownStyler.apply(to: storage)
        XCTAssertEqual(storage.length, 0)
    }

    // MARK: - Cases the old regex parser got wrong

    func testNestedBoldItalicKeepsBothTraits() {
        let storage = styled("***loud***")
        // Bold from the outer node must survive the inner node's styling.
        let traitsAtX = traits(storage, at: index(of: "loud", in: storage.string))
        XCTAssertTrue(traitsAtX.contains(.bold), "lost bold in ***x***")
        XCTAssertTrue(traitsAtX.contains(.italic), "lost italic in ***x***")
    }

    func testBoldInsideItalicKeepsBothTraits() {
        let storage = styled("*a **b** c*")
        let atB = traits(storage, at: index(of: "b", in: storage.string))
        XCTAssertTrue(atB.contains(.bold))
        XCTAssertTrue(atB.contains(.italic))
        let atA = traits(storage, at: index(of: "a", in: storage.string))
        XCTAssertTrue(atA.contains(.italic))
        XCTAssertFalse(atA.contains(.bold), "bold must not leak outside its own span")
    }

    func testEscapedMarkersAreNotTreatedAsEmphasis() {
        let storage = styled(#"\*not italic\*"#)
        XCTAssertTrue(markerRanges(storage).isEmpty, "escaped asterisks should stay literal text")
    }

    func testMarkersInsideCodeSpansAreNotEmphasis() {
        let storage = styled("`**not bold**`")
        // Only the backticks are markers; the asterisks are code content.
        XCTAssertEqual(markerSubstrings(storage), ["`", "`"])
        let atStars = index(of: "**not", in: storage.string)
        XCTAssertFalse(traits(storage, at: atStars).contains(.bold))
        XCTAssertTrue(isMonospaced(storage, at: atStars))
    }

    func testMultiBacktickCodeSpanUsesTheRightMarkerLength() {
        // ``a`b`` — a two-backtick fence wrapping content that contains one.
        let storage = styled("``a`b``")
        XCTAssertEqual(markerSubstrings(storage), ["``", "``"])
        XCTAssertTrue(isMonospaced(storage, at: 2))
    }

    func testUnderscoreEmphasisIsRecognized() {
        let storage = styled("_slanted_")
        XCTAssertEqual(markerSubstrings(storage), ["_", "_"])
        XCTAssertTrue(traits(storage, at: 1).contains(.italic))
    }

    func testIntraWordUnderscoresAreNotEmphasis() {
        // snake_case_name is one word to CommonMark, not emphasis.
        XCTAssertTrue(markerRanges(styled("snake_case_name")).isEmpty)
    }

    func testUnmatchedMarkerIsLeftAsPlainText() {
        XCTAssertTrue(markerRanges(styled("2 * 3 = 6")).isEmpty)
    }

    // MARK: - UTF-8 / UTF-16 offset mapping
    //
    // swift-markdown reports columns as UTF-8 byte offsets; NSAttributedString
    // indexes UTF-16 units. Anything non-ASCII earlier on the line shifts the
    // two apart, so these are the tests that catch a broken conversion.

    func testMarkerRangesAreCorrectAfterAnEmojiOnTheSameLine() {
        let source = "🎉 **party**"
        let storage = styled(source)
        XCTAssertEqual(markerSubstrings(storage), ["**", "**"],
                       "emoji is 2 UTF-16 units but 4 UTF-8 bytes — ranges drifted")
        XCTAssertTrue(traits(storage, at: index(of: "party", in: source)).contains(.bold))
    }

    func testMarkerRangesAreCorrectAfterAccentedCharacters() {
        let source = "café résumé **bold**"
        let storage = styled(source)
        XCTAssertEqual(markerSubstrings(storage), ["**", "**"],
                       "each é is 1 UTF-16 unit but 2 UTF-8 bytes")
        XCTAssertTrue(traits(storage, at: index(of: "bold", in: source)).contains(.bold))
    }

    func testMarkerRangesAreCorrectOnALineFollowingNonASCIILines() {
        let source = "🎉🎉🎉 first line\ncafé second line\n**third**"
        let storage = styled(source)
        XCTAssertEqual(markerSubstrings(storage), ["**", "**"],
                       "per-line offset table drifted across earlier non-ASCII lines")
        XCTAssertTrue(traits(storage, at: index(of: "third", in: source)).contains(.bold))
    }

    func testEmphasisAroundNonASCIIContentIsMeasuredCorrectly() {
        let source = "**héllo wörld**"
        let storage = styled(source)
        XCTAssertEqual(markerSubstrings(storage), ["**", "**"])
        XCTAssertTrue(traits(storage, at: index(of: "héllo", in: source)).contains(.bold))
        // The closing marker must land on the last two characters.
        XCTAssertEqual(markerRanges(storage).last?.location, (source as NSString).length - 2)
    }

    func testEmojiInsideEmphasisKeepsTheClosingMarkerAligned() {
        let source = "**a 🎉 b**"
        let storage = styled(source)
        XCTAssertEqual(markerSubstrings(storage), ["**", "**"])
        XCTAssertEqual(markerRanges(storage).last?.location, (source as NSString).length - 2)
    }

    // MARK: - Headings

    func testHeadingMarkerIsTaggedAndTextIsEnlarged() {
        let storage = styled("# Title")
        XCTAssertTrue(markerSubstrings(storage).contains { $0.contains("#") },
                      "expected the '#' prefix to be tagged as a marker")
        let headingFont = storage.attribute(.font, at: index(of: "Title", in: storage.string),
                                            effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(headingFont?.pointSize ?? 0, MarkdownStyler.baseFontSize,
                             "heading text should be larger than body text")
    }

    func testHashInsideALineIsNotAHeading() {
        XCTAssertTrue(markerRanges(styled("issue #42 is open")).isEmpty)
    }

    // MARK: - Marker visibility

    func testMarkersHideWhenTheCursorIsOutsideTheElement() {
        let storage = styled("**bold** trailing text")
        MarkdownStyler.updateMarkerVisibility(in: storage, selection: NSRange(location: 15, length: 0))

        let leadMarker = try? XCTUnwrap(markerRanges(storage).first)
        let hidden = storage.attribute(.mdHidden, at: leadMarker?.location ?? 0, effectiveRange: nil)
        XCTAssertNotNil(hidden, "markers should collapse when the cursor is elsewhere")
    }

    func testMarkersStayVisibleWhileTheCursorIsInsideTheElement() {
        let storage = styled("**bold** trailing text")
        MarkdownStyler.updateMarkerVisibility(in: storage, selection: NSRange(location: 4, length: 0))

        let leadMarker = markerRanges(storage).first ?? NSRange(location: 0, length: 0)
        let hidden = storage.attribute(.mdHidden, at: leadMarker.location, effectiveRange: nil)
        XCTAssertNil(hidden, "markers should stay visible while editing inside the element")
    }

    func testVisibilityRecomputesWhenTheCursorMovesAway() {
        let storage = styled("**bold** trailing text")
        MarkdownStyler.updateMarkerVisibility(in: storage, selection: NSRange(location: 4, length: 0))
        MarkdownStyler.updateMarkerVisibility(in: storage, selection: NSRange(location: 18, length: 0))

        let leadMarker = markerRanges(storage).first ?? NSRange(location: 0, length: 0)
        XCTAssertNotNil(storage.attribute(.mdHidden, at: leadMarker.location, effectiveRange: nil),
                        "stale visible state left behind after the cursor moved out")
    }

    // MARK: - Restyling

    func testRestylingIsIdempotent() {
        let storage = styled("**bold** and *italic* and `code`")
        let first = markerRanges(storage)
        MarkdownStyler.apply(to: storage)
        XCTAssertEqual(markerRanges(storage), first, "re-applying styles should not accumulate state")
    }

    func testRestylingClearsMarkersFromRemovedSyntax() {
        let storage = styled("**bold**")
        XCTAssertFalse(markerRanges(storage).isEmpty)

        storage.replaceCharacters(in: fullRange(storage), with: "plain")
        MarkdownStyler.apply(to: storage)
        XCTAssertTrue(markerRanges(storage).isEmpty, "markers from the old text were not cleared")
    }

    func testALongMixedDocumentStylesWithoutCrashing() {
        let source = """
        # Heading
        Some **bold**, some *italic*, some `code`, some ~~struck~~.
        - [ ] a task with 🎉
        - [x] a done task with café
        > a quote
        ```
        fenced code block
        ```
        Final ***nested*** line.
        """
        let storage = styled(source)
        XCTAssertGreaterThan(markerRanges(storage).count, 0)
        XCTAssertTrue(traits(storage, at: index(of: "nested", in: source)).contains(.bold))
    }
}
