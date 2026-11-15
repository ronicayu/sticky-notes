import AppKit

/// The text a slash menu entry puts in place of the `/` that opened it.
final class SlashReplacement: NSObject {
    let slashLocation: Int
    let replacement: String

    init(slashLocation: Int, replacement: String) {
        self.slashLocation = slashLocation
        self.replacement = replacement
    }
}

/// The Markdown editor both note windows host: a `TodoTextView` on a TextKit 1
/// stack, restyled as the text changes, with markers that hide when the caret
/// is elsewhere, list continuation, slash commands, label completion and
/// checkbox toggling. It knows nothing about notes, files or windows; the host
/// feeds it text and listens to `onTextChange`.
@MainActor final class MarkdownEditorController: NSObject, NSTextViewDelegate, NSTextStorageDelegate, TodoTextViewDelegate {
    /// What differs between the editors that host this. The rest is shared.
    struct Options {
        var verticalInset: CGFloat
        var lineFragmentPadding: CGFloat?
        /// Turns off smart insert, text replacement, spelling correction and the find bar.
        var quietSubstitutions = false
        /// Enter continues a list item and Tab indents it.
        var listEditing = false
        /// Typing `/` opens the date, time and block menu.
        var slashMenu = false

        static let note = Options(verticalInset: 8, listEditing: true, slashMenu: true)
        static let daily = Options(
            verticalInset: 4,
            lineFragmentPadding: TodoTextView.leadingPaddingForCheckbox,
            quietSubstitutions: true
        )
    }

    let textView: TodoTextView
    let textStorage: NSTextStorage
    let layoutManager: NSLayoutManager

    /// Called first on every user edit, before the text is restyled.
    var onTextChange: ((String) -> Void)?
    /// Called when Up is pressed on the first line. Nil leaves the key alone.
    var onMoveUpFromFirstLine: (() -> Void)?
    /// The labels offered when a `#word` is typed. Nil turns the completion off.
    var labelProvider: (() -> [String])?
    /// Called with the label the person picked from the completion list.
    var onLabelTyped: ((String) -> Void)?

    private let options: Options
    private let clock: AppClock
    private let markerLayout = HiddenMarkerLayoutDelegate()
    let restyler = MarkdownRestyler()
    /// What has changed in the text since it was last styled: the text now at
    /// `range`, and how much longer the text became in all. Several edits are
    /// merged into the one range that holds them all. Nil when nothing changed.
    private var pendingEdit: (range: NSRange, changeInLength: Int)?
    private var orphanCheckQueued = false
    /// The selection the hidden markers were last worked out for. Markers away
    /// from it, and from what was restyled, are already right.
    private var visibilitySelection: NSRange?
    private var labelPanel: LabelCompletionPanel?
    /// Character index of the `#` that opened the active completion, if any.
    private var labelTriggerStart: Int?

