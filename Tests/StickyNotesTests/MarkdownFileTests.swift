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

    /// Without a closing `---` there is no frontmatter — the file just opens
    /// with a horizontal rule. Absorbing it as metadata left an empty body,
    /// and the next save wrote that emptiness over the user's real text.
    func testUnterminatedFrontmatterIsTreatedAsBody() {
        let raw = "---\nid: ABC\nbody text\n"
        let doc = MarkdownFile.parse(raw)
        XCTAssertNil(doc.value(for: "id"))
        XCTAssertEqual(doc.body, raw, "the document has to survive intact")
    }

    func testCRLFFrontmatterIsStillRecognized() {
        let doc = MarkdownFile.parse("---\r\nid: ABC\r\ncolor: pink\r\n---\r\n\r\nbody")
        XCTAssertEqual(doc.value(for: "id"), "ABC")
        XCTAssertEqual(doc.value(for: "color"), "pink")
        XCTAssertTrue(doc.body.contains("body"))
    }

    /// A newline in a value used to split the record, so re-reading the file
    /// truncated the title and dropped the line after it.
    func testANewlineInAValueSurvivesARoundTrip() {
        let document = MarkdownFile.Document(frontmatter: [("title", "a\nb")], body: "text")
        let raw = MarkdownFile.serialize(document, forceQuoteKeys: ["title"])
        let parsed = MarkdownFile.parse(raw)
        XCTAssertEqual(parsed.value(for: "title"), "a\nb")
        XCTAssertEqual(parsed.body, "text")
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

// MARK: - Frontmatter the app does not own

final class MarkdownFileUnknownKeyTests: XCTestCase {
    private let owned: Set<String> = ["id", "title", "labels"]

    /// Every kind of line Obsidian and its plugins put in a frontmatter.
    private let obsidianFile = """
    ---
    # written by a plugin
    id: ABC
    tags:
      - project/x
      - "needs: review"
    aliases: [Plan B, 'Plan "C"']
    cssclasses: wide-page
    nested:
      owner:
        name: Ada
        roles: [a, b]
      note: "has # and : and '--- inside'"
    summary: |
      First line
        indented line
      ---
      line after a dashed line

    title: Meeting
    quote: 'it''s'
    url: https://example.com/a?b=c#d
    labels:
      - work
      - home
    empty:
    ---

    Body text
    """

    func testFrontmatterItDoesNotUnderstandComesBackByteForByte() {
        let document = MarkdownFile.parse(obsidianFile, ownedKeys: owned)
        let written = MarkdownFile.serialize(
            document, forceQuoteKeys: [], blockListKeys: document.blockListKeys
        )
        XCTAssertEqual(written, obsidianFile)
    }

    func testAnOwnedKeyChangesInPlaceAndTheOthersStayWhereTheyWere() {
        var document = MarkdownFile.parse(obsidianFile, ownedKeys: owned)
        document.frontmatter = document.frontmatter.map { $0.0 == "title" ? ("title", "Renamed") : $0 }
        let written = MarkdownFile.serialize(document, blockListKeys: document.blockListKeys)

        XCTAssertEqual(written, obsidianFile.replacingOccurrences(of: "title: Meeting", with: "title: Renamed"))
    }

    func testAnOwnedKeyTheFileLacksIsAddedAfterTheExistingLines() {
        var document = MarkdownFile.parse("---\ntags: [a]\n---\n\nbody", ownedKeys: owned)
        document.frontmatter.append(("id", "NEW"))
        XCTAssertEqual(MarkdownFile.serialize(document), "---\ntags: [a]\nid: NEW\n---\n\nbody")
    }

    func testABlockListIsReadAsItsItems() {
        let document = MarkdownFile.parse("---\nlabels:\n  - work\n  - \"two words\"\n- odd\n---\n\nb", ownedKeys: owned)
        XCTAssertEqual(document.value(for: "labels"), "[work, two words, odd]")
        XCTAssertEqual(document.blockListKeys, ["labels"])
    }

    func testAFlowListIsNotABlockList() {
        let document = MarkdownFile.parse("---\nlabels: [a, b]\n---\n\nb", ownedKeys: owned)
        XCTAssertEqual(document.value(for: "labels"), "[a, b]")
        XCTAssertTrue(document.blockListKeys.isEmpty)
    }

    func testABlockListIsWrittenAsABlockListWhenAsked() {
        let document = MarkdownFile.Document(frontmatter: [("labels", "[a, b]")], body: "b")
        XCTAssertEqual(
            MarkdownFile.serialize(document, blockListKeys: ["labels"]),
            "---\nlabels:\n  - a\n  - b\n---\n\nb"
        )
    }

    func testAnEmptyListIsWrittenInFlowStyleEvenWhenBlockStyleIsAsked() {
        let document = MarkdownFile.Document(frontmatter: [("labels", "[]")], body: "b")
        XCTAssertEqual(MarkdownFile.serialize(document, blockListKeys: ["labels"]), "---\nlabels: []\n---\n\nb")
    }

    func testAnIndentedDashLineInsideAValueDoesNotEndTheFrontmatter() {
        let raw = "---\nnote: |\n  a\n  ---\n  b\nid: A\n---\n\nbody"
        let document = MarkdownFile.parse(raw, ownedKeys: owned)
        XCTAssertEqual(document.value(for: "id"), "A")
        XCTAssertEqual(document.body, "body")
    }

    func testAValueFoldedOverSeveralLinesIsReadAsOneLine() {
        let document = MarkdownFile.parse("---\ntitle: \"a long\n  title\"\n---\n\nb", ownedKeys: owned)
        XCTAssertEqual(document.value(for: "title"), "a long title")
    }

    func testLinesItDoesNotUnderstandAreKeptRatherThanDropped() {
        let raw = "---\nid: A\nthis line has no colon\n: empty key\n---\n\nbody"
        let document = MarkdownFile.parse(raw, ownedKeys: owned)
        XCTAssertEqual(MarkdownFile.serialize(document), raw)
    }

    func testCRLFLinesOfOtherKeysAreKeptAsTheyWere() {
        let raw = "---\r\nid: A\r\ntags:\r\n  - x\r\n---\r\n\r\nbody"
        let document = MarkdownFile.parse(raw, ownedKeys: owned)
        XCTAssertEqual(document.value(for: "id"), "A")
        XCTAssertEqual(MarkdownFile.serialize(document), "---\nid: A\ntags:\r\n  - x\r\n---\n\nbody")
    }
}
