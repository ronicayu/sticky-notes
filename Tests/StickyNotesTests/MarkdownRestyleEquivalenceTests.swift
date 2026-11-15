import AppKit
import XCTest
@testable import StickyNotesKit

/// Restyling only the paragraphs an edit touched has to leave the text looking
/// exactly as a restyle of all of it would. These tests apply random edits to
/// generated notes and compare the two, attribute for attribute.
@MainActor final class MarkdownRestyleEquivalenceTests: XCTestCase {

    // MARK: - Random source

    /// SplitMix64: the same seed gives the same notes and edits on every machine.
    private struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
        mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }
        mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
    }

    private static let blocks = [
        "# Heading", "## Sub heading", "### Third level", "- item one", "* star item", "1. first", "23. later",
        "- [ ] a task", "- [x] a done task", "> a quote", "plain words on a line", "A **bold** word and *italic*",
        "***both*** here", "some ~~struck~~ text", "inline `code` and ``two`` ticks", "see [a link](https://example.com/a)",
        "a [[Wiki Note]] link", "bare https://example.org/path/x link", "party 🎉 time with café", "[ref]: https://example.com",
        "![img](a.png)", "| a | b |\n|---|---|\n| 1 | 2 |", "---", "[[x]](y)", "**[nested](u)** and `[[w]]`",
        "- [ ] **bold task** [[Note]]", "**粗体**与*斜体*和`代码`", "# 标题 二", "- [ ] 买菜，做饭", "全角：＊＊粗＊＊ ｜ ［［链接］］",
        "[链接](https://例子.cn/路径) 和 ~~删除~~", "- 项目一\n- 项目二 **加粗**", "Setext\n=====", "[ref] and [other][ref]", "tab\there", "line one\nline two\nline three"
    ]

    /// Blocks whose reading depends on other paragraphs. Rare in the notes, so
    /// most edits still take the fast path.
    private static let contextBlocks = [
        "```\nfenced **text**\n\nacross a gap\n```", "~~~\ntilde\n~~~", "<!-- comment\n\nstill comment -->",
        "<pre>\nraw\n\nraw</pre>", "- item\n\n    continued **here**", "    indented code", "  - nested later",
        "- parent\n\n  second paragraph with *emphasis*", "line\u{2028}separated", "<div>html</div>"
    ]

    private static let pieces = [
        "\n\n", "\n", " ", "**", "*", "`", "[[", "]]", "](", "[", "]", "# ", "## ", "- ", "- [ ] ", "- [x] ", "1. ", "> ",
        "x", "word", "🎉", "é", "你", "好吗", "，", "。", "＊", "粗体", "\t", "~~", "https://a.example.com", "(u)", "\n\n\n", "***", "_"
    ]

    private static let rareEditPieces = ["```", "~~~", "    ", "<!--", "<pre>", "\n\n    ", "\n\n  ", "\u{2028}"]

    private func makeNote(_ random: inout Random) -> String {
        let count = 3 + random.below(12)
        var parts: [String] = []
        for _ in 0..<count {
            parts.append(random.chance(3) ? random.pick(Self.contextBlocks) : random.pick(Self.blocks))
        }
        var text = parts[0]
        for part in parts.dropFirst() {
            text += random.pick(["\n", "\n\n", "\n\n", "\n\n", " ", "\n\n\n"]) + part
        }
        return text
    }

    /// An edit at composed-character boundaries, so no emoji is cut in half.
    private func makeEdit(in text: String, _ random: inout Random) -> (range: NSRange, replacement: String) {
        let ns = text as NSString
        func boundary(_ raw: Int) -> Int {
            raw >= ns.length ? ns.length : ns.rangeOfComposedCharacterSequence(at: raw).location
        }
        let location = boundary(random.below(ns.length + 1))
        var end = location
        if random.chance(40) {
            for _ in 0..<(1 + random.below(6)) where end < ns.length {
                end = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: end))
            }
        }
        var replacement = ""
        if end == location || random.chance(50) {
            replacement = random.chance(4) ? random.pick(Self.rareEditPieces)
                : random.chance(10) ? random.pick(Self.blocks) : random.pick(Self.pieces)
        }
        return (NSRange(location: location, length: end - location), replacement)
    }

    // MARK: - Comparing

    /// The first difference between two attributed strings, or nil. Marker scopes
    /// are compared by the range they hold.
    private func firstDifference(_ a: NSAttributedString, _ b: NSAttributedString) -> String? {
        guard a.string == b.string else { return "texts differ" }
        let length = a.length
        var position = 0
        while position < length {
            var rangeA = NSRange(), rangeB = NSRange()
            let attributesA = a.attributes(at: position, effectiveRange: &rangeA)
            let attributesB = b.attributes(at: position, effectiveRange: &rangeB)
            let keys = Set(attributesA.keys).union(attributesB.keys)
            for key in keys {
                let valueA = attributesA[key], valueB = attributesB[key]
                let same: Bool
                if let scopeA = valueA as? MarkerScope, let scopeB = valueB as? MarkerScope {
                    same = NSEqualRanges(scopeA.range, scopeB.range)
                } else if let valueA = valueA, let valueB = valueB {
                    same = (valueA as AnyObject).isEqual(valueB)
                } else {
                    same = false
                }
                if !same {
                    let near = (a.string as NSString).substring(
                        with: NSRange(location: max(0, position - 12), length: min(30, length - max(0, position - 12))))
                    return "at \(position) (near “\(near)”) attribute \(key.rawValue): "
                        + "incremental \(describe(valueA)) vs full \(describe(valueB))"
                }
            }
            position = min(NSMaxRange(rangeA), NSMaxRange(rangeB))
        }
        return nil
    }

    private func describe(_ value: Any?) -> String {
        guard let value = value else { return "none" }
        if let scope = value as? MarkerScope { return "scope \(scope.range)" }
        return "\(value)"
    }

    private func fullyStyled(_ text: String, selection: NSRange) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        MarkdownStyler.apply(to: storage)
        MarkdownStyler.updateMarkerVisibility(in: storage, selection: selection)
        return storage
    }

    // MARK: - The property

    func testIncrementalRestylingEqualsFullRestylingOverRandomEdits() {
        let restyler = MarkdownRestyler()
        var edits = 0
        for noteIndex in 0..<200 {
            let seed = UInt64(0x5EED_0000 + noteIndex)
            var random = Random(state: seed)
            let initial = makeNote(&random)
            let storage = NSTextStorage(string: initial)
            restyler.restyleAll(storage)
            var history: [String] = []

            for step in 0..<12 {
                let edit = makeEdit(in: storage.string, &random)
                storage.replaceCharacters(in: edit.range, with: edit.replacement)
                let newLength = (edit.replacement as NSString).length
                restyler.restyle(
                    storage,
                    edited: NSRange(location: edit.range.location, length: newLength),
                    changeInLength: newLength - edit.range.length
                )
                edits += 1
                history.append("replace \(edit.range) with \(edit.replacement.debugDescription)")

                let selection = NSRange(
                    location: random.below(storage.length + 1), length: random.chance(20) ? random.below(6) : 0)
                let clamped = NSIntersectionRange(selection, NSRange(location: 0, length: storage.length))
                let place = clamped.length == 0 && selection.length > 0 ? NSRange(location: selection.location, length: 0) : clamped
                MarkdownStyler.updateMarkerVisibility(in: storage, selection: place)
                let expected = fullyStyled(storage.string, selection: place)
                if let difference = firstDifference(storage, expected) {
                    XCTFail("note \(noteIndex) (seed \(seed)) step \(step): \(difference)\n"
                            + "started as: \(initial.debugDescription)\n"
                            + "history: \(history.joined(separator: "\n         "))")
                    return
                }
            }
        }
        XCTAssertGreaterThan(restyler.incrementalCount, edits * 6 / 10,
                             "most edits should take the fast path, or this test proves nothing")
        XCTAssertGreaterThan(restyler.fullCount, 200, "the notes with fences or indented blocks must fall back")
    }

    // MARK: - What must fall back

    private func assertEquivalentAfter(
        start: String, replacing range: NSRange, with replacement: String,
        expectFull: Bool, file: StaticString = #filePath, line: UInt = #line
    ) {
        let restyler = MarkdownRestyler()
        let storage = NSTextStorage(string: start)
        restyler.restyleAll(storage)
        let fullBefore = restyler.fullCount
        storage.replaceCharacters(in: range, with: replacement)
        let length = (replacement as NSString).length
        restyler.restyle(storage, edited: NSRange(location: range.location, length: length),
                         changeInLength: length - range.length)
        XCTAssertEqual(restyler.fullCount > fullBefore, expectFull, "wrong path", file: file, line: line)
        let selection = NSRange(location: 0, length: 0)
        MarkdownStyler.updateMarkerVisibility(in: storage, selection: selection)
        XCTAssertNil(firstDifference(storage, fullyStyled(storage.string, selection: selection)), file: file, line: line)
    }

    private func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    func testClosingAFenceRestylesTheTextItHadHiddenFromTheStyler() {
        let text = "intro\n\n```\n**inside** the fence\n\nmore **inside**\n```\n\nafter *this* too"
        assertEquivalentAfter(start: text, replacing: range(of: "```\n**", in: text), with: "``\n**", expectFull: true)
    }

    func testOpeningAFenceChangesTheTextAfterIt() {
        let text = "intro line\n\nfirst **bold** paragraph\n\nsecond **bold** paragraph\n\nthird *x* paragraph"
        assertEquivalentAfter(start: text, replacing: NSRange(location: 0, length: 0), with: "```\n", expectFull: true)
    }

    func testTypingBeforeAListContinuationRestylesTheContinuation() {
        let text = "- item\n\n  continued **here**\n\n  and *here*\n\nlast paragraph"
        assertEquivalentAfter(start: text, replacing: NSRange(location: 0, length: 2), with: "", expectFull: true)
    }

    func testAnHtmlCommentSpanningAGapFallsBack() {
        let text = "one\n\n<!-- start\n\n**not bold** -->\n\ntwo **bold**"
        assertEquivalentAfter(start: text, replacing: range(of: "one", in: text), with: "ones", expectFull: true)
    }

    func testAnOrdinaryEditInsideALongNoteStaysIncremental() {
        let paragraphs = (0..<30).map { "paragraph \($0) with **bold** and [a link](https://example.com/\($0)) and `code`" }
        let text = paragraphs.joined(separator: "\n\n")
        assertEquivalentAfter(start: text, replacing: range(of: "paragraph 14", in: text), with: "paragraph 14 more ", expectFull: false)
    }

    func testSplittingAParagraphWithABlankLineStaysEquivalent() {
        let paragraphs = (0..<10).map { "para \($0) has *emphasis* and **strong** text to split" }
        let text = paragraphs.joined(separator: "\n\n")
        assertEquivalentAfter(start: text, replacing: range(of: "and **strong**", in: text), with: "\n\nand **strong**", expectFull: false)
    }

    func testJoiningTwoParagraphsStaysEquivalent() {
        let paragraphs = (0..<10).map { "para \($0) has *emphasis* and **strong** text" }
        let text = paragraphs.joined(separator: "\n\n")
        assertEquivalentAfter(start: text, replacing: range(of: "\n\npara 5", in: text), with: " para 5", expectFull: false)
    }

    func testTypingAtTheEndOfTheNoteAndDeletingItAllStayEquivalent() {
        let text = (0..<6).map { "p\($0) **b** [[w]] https://example.com/x" }.joined(separator: "\n\n")
        assertEquivalentAfter(start: text, replacing: NSRange(location: (text as NSString).length, length: 0), with: "x", expectFull: false)
        assertEquivalentAfter(start: text, replacing: NSRange(location: 0, length: (text as NSString).length), with: "", expectFull: true)
    }

    // MARK: - Through the editor

    /// The editor restyles only what an edit touched and re-hides markers only
    /// where the caret was or is. Compared with styling everything from scratch.
    func testTheEditorKeepsMarkersAndAttributesRightThroughRandomEditsAndCaretMoves() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestyleEquivalence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(rootURL: root)

        for (index, options) in [MarkdownEditorController.Options.note, .daily].enumerated() {
            for noteIndex in 0..<40 {
                let seed = UInt64(0xED17_0000 + index * 1000 + noteIndex)
                var random = Random(state: seed)
                let editor = MarkdownEditorController(
                    text: makeNote(&random), store: store, clock: ManualClock(), options: options)
                let storage = editor.textStorage
                var history: [String] = []

                for step in 0..<10 {
                    if random.chance(35) {
                        editor.textView.setSelectedRange(NSRange(location: random.below(storage.length + 1), length: 0))
                    }
                    let edit = makeEdit(in: storage.string, &random)
                    guard editor.textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { continue }
                    storage.replaceCharacters(in: edit.range, with: edit.replacement)
                    editor.textView.setSelectedRange(NSRange(
                        location: edit.range.location + (edit.replacement as NSString).length, length: 0))
                    editor.textView.didChangeText()
                    history.append("replace \(edit.range) with \(edit.replacement.debugDescription)")

                    let expected = fullyStyled(storage.string, selection: editor.textView.selectedRange())
                    if let difference = firstDifference(storage, expected) {
                        XCTFail("editor \(index) note \(noteIndex) (seed \(seed)) step \(step): \(difference)\n"
                                + "text: \(storage.string.debugDescription)\n"
                                + "history: \(history.suffix(3).joined(separator: "\n         "))")
                        return
                    }
                }
                XCTAssertGreaterThan(editor.restyler.incrementalCount + editor.restyler.fullCount, 1)
            }
        }
    }

    func testUndoRestoresTheStylingToo() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestyleUndo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = (0..<8).map { "para \($0) **bold** and [link](https://example.com) here" }.joined(separator: "\n\n")
        let editor = MarkdownEditorController(
            text: text, store: NoteStore(rootURL: root), clock: ManualClock(), options: .note)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.textView
        let undo = try XCTUnwrap(editor.textView.undoManager)
        let fullBefore = editor.restyler.fullCount

        let spot = (text as NSString).range(of: "para 4").location
        editor.textView.setSelectedRange(NSRange(location: spot, length: 0))
        editor.textView.insertText("# ", replacementRange: NSRange(location: spot, length: 0))
        XCTAssertGreaterThan(editor.restyler.incrementalCount, 0, "typing should have been restyled in a slice")
        XCTAssertEqual(editor.restyler.fullCount, fullBefore)

        undo.undo()
        XCTAssertEqual(editor.textView.string, text)
        let selection = editor.textView.selectedRange()
        XCTAssertNil(firstDifference(editor.textStorage, fullyStyled(text, selection: selection)))

        undo.redo()
        XCTAssertTrue(editor.textView.string.contains("# para 4"))
        XCTAssertNil(firstDifference(
            editor.textStorage, fullyStyled(editor.textView.string, selection: editor.textView.selectedRange())))
    }

    // MARK: - Changes the delegate is never told about, and input methods

    private func makeEditor(_ text: String, options: MarkdownEditorController.Options = .note)
        throws -> (MarkdownEditorController, NSWindow, URL)
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestyleIME-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let editor = MarkdownEditorController(
            text: text, store: NoteStore(rootURL: root), clock: ManualClock(), options: options)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.textView
        return (editor, window, root)
    }

    private func assertStyledLikeAFullRestyle(
        _ editor: MarkdownEditorController, file: StaticString = #filePath, line: UInt = #line
    ) {
        let expected = fullyStyled(editor.textStorage.string, selection: editor.textView.selectedRange())
        XCTAssertNil(firstDifference(editor.textStorage, expected), file: file, line: line)
    }

    func testMarkersFollowTheCaretAfterTheTextChangedWithoutTheDelegateHearing() throws {
        let (editor, window, root) = try makeEditor("intro\n\nsome **bold** text and more\n\nlast *line* here")
        defer { _ = window; try? FileManager.default.removeItem(at: root) }
        let text = editor.textStorage.string as NSString

        // What Writing Tools or an inline prediction does: the text changes, no didChangeText.
        editor.textStorage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "introduction")
        editor.textView.setSelectedRange(NSRange(location: text.range(of: "bold").location + 9, length: 0))
        for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        assertStyledLikeAFullRestyle(editor)

        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        assertStyledLikeAFullRestyle(editor)
        let bold = (editor.textStorage.string as NSString).range(of: "**bold**")
        XCTAssertNotNil(editor.textStorage.attribute(.mdHidden, at: bold.location, effectiveRange: nil),
                        "the markers stayed shown after the caret left")
    }

    private func compose(_ pinyin: String, at location: Int, in editor: MarkdownEditorController) {
        editor.textView.setSelectedRange(NSRange(location: location, length: 0))
        editor.textView.setMarkedText(
            pinyin, selectedRange: NSRange(location: (pinyin as NSString).length, length: 0),
            replacementRange: NSRange(location: location, length: 0))
    }

    private func settle() {
        for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testAPinyinCompositionInsideAndNextToMarkersCommitsToAFullRestyleAndStaysShownMeanwhile() throws {
        let contexts: [(text: String, marker: String, offset: Int)] = [
            ("前 **粗体** 后", "**粗", 3), ("前 **粗体** 后", "**粗", 2), ("前 **粗体** 后", "**粗", 7),
            ("# 标题\n\n正文", "# ", 2), ("# \n\n正文", "# ", 2),
            ("- [ ] 买菜\n- [ ] 做饭", "- [ ] ", 6), ("- [ ] \n- [ ] 做饭", "- [ ] ", 6)
        ]
        for context in contexts {
            let (editor, window, root) = try makeEditor(context.text)
            defer { _ = window; try? FileManager.default.removeItem(at: root) }
            let start = (context.text as NSString).range(of: context.marker).location + context.offset

            compose("n", at: start, in: editor)
            compose("ni", at: start, in: editor)
            XCTAssertTrue(editor.textView.hasMarkedText())
            let marked = editor.textView.markedRange()
            XCTAssertEqual(marked.length, 2, context.text)
            settle()
            editor.textStorage.enumerateAttribute(.mdHidden, in: marked) { value, range, _ in
                XCTAssertNil(value, "composition text was hidden at \(range) in \(context.text.debugDescription)")
            }

            editor.textView.insertText("你", replacementRange: editor.textView.markedRange())
            XCTAssertFalse(editor.textView.hasMarkedText())
            settle()
            assertStyledLikeAFullRestyle(editor)
            XCTAssertTrue(editor.textStorage.string.contains("你"))
        }
    }

    func testCancellingACompositionToNothingLeavesTheStylingAFullRestyleWouldGive() throws {
        for text in ["前 **粗体** 后\n\n# 标题\n\n- [ ] 买菜", "plain **bold** text"] {
            let (editor, window, root) = try makeEditor(text)
            defer { _ = window; try? FileManager.default.removeItem(at: root) }
            let start = (text as NSString).range(of: "**").location + 3

            compose("ni", at: start, in: editor)
            // Backspaced to empty, then Escape.
            editor.textView.setMarkedText(
                "", selectedRange: NSRange(location: 0, length: 0),
                replacementRange: editor.textView.markedRange())
            editor.textView.unmarkText()
            settle()

            XCTAssertEqual(editor.textStorage.string, text)
            assertStyledLikeAFullRestyle(editor)
            editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
            settle()
            assertStyledLikeAFullRestyle(editor)

            compose("ni", at: start, in: editor)
            editor.textView.unmarkText()
            settle()
            assertStyledLikeAFullRestyle(editor)
        }
    }
}
