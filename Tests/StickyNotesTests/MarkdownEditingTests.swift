import XCTest
@testable import StickyNotesKit

final class MarkdownEditingTests: XCTestCase {

    /// Writes the caret as `|` and a selection as `[...]`, so expectations read
    /// as what the user would see rather than as index arithmetic.
    private func parse(_ annotated: String) -> (String, NSRange) {
        if let caret = annotated.range(of: "|") {
            var text = annotated
            text.removeSubrange(caret)
            let offset = annotated.distance(from: annotated.startIndex, to: caret.lowerBound)
            let prefix = String(annotated.prefix(offset))
            return (text, NSRange(location: (prefix as NSString).length, length: 0))
        }
        guard let open = annotated.range(of: "["), let close = annotated.range(of: "]") else {
            return (annotated, NSRange(location: 0, length: 0))
        }
        let inner = String(annotated[annotated.index(after: open.lowerBound)..<close.lowerBound])
        let before = String(annotated[..<open.lowerBound])
        let after = String(annotated[annotated.index(after: close.lowerBound)...])
        return (before + inner + after,
                NSRange(location: (before as NSString).length, length: (inner as NSString).length))
    }

    private func render(_ edit: MarkdownEditing.Edit) -> String {
        let ns = edit.text as NSString
        if edit.selection.length == 0 {
            return ns.substring(to: edit.selection.location) + "|" + ns.substring(from: edit.selection.location)
        }
        let before = ns.substring(to: edit.selection.location)
        let inner = ns.substring(with: edit.selection)
        let after = ns.substring(from: edit.selection.location + edit.selection.length)
        return before + "[" + inner + "]" + after
    }

    private func indent(_ annotated: String) -> String {
        let (text, selection) = parse(annotated)
        return render(MarkdownEditing.indent(text, selection: selection))
    }

    private func outdent(_ annotated: String) -> String {
        let (text, selection) = parse(annotated)
        return render(MarkdownEditing.outdent(text, selection: selection))
    }

    private func wrap(_ annotated: String, _ marker: String) -> String {
        let (text, selection) = parse(annotated)
        return render(MarkdownEditing.toggleWrap(text, selection: selection, marker: marker))
    }

    private func toggleCheckbox(_ annotated: String) -> String {
        let (text, selection) = parse(annotated)
        return render(MarkdownEditing.toggleCheckbox(text, selection: selection))
    }

    // MARK: - Indent

    func testIndentAddsOneLevelToTheCurrentLine() {
        XCTAssertEqual(indent("- item|"), "  - item|")
    }

    func testIndentMovesTheCaretWithTheText() {
        XCTAssertEqual(indent("- it|em"), "  - it|em")
    }

    func testIndentAppliesToEveryLineInASelection() {
        XCTAssertEqual(indent("[- one\n- two]"), "[  - one\n  - two]")
    }

    func testIndentIsCumulative() {
        XCTAssertEqual(indent(indent("- item|")), "    - item|")
    }

    func testIndentLeavesOtherLinesAlone() {
        XCTAssertEqual(indent("- one|\n- two"), "  - one|\n- two")
    }

    // MARK: - Outdent

    func testOutdentRemovesOneLevel() {
        XCTAssertEqual(outdent("  - item|"), "- item|")
    }

    func testOutdentOnAnUnindentedLineDoesNothing() {
        XCTAssertEqual(outdent("- item|"), "- item|")
    }

    func testOutdentHandlesTabIndentation() {
        XCTAssertEqual(outdent("\t- item|"), "- item|")
    }

    func testOutdentHandlesASingleStraySpace() {
        XCTAssertEqual(outdent(" - item|"), "- item|")
    }

    func testOutdentAppliesToEveryLineInASelection() {
        XCTAssertEqual(outdent("[  - one\n  - two]"), "[- one\n- two]")
    }

    func testIndentThenOutdentRoundTrips() {
        let original = "- item|"
        XCTAssertEqual(outdent(indent(original)), original)
    }

    func testOutdentDoesNotPullTheCaretIntoThePreviousLine() {
        // Caret at the very start of an unindentable line.
        XCTAssertEqual(outdent("first\n|- item"), "first\n|- item")
    }

    // MARK: - List detection

    func testListLinesAreRecognized() {
        for line in ["- item", "* item", "+ item", "1. item", "  - nested", "\t- tabbed", "12. item"] {
            let (text, selection) = parse(line + "|")
            XCTAssertTrue(MarkdownEditing.isListLine(text, selection: selection), "\(line) should be a list line")
        }
    }

    func testNonListLinesAreNotRecognized() {
        for line in ["plain text", "# heading", "1.no space", "-nospace", ""] {
            let (text, selection) = parse(line + "|")
            XCTAssertFalse(MarkdownEditing.isListLine(text, selection: selection), "\(line) should not be a list line")
        }
    }

    // MARK: - Emphasis

    func testWrappingASelectionAddsMarkers() {
        XCTAssertEqual(wrap("say [hello] there", "**"), "say **[hello]** there")
    }

