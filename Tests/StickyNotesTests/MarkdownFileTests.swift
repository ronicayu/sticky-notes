import XCTest
@testable import StickyNotesKit

final class MarkdownFileTests: XCTestCase {

    // MARK: - Parsing

    func testParsesFrontmatterAndBody() {
        let raw = """
        ---
        id: ABC
        color: blue
        ---

        Body line one
        Body line two
        """
        let doc = MarkdownFile.parse(raw)
        XCTAssertEqual(doc.value(for: "id"), "ABC")
        XCTAssertEqual(doc.value(for: "color"), "blue")
        XCTAssertEqual(doc.body, "Body line one\nBody line two")
    }

    func testTreatsWholeInputAsBodyWhenFrontmatterMissing() {
        let raw = "no frontmatter here\njust text"
        let doc = MarkdownFile.parse(raw)
        XCTAssertTrue(doc.frontmatter.isEmpty)
        XCTAssertEqual(doc.body, raw)
    }

    func testUnquotesDoubleQuotedValuesAndUnescapes() {
        let raw = """
        ---
        title: "Tom said \\"hi\\""
        note: "line\\nbreak"
        ---

        body
        """
        let doc = MarkdownFile.parse(raw)
        XCTAssertEqual(doc.value(for: "title"), #"Tom said "hi""#)
        XCTAssertEqual(doc.value(for: "note"), "line\nbreak")
    }

    func testUnquotesSingleQuotedValuesLiterally() {
        let doc = MarkdownFile.parse("---\ntitle: 'a\\nb'\n---\n\nbody")
        // Single-quoted YAML does not process escapes.
        XCTAssertEqual(doc.value(for: "title"), #"a\nb"#)
    }

    /// A value containing a colon — the exact case that made an unquoted title
    /// truncate before quoting was forced on write.
    func testValueKeepsEverythingAfterTheFirstColon() {
        let doc = MarkdownFile.parse("---\ntitle: Meeting: Q3 plan\n---\n\nbody")
        XCTAssertEqual(doc.value(for: "title"), "Meeting: Q3 plan")
    }

    func testSkipsMalformedLinesWithoutLosingLaterKeys() {
        let raw = """
        ---
        id: ABC
        this line has no colon
        : empty key
        color: pink
        ---

        body
        """
        let doc = MarkdownFile.parse(raw)
        XCTAssertEqual(doc.value(for: "id"), "ABC")
        XCTAssertEqual(doc.value(for: "color"), "pink")
        XCTAssertEqual(doc.frontmatter.count, 2, "malformed lines should be dropped, not stored")
    }

    func testUnterminatedFrontmatterConsumesRestOfDocument() {
        // No closing `---`. Every key line is absorbed; body ends up empty.
        // Documenting the behavior so a future change to it is deliberate.
        let doc = MarkdownFile.parse("---\nid: ABC\nbody text\n")
        XCTAssertEqual(doc.value(for: "id"), "ABC")
        XCTAssertEqual(doc.body, "")
    }

    func testDropsExactlyOneBlankLineAfterFrontmatter() {
        let oneGap = MarkdownFile.parse("---\nid: A\n---\n\nbody")
        XCTAssertEqual(oneGap.body, "body")

        let twoGaps = MarkdownFile.parse("---\nid: A\n---\n\n\nbody")
        XCTAssertEqual(twoGaps.body, "\nbody", "only the cosmetic gap is dropped")

        let noGap = MarkdownFile.parse("---\nid: A\n---\nbody")
        XCTAssertEqual(noGap.body, "body")
    }

    func testEmptyBodyParsesAsEmptyString() {
        let doc = MarkdownFile.parse("---\nid: A\n---\n\n")
        XCTAssertEqual(doc.body, "")
    }

    // MARK: - Serializing

    func testSerializeThenParseRoundTrips() {
        let pairs: [(String, String)] = [
            ("id", "3F2504E0-4F89-11D3-9A0C-0305E82C3301"),
            ("title", "Groceries"),
            ("color", "green"),
            ("labels", "[home, errands]"),
            ("collapsed", "false")
        ]
        let body = "- [ ] milk\n- [x] eggs\n\nnote to self"
        let raw = MarkdownFile.serialize(MarkdownFile.Document(frontmatter: pairs, body: body))
        let back = MarkdownFile.parse(raw)

        for (key, value) in pairs {
            XCTAssertEqual(back.value(for: key), value, "key \(key) did not survive the round trip")
        }
        XCTAssertEqual(back.body, body)
    }

    func testFlowListsArePassedThroughUnquoted() {
        let raw = MarkdownFile.serialize(
            MarkdownFile.Document(frontmatter: [("labels", "[a, b]")], body: "")
        )
        XCTAssertTrue(raw.contains("labels: [a, b]"), "flow list should stay raw YAML, got:\n\(raw)")
    }

    func testRiskyValuesGetQuotedAndSurviveRoundTrip() {
        // Each of these would parse as something other than a plain string if
        // emitted bare.
        let risky = [
            "Meeting: Q3",     // colon
            "#hashtag start",  // comment marker
            "- leading dash",  // list item
            " padded ",        // significant whitespace
            ""                 // empty
        ]
        for value in risky {
            let raw = MarkdownFile.serialize(
                MarkdownFile.Document(frontmatter: [("title", value)], body: "b")
            )
            XCTAssertEqual(MarkdownFile.parse(raw).value(for: "title"), value,
                           "value \(value.debugDescription) did not survive")
        }
    }

    func testForceQuotedTitleSurvivesEmbeddedQuotesAndBackslashes() {
        let value = #"He said "hi" \ then left"#
        let raw = MarkdownFile.serialize(
            MarkdownFile.Document(frontmatter: [("title", value)], body: "b"),
            forceQuoteKeys: ["title"]
        )
        XCTAssertEqual(MarkdownFile.parse(raw).value(for: "title"), value)
    }

    /// Regression guard for the fix in fa40288: a title that looks like a
    /// YAML flow list must not be passed through as one.
    func testForceQuotedTitleThatLooksLikeAListIsQuoted() {
        let raw = MarkdownFile.serialize(
            MarkdownFile.Document(frontmatter: [("title", "[draft] ideas")], body: "b"),
            forceQuoteKeys: ["title"]
        )
        XCTAssertTrue(raw.contains(#"title: "[draft] ideas""#), "got:\n\(raw)")
        XCTAssertEqual(MarkdownFile.parse(raw).value(for: "title"), "[draft] ideas")
    }

    func testBodyContainingSeparatorSurvivesRoundTrip() {
        let body = "before\n\n---\n\nafter"
        let raw = MarkdownFile.serialize(
            MarkdownFile.Document(frontmatter: [("id", "A")], body: body)
        )
        XCTAssertEqual(MarkdownFile.parse(raw).body, body,
                       "a thematic break in the body must not be read as frontmatter")
    }
}
