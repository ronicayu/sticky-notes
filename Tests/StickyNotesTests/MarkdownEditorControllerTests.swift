import AppKit
import XCTest
@testable import StickyNotesKit

/// The shared Markdown editor on its own: no window, no note, no `NSApp`. Typing
/// is simulated the way AppKit does it: set the text, then fire the delegate
/// callback a real keystroke would.
@MainActor final class MarkdownEditorControllerTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var clock: ManualClock!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownEditor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(rootURL: root, format: .markdown)
        clock = ManualClock()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeEditor(_ text: String = "", options: MarkdownEditorController.Options = .note) -> MarkdownEditorController {
        MarkdownEditorController(text: text, store: store, clock: clock, options: options)
    }

    private func type(_ text: String, into editor: MarkdownEditorController, caret: Int? = nil) {
        editor.textView.string = text
        editor.textView.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: editor.textView))
    }

    private func pressEnter(in editor: MarkdownEditorController) -> Bool {
        editor.textView(editor.textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    // MARK: - Typing

    func testTypingTellsTheHostTheTextBeforeItIsRestyled() {
        let editor = makeEditor()
        var heard: [String] = []
        var headingStyledWhenHeard: [Bool] = []
        editor.onTextChange = { text in
            heard.append(text)
            let size = (editor.textStorage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
            headingStyledWhenHeard.append(size > MarkdownStyler.baseFontSize)
        }

        type("# Title", into: editor)

        XCTAssertEqual(heard, ["# Title"])
        XCTAssertEqual(headingStyledWhenHeard, [false], "the host is told before the restyle")
        let size = (editor.textStorage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        XCTAssertGreaterThan(size, MarkdownStyler.baseFontSize, "the text was not restyled after the change")
    }

    func testShowingOutsideTextIsNotAnEditAndKeepsTheCaretInRange() {
        let editor = makeEditor("hello world")
        editor.textView.setSelectedRange(NSRange(location: 9, length: 0))
        var heard = 0
        editor.onTextChange = { _ in heard += 1 }

        editor.replaceText("hi")

        XCTAssertEqual(editor.textView.string, "hi")
        XCTAssertEqual(heard, 0)
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 2, length: 0))
    }

    // MARK: - Markers

    private func isCollapsed(_ editor: MarkdownEditorController, at index: Int) -> Bool {
        editor.layoutManager.ensureGlyphs(forCharacterRange: NSRange(location: 0, length: editor.textStorage.length))
        return editor.layoutManager.propertyForGlyph(at: editor.layoutManager.glyphIndexForCharacter(at: index)) == .null
    }

    func testMarkersCollapseWhenTheCaretIsElsewhereAndReturnWhenItIsInside() {
        for options in [MarkdownEditorController.Options.note, .daily] {
            let editor = makeEditor(options: options)
            type("**bold** after", into: editor, caret: 14)
            XCTAssertTrue(isCollapsed(editor, at: 0), "the opening ** stayed visible with the caret outside")

            editor.textView.setSelectedRange(NSRange(location: 4, length: 0))
            XCTAssertFalse(isCollapsed(editor, at: 0), "the ** stayed hidden with the caret inside the bold text")
        }
    }

    // MARK: - Lists

    func testEnterContinuesABulletAndANumberedItemAndATask() {
        let cases: [(String, String)] = [
            ("- milk", "- milk\n- "),
            ("* milk", "* milk\n* "),
            ("2. milk", "2. milk\n3. "),
            ("  - [x] milk", "  - [x] milk\n  - [ ] ")
        ]
        for (before, after) in cases {
            let editor = makeEditor()
            type(before, into: editor)
            XCTAssertTrue(pressEnter(in: editor), before)
            XCTAssertEqual(editor.textView.string, after)
        }
    }

    func testEnterOnAnEmptyItemEndsTheListAndLeavesTheNewlineToTheTextView() {
        let editor = makeEditor()
        type("- milk\n- ", into: editor)

        XCTAssertFalse(pressEnter(in: editor))

        XCTAssertEqual(editor.textView.string, "- milk\n")
    }

    func testEnterOutsideAListIsLeftAlone() {
        let editor = makeEditor()
        type("plain", into: editor)
        XCTAssertFalse(pressEnter(in: editor))
        XCTAssertEqual(editor.textView.string, "plain")
    }

    func testListEditingIsOffWhereTheHostDidNotAskForIt() {
        let editor = makeEditor(options: .daily)
        type("- milk", into: editor)

        XCTAssertFalse(pressEnter(in: editor))
        XCTAssertEqual(editor.textView.string, "- milk")
        XCTAssertFalse(editor.textView(editor.textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
    }

    func testTabIndentsAListLineButNotOtherText() {
        let editor = makeEditor()
        type("- milk", into: editor)
        XCTAssertTrue(editor.textView(editor.textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(editor.textView.string, "  - milk")

        let plain = makeEditor()
        type("plain", into: plain)
        XCTAssertFalse(plain.textView(plain.textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
    }

    func testUpOnTheFirstLineHandsOverToTheHostAndElsewhereMovesTheCaret() {
        let editor = makeEditor()
        var handedOver = 0
        editor.onMoveUpFromFirstLine = { handedOver += 1 }
        type("first\nsecond", into: editor, caret: 3)

        XCTAssertTrue(editor.textView(editor.textView, doCommandBy: #selector(NSResponder.moveUp(_:))))
        XCTAssertEqual(handedOver, 1)

        editor.textView.setSelectedRange(NSRange(location: 8, length: 0))
        XCTAssertFalse(editor.textView(editor.textView, doCommandBy: #selector(NSResponder.moveUp(_:))))
        XCTAssertEqual(handedOver, 1)
    }

    // MARK: - Checkboxes

    func testToggleFlipsAnUncheckedBoxAndBack() {
        let editor = makeEditor()
        type("- [ ] milk", into: editor)

        editor.textViewDidToggleCheckbox(at: 0)
        XCTAssertEqual(editor.textView.string, "- [x] milk")

        editor.textViewDidToggleCheckbox(at: 0)
        XCTAssertEqual(editor.textView.string, "- [ ] milk")
    }

    /// A note and the daily note are two hosts of one editor, so a tab-indented
    /// task toggles the same way in both.
    func testANoteAndTheDailyNoteToggleATabIndentedTaskIdentically() throws {
        _ = NSApplication.shared
        let line = "\t- [ ] call back\nnext"
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        note.content = line
        store.save(note)
        let noteWindow = NoteWindowController(note: note, store: store, clock: clock, onClosed: { _ in })
        defer { noteWindow.window?.close() }

        let isolated = IsolatedSettings()
        defer { isolated.tearDown() }
        let dailyWindow = DailyNoteWindowController(settings: isolated.settings, store: store, clock: clock)
        defer { dailyWindow.window?.close() }
        type(line, into: dailyWindow.editor)

        for editor in [noteWindow.editor, dailyWindow.editor] {
            editor.textViewDidToggleCheckbox(at: 3)
            XCTAssertEqual(editor.textView.string, "\t- [x] call back\nnext")
            editor.textViewDidToggleCheckbox(at: 3)
            XCTAssertEqual(editor.textView.string, line)
        }
    }

    func testToggleOnALineWithoutABracketChangesNothing() {
        let editor = makeEditor()
        type("no box here", into: editor)
        editor.textViewDidToggleCheckbox(at: 2)
        XCTAssertEqual(editor.textView.string, "no box here")
    }

    // MARK: - Slash menu

    func testSlashMenuEntriesUseTheInjectedClock() {
        let entries = MarkdownEditorController.dateTimeEntries(now: clock.now())
        XCTAssertEqual(entries.count, 3)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(entries[0].1, formatter.string(from: clock.now()))
        XCTAssertTrue(entries[2].1.hasPrefix(entries[0].1 + " "))
    }

    // MARK: - Text size

    func testChangingTheTextSizeRestylesTheText() {
        let editor = makeEditor("plain text")
        let original = MarkdownStyler.baseFontSize
        defer { MarkdownStyler.baseFontSize = original }

        MarkdownStyler.baseFontSize = original + 4
        editor.applyTextSize()

        let size = (editor.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
        XCTAssertEqual(size, original + 4)
        XCTAssertEqual((editor.textView.typingAttributes[.font] as? NSFont)?.pointSize, original + 4)
    }
}
