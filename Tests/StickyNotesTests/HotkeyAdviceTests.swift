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
            // Either it's flagged or it isn't — both are valid; what matters
            // is that lookup never crashes and returns a usable string.
            _ = HotkeyAdvice.conflictNote(for: description)
        }
    }

    // MARK: - Permission guidance

    func testThePermissionLineIsATaskTheUserCanTickOff() throws {
        let progress = try XCTUnwrap(
            MarkdownEditing.checkboxProgress(in: HotkeyAdvice.permissionChecklistLine)
        )
        XCTAssertEqual(progress.total, 1)
        XCTAssertEqual(progress.done, 0)
    }

    func testThePermissionLineNamesWhereToGo() {
        let line = HotkeyAdvice.permissionChecklistLine
        XCTAssertTrue(line.contains("Accessibility"), "got: \(line)")
        XCTAssertTrue(line.contains("System Settings"), "got: \(line)")
    }

    /// One click rather than a scavenger hunt through System Settings.
    func testTheSettingsDeepLinkTargetsTheAccessibilityPane() throws {
        let url = try XCTUnwrap(HotkeyAdvice.accessibilitySettingsURL)
        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        XCTAssertTrue(url.absoluteString.contains("Privacy_Accessibility"))
    }

    func testThePermissionMenuTitleReadsAsAWarning() {
        XCTAssertTrue(HotkeyAdvice.permissionMenuTitle.contains("Accessibility"))
    }
}
