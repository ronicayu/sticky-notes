import XCTest
@testable import StickyNotesKit

final class DailyNoteTests: XCTestCase {

    /// A fixed, timezone-stable reference point: Wednesday 4 March 2026.
    private let reference: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 4
        comps.hour = 12; comps.minute = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: comps)!
    }()

    private var utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }()

    // MARK: - Path pattern rendering

    func testRendersTheCommonDailyNotePattern() {
        XCTAssertEqual(
            DailyNote.render("Daily/{YYYY}-{MM}-{DD}.md", date: reference, calendar: utc),
            "Daily/2026-03-04.md"
        )
    }

    func testRendersNestedFolderPatterns() {
        XCTAssertEqual(
            DailyNote.render("{YYYY}/{MM}/{YYYY}-{MM}-{DD}.md", date: reference, calendar: utc),
            "2026/03/2026-03-04.md"
        )
    }

    func testPaddedAndUnpaddedTokensDiffer() {
        XCTAssertEqual(DailyNote.render("{M}-{D}", date: reference, calendar: utc), "3-4")
        XCTAssertEqual(DailyNote.render("{MM}-{DD}", date: reference, calendar: utc), "03-04")
    }

    func testTwoDigitYearToken() {
        XCTAssertEqual(DailyNote.render("{YY}", date: reference, calendar: utc), "26")
    }

    /// `{YY}` must not eat the front of `{YYYY}` — the reason replacement is
    /// ordered longest-first.
    func testLongerTokensWinOverShorterPrefixes() {
        XCTAssertEqual(DailyNote.render("{YYYY}", date: reference, calendar: utc), "2026")
        XCTAssertEqual(DailyNote.render("{YYYY}{YY}", date: reference, calendar: utc), "202626")
        XCTAssertEqual(DailyNote.render("{MM}{M}", date: reference, calendar: utc), "033")
        XCTAssertEqual(DailyNote.render("{dddd}{ddd}", date: reference, calendar: utc), "WednesdayWed")
    }

    func testWeekdayTokens() {
        XCTAssertEqual(DailyNote.render("{dddd}", date: reference, calendar: utc), "Wednesday")
        XCTAssertEqual(DailyNote.render("{ddd}", date: reference, calendar: utc), "Wed")
    }

    func testUnknownTokensPassThroughUnchanged() {
        XCTAssertEqual(
            DailyNote.render("{YYYY}-{QQ}.md", date: reference, calendar: utc),
            "2026-{QQ}.md",
            "an unrecognized token should stay visible so the user can spot the typo"
        )
    }

    func testPatternWithoutTokensIsReturnedVerbatim() {
        XCTAssertEqual(DailyNote.render("Inbox/today.md", date: reference, calendar: utc), "Inbox/today.md")
    }

    func testEmptyPatternRendersEmpty() {
        XCTAssertEqual(DailyNote.render("", date: reference, calendar: utc), "")
    }

    // MARK: - moment.js -> ICU translation

    func testTranslatesCommonMomentDateFormats() {
        XCTAssertEqual(DailyNote.momentToICU("YYYY-MM-DD"), "yyyy-MM-dd")
        XCTAssertEqual(DailyNote.momentToICU("DD/MM/YYYY"), "dd/MM/yyyy")
        XCTAssertEqual(DailyNote.momentToICU("YY"), "yy")
    }

    func testTranslatesTimeFormats() {
        XCTAssertEqual(DailyNote.momentToICU("HH:mm"), "HH:mm")
        XCTAssertEqual(DailyNote.momentToICU("h:mm A"), "h:mm a")
        XCTAssertEqual(DailyNote.momentToICU("HH:mm:ss"), "HH:mm:ss")
    }

    func testTranslatesWeekdayAndMonthNameFormats() {
        XCTAssertEqual(DailyNote.momentToICU("dddd"), "EEEE")
        XCTAssertEqual(DailyNote.momentToICU("ddd"), "EEE")
        XCTAssertEqual(DailyNote.momentToICU("MMMM"), "MMMM")
        XCTAssertEqual(DailyNote.momentToICU("MMM"), "MMM")
    }

    func testBracketEscapesBecomeQuotedLiterals() {
        XCTAssertEqual(DailyNote.momentToICU("[Week of] YYYY"), "'Week of' yyyy")
    }

    func testStrayLettersAreQuotedSoDateFormatterDoesNotReinterpretThem() {
        // 'z' is not a moment token we map; leaving it bare would make
        // DateFormatter emit a timezone name.
        XCTAssertEqual(DailyNote.momentToICU("z"), "'z'")
    }

    func testPunctuationAndSeparatorsPassThrough() {
        XCTAssertEqual(DailyNote.momentToICU("YYYY.MM.DD"), "yyyy.MM.dd")
        XCTAssertEqual(DailyNote.momentToICU("YYYY_MM_DD"), "yyyy_MM_dd")
    }

    /// The translated pattern has to actually work in DateFormatter.
    func testTranslatedPatternProducesTheExpectedString() {
        let formatter = DateFormatter()
        formatter.calendar = utc
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = DailyNote.momentToICU("YYYY-MM-DD")
        XCTAssertEqual(formatter.string(from: reference), "2026-03-04")

        formatter.dateFormat = DailyNote.momentToICU("[Week of] dddd")
        XCTAssertEqual(formatter.string(from: reference), "Week of Wednesday")
    }

    // MARK: - Template token expansion

    private func expand(_ template: String, file: String = "2026-03-04.md") -> String {
        DailyNote.expandTokens(
            in: template,
            for: reference,
            fileURL: URL(fileURLWithPath: "/vault/Daily/\(file)")
        )
    }

    func testTitleTokenComesFromTheFilename() {
        XCTAssertEqual(expand("# {{title}}"), "# 2026-03-04")
    }

    func testTitleTokenToleratesWhitespaceAndCasing() {
        XCTAssertEqual(expand("{{ Title }}"), "2026-03-04")
        XCTAssertEqual(expand("{{TITLE}}"), "2026-03-04")
    }

    func testUnknownTokensAreLeftInPlace() {
        XCTAssertEqual(
            expand("{{title}} {{weather}}"),
            "2026-03-04 {{weather}}",
            "unrecognized tokens should survive so the user can see and fix them"
        )
    }

    func testTemplateWithoutTokensIsUnchanged() {
        let template = "## Tasks\n\n- [ ] \n\n## Notes\n"
        XCTAssertEqual(expand(template), template)
    }

    func testDateTokenIsReplacedWithSomethingDateShaped() {
        // Exact digits depend on the machine's calendar/locale, so assert the
        // shape rather than a literal — the ICU translation itself is covered
        // by testTranslatedPatternProducesTheExpectedString.
        let out = expand("{{date}}")
        XCTAssertFalse(out.contains("{{"), "token was not expanded: \(out)")
        XCTAssertNotNil(out.range(of: #"^\d{2,4}-\d{2}-\d{2}$"#, options: .regularExpression),
                        "expected an ISO-ish date, got \(out)")
    }

    func testDateTokenHonorsAnExplicitFormat() {
        let out = expand("{{date:YYYY}}")
        XCTAssertNotNil(out.range(of: #"^\d{4}$"#, options: .regularExpression), "got \(out)")
    }

    func testYesterdayAndTomorrowDifferFromToday() {
        let today = expand("{{date}}")
        XCTAssertNotEqual(expand("{{yesterday}}"), today)
        XCTAssertNotEqual(expand("{{tomorrow}}"), today)
        XCTAssertNotEqual(expand("{{yesterday}}"), expand("{{tomorrow}}"))
    }

    func testMultipleTokensOnOneLineAllExpand() {
        let out = expand("{{yesterday}} <- {{title}} -> {{tomorrow}}")
        XCTAssertFalse(out.contains("{{"), "some tokens were left unexpanded: \(out)")
        XCTAssertTrue(out.contains("2026-03-04"))
    }

    func testExpansionDoesNotCorruptSurroundingText() {
        let out = expand("before {{title}} after")
        XCTAssertEqual(out, "before 2026-03-04 after")
    }

    // MARK: - Window state

    func testDefaultStateIsHiddenAndExpanded() {
        let state = DailyNoteState.defaultState
        XCTAssertFalse(state.visible)
        XCTAssertFalse(state.collapsed)
        XCTAssertEqual(state.color, .yellow)
    }

    func testStateRoundTripsThroughJSON() throws {
        var state = DailyNoteState.defaultState
        state.visible = true
        state.collapsed = true
        state.color = .blue
        state.positionX = 42

        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(DailyNoteState.self, from: data)

        XCTAssertTrue(back.visible)
        XCTAssertTrue(back.collapsed)
        XCTAssertEqual(back.color, .blue)
        XCTAssertEqual(back.positionX, 42)
    }

    func testStateDecodesWhenNewerFieldsAreMissing() throws {
        // A file written before `visible` / `collapsed` existed.
        let legacy = """
        {"positionX": 10, "positionY": 20, "width": 300, "height": 400, "colorRaw": "pink"}
        """
        let state = try JSONDecoder().decode(DailyNoteState.self, from: Data(legacy.utf8))
        XCTAssertEqual(state.color, .pink)
        XCTAssertFalse(state.visible, "missing flags should default rather than throw")
        XCTAssertFalse(state.collapsed)
    }

    func testUnknownColorFallsBackToYellow() throws {
        let raw = """
        {"positionX": 0, "positionY": 0, "width": 1, "height": 1, "colorRaw": "chartreuse"}
        """
        let state = try JSONDecoder().decode(DailyNoteState.self, from: Data(raw.utf8))
        XCTAssertEqual(state.color, .yellow)
    }
}