    init(text: String = "", store: NoteStore, clock: AppClock, options: Options) {
        self.options = options
        self.clock = clock
        textStorage = NSTextStorage(string: text)
        layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        if let padding = options.lineFragmentPadding { container.lineFragmentPadding = padding }
        layoutManager.addTextContainer(container)

        textView = TodoTextView(frame: .zero, textContainer: container)
        super.init()

        textView.isRichText = false
        textView.allowsUndo = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: options.verticalInset)
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: MarkdownStyler.baseFontSize),
            .foregroundColor: MarkdownStyler.bodyTextColor
        ]
        textView.insertionPointColor = MarkdownStyler.bodyTextColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.usesFindBar = !options.quietSubstitutions
        textView.isIncrementalSearchingEnabled = !options.quietSubstitutions
        if options.quietSubstitutions {
            textView.smartInsertDeleteEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
        }
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        textView.delegate = self
        textStorage.delegate = self
        textView.todoDelegate = self
        layoutManager.delegate = markerLayout
        textView.attachmentHandler = { [weak store] pasteboard in
            guard let store = store else { return nil }
            return Attachments.handlePaste(pasteboard, for: store)
        }
        textView.attachmentResolver = { [weak store] reference in
            guard let store = store else { return nil }
            return Attachments.resolve(reference, for: store)
        }
        restyle()
    }

    // MARK: - Styling

    /// Restyle the whole text and re-hide the markers the caret is not in.
    func restyle() {
        let restyled = restyler.restyleAll(textStorage)
        pendingEdit = nil
        rehideMarkers(restyled: restyled, edit: nil)
    }

    /// Restyle after the text changed: only the paragraphs around the edits, or
    /// everything when nothing says what changed. While a composition (an input
    /// method's marked text) is open nothing is touched: restyling would reset the
    /// marked text's attributes. The restyle happens when it is committed.
    private func restyleAfterEdit() {
        guard !textView.hasMarkedText() else { return }
        guard let edit = pendingEdit else {
            restyle()
            return
        }
        pendingEdit = nil
        let restyled = restyler.restyle(textStorage, edited: edit.range, changeInLength: edit.changeInLength)
        rehideMarkers(restyled: restyled, edit: edit)
    }

    /// The text can change with no `textDidChange` after it: a composition cancelled
    /// with Escape or backspaced to nothing, Writing Tools, an inline prediction.
    /// When the turn of the run loop that made the change is over and the delegate
    /// has not been told, the restyle is done here.
    private func checkForUnreportedEdit() {
        guard !orphanCheckQueued else { return }
        orphanCheckQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.orphanCheckQueued = false
            if self.pendingEdit != nil && !self.textView.hasMarkedText() { self.restyleAfterEdit() }
        }
    }

    /// Hiding is a layout decision, so changing which markers are hidden has to
    /// invalidate the glyphs the layout manager already generated. Only the
    /// paragraphs around the caret, around where it was, and the ones just
    /// restyled can have changed; everywhere else the answer is still right.
    func refreshMarkerVisibility() {
        rehideMarkers(restyled: nil, edit: nil)
    }

    /// `restyled` is the text whose attributes were just rewritten, which lost
    /// its hidden flags; `edit` is the change that came with it, so the old
    /// caret can be found in the new text.
    private func rehideMarkers(restyled: NSRange?, edit: (range: NSRange, changeInLength: Int)?) {
        // An edit is in flight: the text has moved but its markers have not been
        // restyled yet, and the restyle that follows will refresh once they have.
        guard pendingEdit == nil else { return }
        let selection = textView.selectedRange()
        let dirty = dirtyRanges(selection: selection, restyled: restyled, edit: edit)
        visibilitySelection = selection
        for range in dirty ?? [NSRange(location: 0, length: textStorage.length)] {
            MarkdownStyler.updateMarkerVisibility(in: textStorage, selection: selection, within: range)
            layoutManager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
        }
        layoutManager.ensureLayout(for: layoutManager.textContainers[0])
    }

    /// The text whose markers may need another look, or nil for all of it.
    private func dirtyRanges(
        selection: NSRange, restyled: NSRange?, edit: (range: NSRange, changeInLength: Int)?
    ) -> [NSRange]? {
        guard let previous = visibilitySelection else { return nil }
        let text = textStorage.string as NSString
        var before = previous
        if let edit = edit {
            let removedEnd = edit.range.location + edit.range.length - edit.changeInLength
            func moved(_ position: Int) -> Int {
                if position <= edit.range.location { return position }
                return position >= removedEnd ? position + edit.changeInLength : edit.range.location
            }
            let start = moved(previous.location)
            before = NSRange(location: start, length: max(0, moved(NSMaxRange(previous)) - start))
        }
        var ranges: [NSRange] = []
        for around in [selection, before] {
            let clamped = NSIntersectionRange(around, NSRange(location: 0, length: text.length))
            let place = clamped.length == 0 ? NSRange(location: min(around.location, text.length), length: 0) : clamped
            guard let paragraphs = MarkdownRestyler.slice(of: text, around: place) else { return nil }
            ranges.append(paragraphs)
        }
        if let restyled = restyled {
            if restyled.length >= text.length { return nil }
            ranges.append(restyled)
        }
        return ranges
    }

    /// Repaint what depends on the system appearance. Note windows paint their
    /// own paper, so AppKit never does this for them.
    func applyColors() {
        textView.insertionPointColor = MarkdownStyler.bodyTextColor
        textView.typingAttributes[.foregroundColor] = MarkdownStyler.bodyTextColor
        restyle()
        textView.needsDisplay = true
    }

    /// Re-apply styling after the shared text size changes.
    func applyTextSize() {
        textView.font = NSFont.systemFont(ofSize: MarkdownStyler.baseFontSize)
        restyle()
    }

    /// Show text that arrived from outside. Setting the storage directly does
    /// not call the delegate, so this never counts as an edit.
    func replaceText(_ text: String) {
        let oldSelection = textView.selectedRange()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
        // The recorded undo operations refer to ranges in the text we just
        // threw away; replaying them against the new string garbles it.
        textView.undoManager?.removeAllActions()
        restyle()
        textView.setSelectedRange(NSRange(location: min(oldSelection.location, textStorage.length), length: 0))
    }

    // MARK: - NSTextViewDelegate

    /// True while the app edits the text itself, such as ticking a task. The
    /// person's caret may sit after a `/` or a `#wo`, and an edit they did not
    /// make must not open a menu for it.
    var isEditingProgrammatically = false

    func textDidChange(_ notification: Notification) {
        onTextChange?(textView.string)
        restyleAfterEdit()
        guard !isEditingProgrammatically else { return }
        if options.slashMenu { detectSlashTrigger() }
        detectLabelTrigger()
    }

    /// Remembers what was edited, for the restyle that follows. The storage calls
    /// this on the main thread, while it is still processing the edit, so nothing
    /// here may change the text or its attributes.
    nonisolated func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            pendingEdit = Self.merged(pendingEdit, with: (editedRange, delta))
            checkForUnreportedEdit()
        }
    }

    /// The one edit that stands for `first` followed by `second`: the range that
    /// holds both, with `first` moved to where `second` left it.
    private static func merged(
        _ first: (range: NSRange, changeInLength: Int)?, with second: (range: NSRange, changeInLength: Int)
    ) -> (range: NSRange, changeInLength: Int) {
        guard let first = first else { return second }
        let removedEnd = second.range.location + second.range.length - second.changeInLength
        func moved(_ position: Int) -> Int {
            if position <= second.range.location { return position }
            return position >= removedEnd ? position + second.changeInLength : second.range.location
        }
        let start = min(moved(first.range.location), second.range.location)
        let end = max(moved(NSMaxRange(first.range)), NSMaxRange(second.range))
        return (NSRange(location: start, length: end - start), first.changeInLength + second.changeInLength)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if pendingEdit != nil {
            // Typing moves the caret before it reports the change, and that report
            // restyles. If none comes, the check restyles instead.
            checkForUnreportedEdit()
        } else {
            refreshMarkerVisibility()
        }
        // Caret moved away from the active `#word` → kill the panel.
        if labelTriggerStart != nil { detectLabelTrigger() }
    }

    /// Body editor key handling.
    /// - While the label list is up, arrows, Enter, Tab and Escape drive it.
    /// - Up on the first line hands over to the host (the title).
    /// - Enter inside a bullet/ordered/checkbox item continues the list, or
    ///   strips the marker if the item is empty, exiting the list.
    /// - Tab indents a list item; anywhere else it keeps its normal meaning.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === self.textView else { return false }

        if let panel = labelPanel, panel.isVisible {
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                panel.selectNext()
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                panel.selectPrevious()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
               commandSelector == #selector(NSResponder.insertTab(_:)) {
                if panel.acceptSelection() { return true }
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                dismissLabelCompletion()
                return true
            }
        }

        if commandSelector == #selector(NSResponder.moveUp(_:)), let handOver = onMoveUpFromFirstLine {
            let selection = textView.selectedRange()
            let str = textView.string as NSString
            let firstNewline = str.range(of: "\n")
            let onFirstLine = firstNewline.location == NSNotFound || selection.location <= firstNewline.location
            guard onFirstLine else { return false }
            handOver()
            return true
        }

        guard options.listEditing else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            return handleListContinuation()
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            return self.textView.indentSelection(outdent: false)
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            return self.textView.indentSelection(outdent: true)
        }
        return false
    }

    // MARK: - Lists

    /// On Enter: if the current line is a list/checkbox item, either continue
    /// the list with the next marker or — if the item is empty — strip the
    /// marker and let the regular newline through to exit the list.
    private func handleListContinuation() -> Bool {
        let str = textView.string as NSString
        let selection = textView.selectedRange()
        let lineRange = str.lineRange(for: NSRange(location: selection.location, length: 0))
        var lineText = str.substring(with: lineRange)
        if lineText.hasSuffix("\n") { lineText.removeLast() }
        let lineNS = lineText as NSString

        // Checkbox: "[indent]- [ ] " or "[indent]- [x] "
        if let regex = try? NSRegularExpression(pattern: #"^([ \t]*)-[ \t]\[[ xX]\][ \t]?(.*)$"#),
           let m = regex.firstMatch(in: lineText, range: NSRange(location: 0, length: lineNS.length)) {
            let indent = lineNS.substring(with: m.range(at: 1))
            let rest = lineNS.substring(with: m.range(at: 2))
            let prefixLen = lineNS.length - (rest as NSString).length
            return continueOrExitList(
                lineRange: lineRange,
                prefixLen: prefixLen,
                rest: rest,
                continuation: "\(indent)- [ ] "
            )
        }

        // Bullet: "- " or "* " (with optional indent)
        if let regex = try? NSRegularExpression(pattern: #"^([ \t]*)([-*])\s(.*)$"#),
           let m = regex.firstMatch(in: lineText, range: NSRange(location: 0, length: lineNS.length)) {
            let indent = lineNS.substring(with: m.range(at: 1))
            let bullet = lineNS.substring(with: m.range(at: 2))
            let rest = lineNS.substring(with: m.range(at: 3))
            let prefixLen = lineNS.length - (rest as NSString).length
            return continueOrExitList(
                lineRange: lineRange,
                prefixLen: prefixLen,
                rest: rest,
                continuation: "\(indent)\(bullet) "
            )
        }

        // Ordered: "1. ", "23. " (with optional indent)
        if let regex = try? NSRegularExpression(pattern: #"^([ \t]*)(\d+)\.\s(.*)$"#),
           let m = regex.firstMatch(in: lineText, range: NSRange(location: 0, length: lineNS.length)) {
            let indent = lineNS.substring(with: m.range(at: 1))
            let numStr = lineNS.substring(with: m.range(at: 2))
            let rest = lineNS.substring(with: m.range(at: 3))
            let next = (Int(numStr) ?? 0) + 1
            let prefixLen = lineNS.length - (rest as NSString).length
            return continueOrExitList(
                lineRange: lineRange,
                prefixLen: prefixLen,
                rest: rest,
                continuation: "\(indent)\(next). "
            )
        }

        return false
    }

    private func continueOrExitList(lineRange: NSRange,
                                    prefixLen: Int,
                                    rest: String,
                                    continuation: String) -> Bool {
        let restTrimmed = rest.trimmingCharacters(in: .whitespaces)
        let selection = textView.selectedRange()

        if restTrimmed.isEmpty {
            // Empty item — strip the marker so this Enter starts a new line
            // outside the list. Return false so NSTextView handles the Enter.
            let prefixRange = NSRange(location: lineRange.location, length: prefixLen)
            guard textView.shouldChangeText(in: prefixRange, replacementString: "") else { return false }
            textStorage.replaceCharacters(in: prefixRange, with: "")
            textView.didChangeText()
            return false
        } else {
            // Continue the list.
            let insertion = "\n" + continuation
            let insertRange = NSRange(location: selection.location, length: 0)
            guard textView.shouldChangeText(in: insertRange, replacementString: insertion) else { return false }
            textStorage.replaceCharacters(in: insertRange, with: insertion)
            textView.didChangeText()
            return true
        }
    }

    // MARK: - TodoTextViewDelegate

    /// Flip the bracket character (`[ ]` ↔ `[x]`) inside the markdown source
    /// for the checkbox at the given character index. The checkbox visual is
    /// re-rendered when the change reaches `textDidChange`.
    func textViewDidToggleCheckbox(at charIndex: Int) {
        let str = textStorage.string as NSString
        guard charIndex < str.length else { return }

        let lineRange = str.lineRange(for: NSRange(location: charIndex, length: 0))
        let lineNS = str.substring(with: lineRange) as NSString
        let bracketInLine = lineNS.range(of: "[")
        guard bracketInLine.location != NSNotFound,
              bracketInLine.location + 1 < lineNS.length else { return }

        let bracketCharIdx = lineRange.location + bracketInLine.location + 1
        let current = str.substring(with: NSRange(location: bracketCharIdx, length: 1))
        let replacement = current.lowercased() == "x" ? " " : "x"

        let range = NSRange(location: bracketCharIdx, length: 1)
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
    }

    // MARK: - Slash commands

    private static let dateFormatter = slashFormatter("yyyy-MM-dd")
    private static let timeFormatter = slashFormatter("HH:mm")

    private static func slashFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    /// The date and time entries every slash menu offers, as (menu title, text).
    static func dateTimeEntries(now: Date) -> [(String, String)] {
        let date = dateFormatter.string(from: now)
        let time = timeFormatter.string(from: now)
        let dateTime = "\(date) \(time)"
        return [
            ("Date  →  \(date)", date),
            ("Time  →  \(time)", time),
            ("Date + Time  →  \(dateTime)", dateTime)
        ]
    }

    private func detectSlashTrigger() {
        let selection = textView.selectedRange()
        guard selection.length == 0, selection.location > 0 else { return }
        let str = textView.string as NSString
        guard selection.location <= str.length else { return }
        let lastChar = str.substring(with: NSRange(location: selection.location - 1, length: 1))
        guard lastChar == "/" else { return }

        if selection.location > 1 {
            let prev = str.substring(with: NSRange(location: selection.location - 2, length: 1))
            let allowed: Set<String> = ["\n", " ", "\t"]
            if !allowed.contains(prev) { return }
        }

        let slashLocation = selection.location - 1
        DispatchQueue.main.async { [weak self] in
            self?.showSlashMenu(at: slashLocation)
        }
    }

    private func showSlashMenu(at slashLocation: Int) {
        let entries = MarkdownEditorController.dateTimeEntries(now: clock.now()) + [
            ("To-do  →  - [ ] ", "- [ ] "),
            ("Divider  →  ---", "---"),
            ("Heading  →  # ", "# "),
            ("Subheading  →  ## ", "## ")
        ]

        let menu = NSMenu()
        menu.font = NSFont.systemFont(ofSize: 12)
        for (title, replacement) in entries {
            let item = NSMenuItem(
                title: title,
                action: #selector(insertSlashCommand(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = SlashReplacement(slashLocation: slashLocation, replacement: replacement)
            menu.addItem(item)
        }

        guard let container = textView.textContainer else { return }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: slashLocation, length: 1),
            actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        let popPoint = NSPoint(x: rect.minX, y: rect.maxY + 2)
        menu.popUp(positioning: nil, at: popPoint, in: textView)
    }

    @objc private func insertSlashCommand(_ sender: NSMenuItem) {
        guard let cmd = sender.representedObject as? SlashReplacement else { return }
        let len = textStorage.length
        let loc = cmd.slashLocation
        guard loc >= 0, loc < len else { return }
        let existing = (textView.string as NSString).substring(with: NSRange(location: loc, length: 1))
        guard existing == "/" else { return }

        let range = NSRange(location: loc, length: 1)
        guard textView.shouldChangeText(in: range, replacementString: cmd.replacement) else { return }
        textStorage.replaceCharacters(in: range, with: cmd.replacement)
        textView.didChangeText()
        let inserted = (cmd.replacement as NSString).length
        textView.setSelectedRange(NSRange(location: loc + inserted, length: 0))
    }

    // MARK: - Label completion

    /// Look back from the caret for an active `#word` token and either show
    /// or update the completion panel. Dismiss it when the cursor leaves
    /// the token's span.
    private func detectLabelTrigger() {
        guard labelProvider != nil else { return }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { dismissLabelCompletion(); return }
        let str = textView.string as NSString
        let cursor = selection.location

        var i = cursor - 1
        while i >= 0 {
            let ch = str.substring(with: NSRange(location: i, length: 1))
            if ch == "#" {
                let prevOK: Bool
                if i == 0 {
                    prevOK = true
                } else {
                    let prev = str.substring(with: NSRange(location: i - 1, length: 1))
                    prevOK = (prev == " " || prev == "\t" || prev == "\n")
                }
                if prevOK {
                    let typedLen = cursor - i - 1
                    let typed = typedLen > 0
                        ? str.substring(with: NSRange(location: i + 1, length: typedLen))
                        : ""
                    showLabelCompletion(at: i, typed: typed)
                    return
                }
                dismissLabelCompletion()
                return
            }
            // Spaces / newlines end the token.
            if ch == " " || ch == "\t" || ch == "\n" {
                dismissLabelCompletion()
                return
            }
            i -= 1
        }
        dismissLabelCompletion()
    }

    private func showLabelCompletion(at hashLocation: Int, typed: String) {
        let normalizedQuery = NoteLabel.normalize(typed)
        let known = labelProvider?() ?? []
        let filtered: [String]
        if normalizedQuery.isEmpty {
            filtered = known
        } else {
            filtered = known.filter { $0.contains(normalizedQuery) }
        }

        var items: [LabelCompletionPanel.Item] = filtered.map { .existing($0) }
        if !normalizedQuery.isEmpty && !known.contains(normalizedQuery) {
            items.append(.create(normalizedQuery))
        }
        if items.isEmpty {
            dismissLabelCompletion()
            return
        }

        let panel = completionPanel()
        labelTriggerStart = hashLocation
        panel.setItems(items)
        positionLabelPanel(panel, below: hashLocation)
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    private func completionPanel() -> LabelCompletionPanel {
        if let panel = labelPanel { return panel }
        let panel = LabelCompletionPanel()
        panel.onAccept = { [weak self] item in
            self?.acceptLabelCompletion(item)
        }
        labelPanel = panel
        return panel
    }

    var isShowingLabelCompletion: Bool { labelPanel?.isVisible == true }

    func dismissLabelCompletion() {
        if let panel = labelPanel, panel.isVisible { panel.orderOut(nil) }
        labelTriggerStart = nil
    }

    private func positionLabelPanel(_ panel: LabelCompletionPanel, below charIndex: Int) {
        guard let win = textView.window, let container = textView.textContainer else { return }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: charIndex, length: 1),
            actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        // Convert from textView (flipped) → window → screen.
        let belowInTextView = NSPoint(x: rect.minX, y: rect.maxY + 2)
        let inWindow = textView.convert(belowInTextView, to: nil)
        let screenPoint = win.convertPoint(toScreen: inWindow)
        var frame = panel.frame
        // Place panel so its TOP edge sits at the caret line.
        frame.origin = NSPoint(x: screenPoint.x, y: screenPoint.y - frame.size.height)
        panel.setFrame(frame, display: false)
    }

    private func acceptLabelCompletion(_ item: LabelCompletionPanel.Item) {
        guard let start = labelTriggerStart else { return }
        let cursor = textView.selectedRange().location
        let length = max(0, cursor - start)
        guard start + length <= textStorage.length else {
            dismissLabelCompletion()
            return
        }
        let range = NSRange(location: start, length: length)
        if textView.shouldChangeText(in: range, replacementString: "") {
            textStorage.replaceCharacters(in: range, with: "")
            textView.didChangeText()
        }
        onLabelTyped?(item.labelName)
        dismissLabelCompletion()
    }
}