    func testWrappingKeepsTheSameTextSelected() {
        let (text, selection) = parse("say [hello] there")
        let edit = MarkdownEditing.toggleWrap(text, selection: selection, marker: "**")
        XCTAssertEqual((edit.text as NSString).substring(with: edit.selection), "hello")
    }

    func testWrappingAnEmptySelectionPutsTheCaretBetweenTheMarkers() {
        XCTAssertEqual(wrap("say | there", "**"), "say **|** there")
    }

    func testUnwrappingWhenTheMarkersAreInsideTheSelection() {
        XCTAssertEqual(wrap("say [**hello**] there", "**"), "say [hello] there")
    }

    func testUnwrappingWhenTheMarkersAreOutsideTheSelection() {
        XCTAssertEqual(wrap("say **[hello]** there", "**"), "say [hello] there")
    }

    func testWrapIsItsOwnInverse() {
        let original = "say [hello] there"
        XCTAssertEqual(wrap(wrap(original, "**"), "**"), original)
    }

    func testItalicAndCodeUseTheirOwnMarkers() {
        XCTAssertEqual(wrap("say [hello] there", "*"), "say *[hello]* there")
        XCTAssertEqual(wrap("say [hello] there", "`"), "say `[hello]` there")
    }

    /// Bold inside italic must not be mistaken for an existing bold wrap.
    func testItalicMarkersDoNotUnwrapBold() {
        XCTAssertEqual(wrap("*[hello]*", "**"), "***[hello]***")
    }

    func testWrappingAtTheVeryStartOfTheTextDoesNotUnderflow() {
        XCTAssertEqual(wrap("[hello] there", "**"), "**[hello]** there")
    }

    func testWrappingAtTheVeryEndOfTheTextDoesNotOverflow() {
        XCTAssertEqual(wrap("there [hello]", "**"), "there **[hello]**")
    }

    // MARK: - Checkbox toggling

    func testPlainLineBecomesAnUncheckedTask() {
        XCTAssertEqual(toggleCheckbox("buy milk|"), "- [ ] buy milk|")
    }

    func testBulletBecomesAnUncheckedTask() {
        XCTAssertEqual(toggleCheckbox("- buy milk|"), "- [ ] buy milk|")
    }

    func testUncheckedTaskBecomesChecked() {
        XCTAssertEqual(toggleCheckbox("- [ ] buy milk|"), "- [x] buy milk|")
    }

    func testCheckedTaskBecomesUnchecked() {
        XCTAssertEqual(toggleCheckbox("- [x] buy milk|"), "- [ ] buy milk|")
    }

    func testCapitalXCountsAsChecked() {
        XCTAssertEqual(toggleCheckbox("- [X] buy milk|"), "- [ ] buy milk|")
    }

    func testTogglingPreservesIndentation() {
        XCTAssertEqual(toggleCheckbox("  - buy milk|"), "  - [ ] buy milk|")
    }

    func testTogglingOnlyAffectsTheCurrentLine() {
        XCTAssertEqual(toggleCheckbox("- [ ] one|\n- [ ] two"), "- [x] one|\n- [ ] two")
    }

    func testTogglingAnEmptyLineStartsATask() {
        XCTAssertEqual(toggleCheckbox("|"), "- [ ] |")
    }

    func testTogglingTwiceReturnsToTheUncheckedTask() {
        XCTAssertEqual(toggleCheckbox(toggleCheckbox("- [ ] milk|")), "- [ ] milk|")
    }

    // MARK: - Progress

    func testProgressCountsCheckedAndTotal() {
        let progress = MarkdownEditing.checkboxProgress(in: "- [x] a\n- [ ] b\n- [x] c")
        XCTAssertEqual(progress?.done, 2)
        XCTAssertEqual(progress?.total, 3)
    }

    func testProgressIsNilWithoutTasks() {
        XCTAssertNil(MarkdownEditing.checkboxProgress(in: "just some notes\n- a bullet"))
        XCTAssertNil(MarkdownEditing.checkboxProgress(in: ""))
    }

    func testProgressCountsIndentedTasks() {
        let progress = MarkdownEditing.checkboxProgress(in: "- [ ] a\n  - [x] nested")
        XCTAssertEqual(progress?.total, 2)
        XCTAssertEqual(progress?.done, 1)
    }

    func testProgressAcceptsCapitalX() {
        XCTAssertEqual(MarkdownEditing.checkboxProgress(in: "- [X] a")?.done, 1)
    }

    func testProgressIgnoresCheckboxLikeTextMidLine() {
        XCTAssertNil(MarkdownEditing.checkboxProgress(in: "see - [ ] in the middle"),
                     "a task marker only counts at the start of a line")
    }

    func testProgressOnAllDoneList() {
        let progress = MarkdownEditing.checkboxProgress(in: "- [x] a\n- [x] b")
        XCTAssertEqual(progress?.done, 2)
        XCTAssertEqual(progress?.total, 2)
    }
}
