import AppKit
import XCTest
@testable import StickyNotesKit

final class MarkdownLinkTests: XCTestCase {

    private func styled(_ source: String) -> NSTextStorage {
        let storage = NSTextStorage(string: source)
        MarkdownStyler.apply(to: storage)
        return storage
    }

    private func link(_ storage: NSTextStorage, at index: Int) -> URL? {
        let value = storage.attribute(.link, at: index, effectiveRange: nil)
        return (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
    }

    private func index(of needle: String, in haystack: String) -> Int {
        (haystack as NSString).range(of: needle).location
    }

    private func markerSubstrings(_ storage: NSTextStorage) -> [String] {
        var out: [String] = []
        let ns = storage.string as NSString
        storage.enumerateAttribute(.mdMarkerScope, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { out.append(ns.substring(with: range)) }
        }
        return out
    }

    // MARK: - Bare URLs

    func testBareHTTPSURLBecomesALink() {
        let source = "see https://example.com for details"
        let storage = styled(source)
        XCTAssertEqual(link(storage, at: index(of: "https", in: source))?.absoluteString, "https://example.com")
    }

    func testBareURLIsStyledAsALink() {
        let source = "see https://example.com now"
        let storage = styled(source)
        let at = index(of: "https", in: source)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor,
                       MarkdownStyler.linkColor)
        XCTAssertNotNil(storage.attribute(.underlineStyle, at: at, effectiveRange: nil))
    }

    func testPlainProseGetsNoLink() {
        let storage = styled("nothing linkable here at all")
        XCTAssertNil(link(storage, at: 3))
    }

    func testURLInsideACodeSpanIsNotLinked() {
        let source = "run `curl https://example.com` now"
        let storage = styled(source)
        XCTAssertNil(link(storage, at: index(of: "https", in: source)),
                     "code spans are deliberately literal")
    }

    // MARK: - Markdown links

    func testMarkdownLinkAppliesTheDestinationToTheVisibleText() {
        let source = "read [the docs](https://example.com/docs) today"
        let storage = styled(source)
        XCTAssertEqual(link(storage, at: index(of: "the docs", in: source))?.absoluteString,
                       "https://example.com/docs")
    }

    func testMarkdownLinkHidesItsSyntaxAsMarkers() {
        let source = "read [the docs](https://example.com) today"
        let storage = styled(source)
        XCTAssertEqual(markerSubstrings(storage), ["[", "](https://example.com)"],
                       "the bracket and the destination should collapse together")
    }

    func testMarkdownLinkMarkersHideWhenTheCaretIsElsewhere() {
        let source = "read [the docs](https://example.com) today"
        let storage = styled(source)
        MarkdownStyler.updateMarkerVisibility(in: storage, selection: NSRange(location: 0, length: 0))

        let destination = index(of: "](", in: source)
        XCTAssertNotNil(storage.attribute(.mdHidden, at: destination, effectiveRange: nil))
    }

    func testMarkdownLinkMarkersStayVisibleWhileEditingTheLink() {
        let source = "read [the docs](https://example.com) today"
        let storage = styled(source)
        MarkdownStyler.updateMarkerVisibility(
            in: storage,
            selection: NSRange(location: index(of: "the docs", in: source), length: 0)
        )
        let destination = index(of: "](", in: source)
        XCTAssertNil(storage.attribute(.mdHidden, at: destination, effectiveRange: nil))
    }

    func testMarkdownLinkTextKeepsInlineEmphasis() {
        let source = "read [**bold link**](https://example.com)"
        let storage = styled(source)
        let at = index(of: "bold link", in: source)
        let font = storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        XCTAssertNotNil(link(storage, at: at))
    }

    func testLinkWithNonASCIITextIsMeasuredCorrectly() {
        let source = "café [naïve link](https://example.com) end"
        let storage = styled(source)
        XCTAssertEqual(markerSubstrings(storage), ["[", "](https://example.com)"],
                       "UTF-8 to UTF-16 offset mapping drifted")
        XCTAssertNotNil(link(storage, at: index(of: "naïve", in: source)))
    }

    func testBracketedTextThatIsNotALinkIsLeftAlone() {
        let storage = styled("a [bracketed] phrase")
        XCTAssertTrue(markerSubstrings(storage).isEmpty)
        XCTAssertNil(link(storage, at: 3))
    }

    func testRestylingDoesNotAccumulateLinkMarkers() {
        let storage = styled("read [docs](https://example.com)")
        let first = markerSubstrings(storage)
        MarkdownStyler.apply(to: storage)
        XCTAssertEqual(markerSubstrings(storage), first)
    }

    func testMarkdownLinkInsideAListItemStillLinks() {
        let source = "- [the docs](https://example.com)"
        let storage = styled(source)
        XCTAssertNotNil(link(storage, at: index(of: "the docs", in: source)))
    }

    /// A checkbox line starts with `- [ ] `, which looks like the beginning of
    /// a markdown link. The two must not be confused.
    func testCheckboxLinesAreNotTreatedAsLinks() {
        let storage = styled("- [ ] buy milk\n- [x] eggs")
        XCTAssertNil(link(storage, at: 0))
        XCTAssertNil(link(storage, at: 16))
    }
}
