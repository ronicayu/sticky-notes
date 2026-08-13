import XCTest
@testable import StickyNotesKit

final class NoteLabelTests: XCTestCase {

    func testLowercasesAndTrims() {
        XCTAssertEqual(NoteLabel.normalize("  Work  "), "work")
    }

    func testDropsASingleLeadingHash() {
        XCTAssertEqual(NoteLabel.normalize("#work"), "work")
        XCTAssertEqual(NoteLabel.normalize("##work"), "work", "the second # is stripped as punctuation")
    }

    func testCollapsesInternalWhitespaceToHyphens() {
        XCTAssertEqual(NoteLabel.normalize("deep    work"), "deep-work")
        XCTAssertEqual(NoteLabel.normalize("a\tb"), "a-b")
    }

    func testKeepsHyphensUnderscoresAndDigits() {
        XCTAssertEqual(NoteLabel.normalize("q3-2026_plan"), "q3-2026_plan")
    }

    func testStripsPunctuation() {
        XCTAssertEqual(NoteLabel.normalize("work!@$%"), "work")
        XCTAssertEqual(NoteLabel.normalize("to/do"), "todo")
    }

    func testKeepsNonLatinLetters() {
        XCTAssertEqual(NoteLabel.normalize("日本語"), "日本語")
        XCTAssertEqual(NoteLabel.normalize("Café"), "café")
    }

    func testEmptyAndPunctuationOnlyInputNormalizeToEmpty() {
        XCTAssertEqual(NoteLabel.normalize(""), "")
        XCTAssertEqual(NoteLabel.normalize("   "), "")
        XCTAssertEqual(NoteLabel.normalize("#"), "")
        XCTAssertEqual(NoteLabel.normalize("!!!"), "")
    }

    func testIsIdempotent() {
        for input in ["#Deep Work", "q3-2026", "  Mixed Case  ", "日本語", "a/b c"] {
            let once = NoteLabel.normalize(input)
            XCTAssertEqual(NoteLabel.normalize(once), once,
                           "normalizing \(input.debugDescription) twice changed the result")
        }
    }

    func testVariantsOfTheSameLabelConverge() {
        let variants = ["Deep Work", "#deep work", "  DEEP   WORK  ", "#Deep-Work"]
        let normalized = Set(variants.map(NoteLabel.normalize))
        XCTAssertEqual(normalized, ["deep-work"], "got \(normalized)")
    }
}
