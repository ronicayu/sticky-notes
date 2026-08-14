import KeyboardShortcuts
import XCTest
@testable import StickyNotesKit

final class HotkeyAdviceTests: XCTestCase {

    func testContestedShortcutsAreFlagged() {
        XCTAssertNotNil(HotkeyAdvice.conflictNote(for: "⌘⇧S"), "the default new-note chord is contested")
        XCTAssertNotNil(HotkeyAdvice.conflictNote(for: "⌘⇧F"))
    }

    func testUncontestedShortcutsAreNotFlagged() {
        XCTAssertNil(HotkeyAdvice.conflictNote(for: "⌃⌥⌘9"))
        XCTAssertNil(HotkeyAdvice.conflictNote(for: "F13"))
    }

    func testNoShortcutMeansNoAdvice() {
        XCTAssertNil(HotkeyAdvice.conflictNote(for: nil))
    }

    /// Recorder descriptions can carry spacing; matching shouldn't depend on it.
    func testSpacingInADescriptionIsIgnored() {
        XCTAssertEqual(HotkeyAdvice.conflictNote(for: "⌘ ⇧ S"),
                       HotkeyAdvice.conflictNote(for: "⌘⇧S"))
    }

    /// macOS renders modifiers in a fixed order, which is not the order the
    /// table happened to be written in.
    func testModifierOrderDoesNotAffectMatching() {
        XCTAssertEqual(HotkeyAdvice.conflictNote(for: "⇧⌘S"),
                       HotkeyAdvice.conflictNote(for: "⌘⇧S"))
        XCTAssertNotNil(HotkeyAdvice.conflictNote(for: "⇧⌘S"))
    }

    func testAdviceNamesSomethingConcrete() throws {
        let note = try XCTUnwrap(HotkeyAdvice.conflictNote(for: "⌘⇧S"))
        XCTAssertTrue(note.contains("Save As"), "advice should name the app command it collides with, got: \(note)")
    }

    /// The app's own defaults are the ones most likely to bite, so each should
    /// either be uncontested or carry an explanation.
    @MainActor
    func testEveryDefaultShortcutIsEitherCleanOrExplained() {
        for name in [KeyboardShortcuts.Name.newNote,
                     .quickSwitcher,
                     .notesPanel,
                     .hideAll] {
            let description = HotkeyAdvice.describe(name)
            XCTAssertNotNil(description, "\(name) has no default shortcut")
            // Feed the recorder's own rendering back in. Asserting nothing
            // here is what hid the fact that it spells chords "⇧⌘S" while
            // the conflict table was keyed "⌘⇧S", so nothing ever matched.
            XCTAssertNotNil(HotkeyAdvice.conflictNote(for: description),
                            "no advice for \(description ?? "nil")")
        }
    }
}
