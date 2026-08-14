import XCTest
@testable import StickyNotesKit

final class CaptureCommandTests: XCTestCase {

    private func parse(_ string: String) -> CaptureCommand? {
        guard let url = URL(string: string) else {
            XCTFail("\(string) is not a URL at all")
            return nil
        }
        return CaptureCommand.parse(url)
    }

    // MARK: - Rejecting things that aren't ours

    func testOtherSchemesAreIgnored() {
        XCTAssertNil(parse("https://example.com/new?text=hi"))
        XCTAssertNil(parse("obsidian://open?file=x"))
    }

    func testUnknownActionsAreIgnored() {
        XCTAssertNil(parse("stickynotes://explode"))
        XCTAssertNil(parse("stickynotes://"))
    }

    // MARK: - new

    func testNewCarriesItsText() {
        XCTAssertEqual(parse("stickynotes://new?text=buy%20milk"),
                       .new(title: nil, text: "buy milk", color: nil, labels: []))
    }

    func testNewAcceptsEveryParameter() {
        XCTAssertEqual(
            parse("stickynotes://new?title=Shopping&text=eggs&color=blue&labels=home,errands"),
            .new(title: "Shopping", text: "eggs", color: .blue, labels: ["home", "errands"])
        )
    }

    func testNewWithNoParametersIsAnEmptyNote() {
        XCTAssertEqual(parse("stickynotes://new"), .new(title: nil, text: "", color: nil, labels: []))
    }

    /// Shell scripts and older tools encode spaces as `+`, which URLComponents
    /// leaves alone — a note would otherwise arrive full of plus signs.
    func testPlusIsDecodedAsASpace() {
        XCTAssertEqual(parse("stickynotes://new?text=buy+more+milk"),
                       .new(title: nil, text: "buy more milk", color: nil, labels: []))
    }

    func testNewlinesSurviveEncoding() {
        XCTAssertEqual(parse("stickynotes://new?text=one%0Atwo"),
                       .new(title: nil, text: "one\ntwo", color: nil, labels: []))
    }

    func testLabelsAreNormalizedLikeTypedOnes() {
        guard case let .new(_, _, _, labels)? = parse("stickynotes://new?labels=%23Deep%20Work,HOME,%20,x") else {
            return XCTFail("did not parse")
        }
        XCTAssertEqual(labels, ["deep-work", "home", "x"], "empty entries should be dropped")
    }

    func testUnknownColorIsIgnoredRatherThanRejectingTheNote() {
        XCTAssertEqual(parse("stickynotes://new?text=hi&color=chartreuse"),
                       .new(title: nil, text: "hi", color: nil, labels: []))
    }

    func testColorIsCaseInsensitive() {
        XCTAssertEqual(parse("stickynotes://new?color=BLUE"),
                       .new(title: nil, text: "", color: .blue, labels: []))
    }

    func testBodyIsAcceptedAsAnAliasForText() {
        XCTAssertEqual(parse("stickynotes://new?body=hello"),
                       .new(title: nil, text: "hello", color: nil, labels: []))
    }

    func testBlankTitleIsTreatedAsAbsent() {
        XCTAssertEqual(parse("stickynotes://new?title=%20%20&text=x"),
                       .new(title: nil, text: "x", color: nil, labels: []))
    }

    func testUnknownParametersAreIgnoredRatherThanFailing() {
        XCTAssertEqual(parse("stickynotes://new?text=hi&sparkles=yes"),
                       .new(title: nil, text: "hi", color: nil, labels: []))
    }

    // MARK: - search and daily

    func testSearchCarriesItsQuery() {
        XCTAssertEqual(parse("stickynotes://search?q=groceries"), .search(query: "groceries"))
    }

    func testSearchAcceptsQueryAsAnAlias() {
        XCTAssertEqual(parse("stickynotes://search?query=groceries"), .search(query: "groceries"))
    }

    func testSearchWithNoQueryJustOpensTheSwitcher() {
        XCTAssertEqual(parse("stickynotes://search"), .search(query: ""))
    }

    func testFindIsAnAliasForSearch() {
        XCTAssertEqual(parse("stickynotes://find?q=x"), .search(query: "x"))
    }

    func testDailyOpensTheDailyNote() {
        XCTAssertEqual(parse("stickynotes://daily"), .daily)
        XCTAssertEqual(parse("stickynotes://today"), .daily)
    }

    // MARK: - Shapes people actually type

    func testActionIsCaseInsensitive() {
        XCTAssertEqual(parse("stickynotes://NEW?text=hi"),
                       .new(title: nil, text: "hi", color: nil, labels: []))
    }

    /// Foundation reports the action for `stickynotes:new` as `path` on
    /// macOS 15+, and as nothing at all on macOS 14 — where this spelling
    /// silently stopped working until the parser stopped relying on either.
    func testSchemeWithoutSlashesStillWorks() {
        XCTAssertEqual(parse("stickynotes:new?text=hi"),
                       .new(title: nil, text: "hi", color: nil, labels: []))
        XCTAssertEqual(parse("stickynotes:daily"), .daily)
    }

    func testTrailingSlashIsTolerated() {
        XCTAssertEqual(parse("stickynotes://daily/"), .daily)
        XCTAssertEqual(parse("stickynotes:daily/"), .daily)
    }

    /// Every spelling of the same command has to reach the same place, on
    /// every macOS version.
    func testEverySpellingOfACommandAgrees() {
        let expected = CaptureCommand.new(title: nil, text: "hi", color: nil, labels: [])
        for spelling in [
            "stickynotes://new?text=hi",
            "stickynotes:new?text=hi",
            "stickynotes:///new?text=hi",
            "stickynotes://NEW?text=hi",
            "stickynotes:New?text=hi"
        ] {
            XCTAssertEqual(parse(spelling), expected, "\(spelling) did not parse")
        }
    }

    func testQueryDecodingIsTheSameWithAndWithoutSlashes() {
        XCTAssertEqual(parse("stickynotes:new?text=a%20b+c"),
                       parse("stickynotes://new?text=a%20b+c"))
    }
}
