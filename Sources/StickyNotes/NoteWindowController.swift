import AppKit

final class NoteWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate, NSLayoutManagerDelegate, NoteDragZoneDelegate, ColorPickerBarDelegate {
    private var note: Note
    private let store: NoteStore
    private let onClosed: (UUID) -> Void

    private let dragZone: NoteDragZone
    private let expandButton: NSButton
    private let trashButton: NSButton
    private let titleField: FlushLeftTextField    // editable; visible expanded
    private let titleLabel: CenteredTitleLabel    // read-only; visible collapsed
    private let dateLabel: NSTextField
    private let colorPicker: ColorPickerBar
    private let footerView: NSView
    /// Container that holds titleField + scrollView + footer. We collapse the
    /// note by forcing this view's height to 0; otherwise its subviews'
    /// constraints would keep dictating the window's minimum content height.
    private let bodyContainer: NSView
    private var bodyHeightZeroConstraint: NSLayoutConstraint!

    private static let titleExpandedFont = NSFont.systemFont(ofSize: MarkdownStyler.baseFontSize + 7, weight: .bold)
    private static let titleCollapsedFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    private var dragZoneHeightConstraint: NSLayoutConstraint!

    private let textView: NSTextView
    private let textStorage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private let scrollView: NSScrollView
    private let backgroundView: HoverTrackingView

    private var saveWorkItem: DispatchWorkItem?
    private var preCollapseHeight: CGFloat
    private var isHovering = false
    private var pendingExternalContent: String?

    /// Height of the chrome strip when expanded.
    static let chromeHeight: CGFloat = 22
    /// Height of the title row sitting below the chrome when expanded.
    static let titleRowHeight: CGFloat = 28
    /// Window height when collapsed (matches the chrome strip exactly).
    static let collapsedHeight: CGFloat = 18

    private static let slashDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let slashTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let humanDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let blurAlpha: CGFloat = 0.7
    private static let activeAlpha: CGFloat = 1.0
    private static let chromeColor = NSColor.black.withAlphaComponent(0.55)

    init(note: Note, store: NoteStore, onClosed: @escaping (UUID) -> Void) {
        self.note = note
        self.store = store
        self.onClosed = onClosed
        self.preCollapseHeight = CGFloat(note.height)

        let displayHeight: CGFloat = note.collapsed
            ? NoteWindowController.collapsedHeight
            : CGFloat(note.height)
        let frame = NSRect(x: note.positionX, y: note.positionY, width: note.width, height: displayHeight)
        let window = NoteWindow(contentRect: frame)

        backgroundView = HoverTrackingView(frame: .zero)
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = note.collapsed ? 5 : 12
        backgroundView.layer?.masksToBounds = true
        backgroundView.layer?.backgroundColor = NSColor(hex: note.color.bodyHex)?.cgColor

        // Drag zone — fills the top edge, handles drag + double-click.
        dragZone = NoteDragZone()
        dragZone.translatesAutoresizingMaskIntoConstraints = false

        expandButton = NoteWindowController.makeChromeButton(
            symbol: note.collapsed ? "chevron.down" : "chevron.up",
            tooltip: "Collapse / expand"
        )
        trashButton = NoteWindowController.makeChromeButton(
            symbol: "trash",
            tooltip: "Archive note"
        )

        // Two title surfaces:
        // - titleField: editable NSTextField shown when the note is expanded
        // - titleLabel: read-only NSView with manually-centered text shown
        //   when collapsed (NSTextField doesn't reliably center in tight bars)
        titleField = FlushLeftTextField()
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.stringValue = note.title
        titleField.placeholderString = "Title"
        titleField.font = NoteWindowController.titleExpandedFont
        titleField.textColor = MarkdownStyler.bodyTextColor
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.lineBreakMode = .byTruncatingTail
        titleField.usesSingleLineMode = true
        titleField.cell?.wraps = false
        titleField.cell?.isScrollable = true
        titleField.allowsDefaultTighteningForTruncation = true
        titleField.isHidden = note.collapsed

        titleLabel = CenteredTitleLabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = note.title
        titleLabel.font = NoteWindowController.titleCollapsedFont
        titleLabel.textColor = MarkdownStyler.bodyTextColor
        titleLabel.placeholder = "Untitled"
        titleLabel.isHidden = !note.collapsed

        bodyContainer = NSView()
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.wantsLayer = true
        bodyContainer.layer?.masksToBounds = true

        // Editor (TextKit 1 stack so we can hook glyph generation for hidden markers).
        textStorage = NSTextStorage(string: note.content)
        layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)

        textView = NSTextView(frame: .zero, textContainer: container)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        // Inset 0 horizontally so the body text starts at the same x as the
        // flush-left title field — they should appear visually left-aligned.
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: MarkdownStyler.baseFontSize),
            .foregroundColor: MarkdownStyler.bodyTextColor
        ]
        textView.insertionPointColor = MarkdownStyler.bodyTextColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        // Footer: relative date (left) + color picker (right).
        dateLabel = NSTextField(labelWithString: "")
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        dateLabel.textColor = NSColor.black.withAlphaComponent(0.40)
        dateLabel.lineBreakMode = .byClipping

        colorPicker = ColorPickerBar(currentColor: note.color)
        colorPicker.translatesAutoresizingMaskIntoConstraints = false

        footerView = NSView()
        footerView.translatesAutoresizingMaskIntoConstraints = false
        footerView.addSubview(dateLabel)
        footerView.addSubview(colorPicker)

        backgroundView.addSubview(bodyContainer)
        backgroundView.addSubview(dragZone)
        bodyContainer.addSubview(titleField)
        bodyContainer.addSubview(scrollView)
        bodyContainer.addSubview(footerView)
        dragZone.addSubview(titleLabel)
        dragZone.addSubview(expandButton)
        dragZone.addSubview(trashButton)

        let pickerSize = colorPicker.intrinsicContentSize

        let initialChromeHeight: CGFloat = note.collapsed
            ? NoteWindowController.collapsedHeight
            : NoteWindowController.chromeHeight
        dragZoneHeightConstraint = dragZone.heightAnchor.constraint(equalToConstant: initialChromeHeight)

        // 0-height constraint that we activate to collapse the body fully out
        // of the layout. Required priority so it wins over body internals.
        bodyHeightZeroConstraint = bodyContainer.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            // Drag zone fills the top edge.
            dragZone.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
            dragZone.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
            dragZone.topAnchor.constraint(equalTo: backgroundView.topAnchor),
            dragZoneHeightConstraint,

            // Body container fills the rest of the window.
            bodyContainer.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
            bodyContainer.topAnchor.constraint(equalTo: dragZone.bottomAnchor),
            bodyContainer.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor),

            // Top-right buttons in the drag zone (visible only when focused).
            trashButton.trailingAnchor.constraint(equalTo: dragZone.trailingAnchor, constant: -7),
            trashButton.centerYAnchor.constraint(equalTo: dragZone.centerYAnchor),
            trashButton.widthAnchor.constraint(equalToConstant: 13),
            trashButton.heightAnchor.constraint(equalToConstant: 13),

            expandButton.trailingAnchor.constraint(equalTo: trashButton.leadingAnchor, constant: -6),
            expandButton.centerYAnchor.constraint(equalTo: dragZone.centerYAnchor),
            expandButton.widthAnchor.constraint(equalToConstant: 13),
            expandButton.heightAnchor.constraint(equalToConstant: 13),

            // Collapsed title label fills the drag zone.
            titleLabel.leadingAnchor.constraint(equalTo: dragZone.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: dragZone.trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: dragZone.topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: dragZone.bottomAnchor),

            // Expanded title field sits at the top of the body container.
            titleField.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor, constant: 14),
            titleField.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor, constant: -14),
            titleField.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            titleField.heightAnchor.constraint(equalToConstant: NoteWindowController.titleRowHeight),

            // Editor.
            scrollView.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor, constant: 14),
            scrollView.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor, constant: -14),
            scrollView.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
            scrollView.bottomAnchor.constraint(equalTo: footerView.topAnchor, constant: -2),

            // Footer at the bottom of the body container.
            footerView.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor, constant: 14),
            footerView.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor, constant: -14),
            footerView.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor, constant: -10),
            footerView.heightAnchor.constraint(equalToConstant: 16),

            dateLabel.leadingAnchor.constraint(equalTo: footerView.leadingAnchor),
            dateLabel.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),

            colorPicker.trailingAnchor.constraint(equalTo: footerView.trailingAnchor),
            colorPicker.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),
            colorPicker.widthAnchor.constraint(equalToConstant: pickerSize.width),
            colorPicker.heightAnchor.constraint(equalToConstant: pickerSize.height)
        ])

        window.contentView = backgroundView
        if note.collapsed {
            bodyContainer.isHidden = true
            bodyHeightZeroConstraint.isActive = true
        }

        super.init(window: window)
        window.delegate = self
        window.alphaValue = NoteWindowController.blurAlpha
        window.initialFirstResponder = textView
        window.minSize = NSSize(width: 120, height: NoteWindowController.collapsedHeight)
        window.contentMinSize = NSSize(width: 120, height: NoteWindowController.collapsedHeight)
        textView.delegate = self
        titleField.delegate = self
        layoutManager.delegate = self
        dragZone.delegate = self
        colorPicker.delegate = self

        expandButton.target = self
        expandButton.action = #selector(toggleCollapse)
        trashButton.target = self
        trashButton.action = #selector(closeNote)

        backgroundView.onHoverChange = { [weak self] hovering in
            self?.isHovering = hovering
            self?.updateAlpha()
            self?.updateChromeVisibility()
        }

        updateDateLabel()
        updateChromeVisibility(animated: false)
        MarkdownStyler.apply(to: textView)
        refreshMarkerVisibility()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStoreChange),
            name: NoteStore.didChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    func focusEditor() {
        guard let window = window else { return }
        window.makeFirstResponder(textView)
        let end = NSRange(location: textView.string.utf16.count, length: 0)
        textView.setSelectedRange(end)
    }

    /// Focus the title field, placing the caret after any existing text.
    func focusTitle() {
        guard let window = window else { return }
        window.makeFirstResponder(titleField)
        if let editor = titleField.currentEditor() {
            let end = (titleField.stringValue as NSString).length
            editor.selectedRange = NSRange(location: end, length: 0)
        }
    }

    private static let chromeSymbolConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)

    private static func makeChromeButton(symbol: String, tooltip: String) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(chromeSymbolConfig)
        button.contentTintColor = NoteWindowController.chromeColor
        button.toolTip = tooltip
        button.alphaValue = 0
        return button
    }

    private func updateExpandButtonIcon() {
        let symbol = note.collapsed ? "chevron.down" : "chevron.up"
        expandButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Collapse / expand")?
            .withSymbolConfiguration(NoteWindowController.chromeSymbolConfig)
    }

    /// Chrome buttons appear only when the note is expanded AND focused (or
    /// hovered) — like TickTick. Hidden the rest of the time so the unfocused
    /// note is just paper + content.
    private func updateChromeVisibility(animated: Bool = true) {
        let isKey = window?.isKeyWindow ?? false
        let shouldShow = !note.collapsed && (isKey || isHovering)
        let target: CGFloat = shouldShow ? 1.0 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                trashButton.animator().alphaValue = target
                expandButton.animator().alphaValue = target
            }
        } else {
            trashButton.alphaValue = target
            expandButton.alphaValue = target
        }
    }

    // MARK: - Actions

    @objc private func toggleCollapse() {
        performToggleCollapse()
    }

    @objc private func closeNote() {
        let isEmpty = note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEmpty {
            store.discardActive(note)
        } else {
            store.archive(note)
        }
        window?.close()
        onClosed(note.id)
    }

    // MARK: - NoteDragZoneDelegate

    func dragZoneDidDoubleClick() {
        performToggleCollapse()
    }

    // MARK: - ColorPickerBarDelegate

    func colorPicker(_ bar: ColorPickerBar, didSelect color: NoteColor) {
        note.color = color
        backgroundView.layer?.backgroundColor = NSColor(hex: color.bodyHex)?.cgColor
        colorPicker.currentColor = color
        scheduleSave()
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard let frame = window?.frame else { return }
        note.positionX = Double(frame.origin.x)
        note.positionY = Double(frame.origin.y)
        scheduleSave()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateAlpha()
        updateChromeVisibility()
    }

    func windowDidResignKey(_ notification: Notification) {
        updateAlpha()
        updateChromeVisibility()
        if pendingExternalContent != nil {
            pendingExternalContent = nil
            if let updated = store.loadNote(id: note.id),
               updated.content != note.content || updated.title != note.title {
                applyExternalNote(updated)
            }
        }
    }

    private func updateAlpha() {
        guard let window = window else { return }
        let isKey = window.isKeyWindow
        let target: CGFloat = (isKey || isHovering) ? NoteWindowController.activeAlpha : NoteWindowController.blurAlpha
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = target
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let frame = window?.frame else { return }
        note.width = Double(frame.size.width)
        if !note.collapsed {
            note.height = Double(frame.size.height)
            preCollapseHeight = frame.size.height
        }
        scheduleSave()
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        note.content = textView.string
        MarkdownStyler.apply(to: textView)
        refreshMarkerVisibility()
        updateDateLabel()
        scheduleSave()
        detectSlashTrigger()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        refreshMarkerVisibility()
    }

    // MARK: - NSTextFieldDelegate (title)

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === titleField else { return }
        note.title = titleField.stringValue
        titleLabel.text = titleField.stringValue
        updateDateLabel()
        scheduleSave()
        detectTitleSlashTrigger()
    }

    /// Title field key handling. Down arrow / Enter → jump to body editor.
    func control(_ control: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === titleField else { return false }
        if selector == #selector(NSResponder.moveDown(_:)) ||
           selector == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(self.textView)
            self.textView.setSelectedRange(NSRange(location: 0, length: 0))
            return true
        }
        return false
    }

    /// Body editor key handling. Up arrow on the first line → jump to title.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === self.textView else { return false }
        guard commandSelector == #selector(NSResponder.moveUp(_:)) else { return false }

        let selection = textView.selectedRange()
        let str = textView.string as NSString
        let firstNewline = str.range(of: "\n")
        let onFirstLine = firstNewline.location == NSNotFound || selection.location <= firstNewline.location
        guard onFirstLine else { return false }

        focusTitle()
        return true
    }

    // MARK: - Slash commands

    private final class SlashCommand: NSObject {
        let slashLocation: Int
        let replacement: String
        init(slashLocation: Int, replacement: String) {
            self.slashLocation = slashLocation
            self.replacement = replacement
        }
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
        let now = Date()
        let date = NoteWindowController.slashDateFormatter.string(from: now)
        let time = NoteWindowController.slashTimeFormatter.string(from: now)
        let dateTime = "\(date) \(time)"

        let entries: [(String, String)] = [
            ("Date  →  \(date)",            date),
            ("Time  →  \(time)",            time),
            ("Date + Time  →  \(dateTime)", dateTime),
            ("To-do  →  - [ ] ",            "- [ ] "),
            ("Divider  →  ---",             "---"),
            ("Heading  →  # ",              "# "),
            ("Subheading  →  ## ",          "## ")
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
            item.representedObject = SlashCommand(slashLocation: slashLocation, replacement: replacement)
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
        guard let cmd = sender.representedObject as? SlashCommand else { return }
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

    // MARK: - Slash commands (title, date/time only)

    private func detectTitleSlashTrigger() {
        guard let editor = titleField.currentEditor() else { return }
        let str = titleField.stringValue as NSString
        let selection = editor.selectedRange
        guard selection.length == 0, selection.location > 0 else { return }
        let lastChar = str.substring(with: NSRange(location: selection.location - 1, length: 1))
        guard lastChar == "/" else { return }

        if selection.location > 1 {
            let prev = str.substring(with: NSRange(location: selection.location - 2, length: 1))
            let allowed: Set<String> = [" ", "\t"]
            if !allowed.contains(prev) { return }
        }

        let slashLocation = selection.location - 1
        DispatchQueue.main.async { [weak self] in
            self?.showTitleSlashMenu(at: slashLocation)
        }
    }

    private func showTitleSlashMenu(at slashLocation: Int) {
        let now = Date()
        let date = NoteWindowController.slashDateFormatter.string(from: now)
        let time = NoteWindowController.slashTimeFormatter.string(from: now)
        let dateTime = "\(date) \(time)"

        let entries: [(String, String)] = [
            ("Date  →  \(date)",            date),
            ("Time  →  \(time)",            time),
            ("Date + Time  →  \(dateTime)", dateTime)
        ]

        let menu = NSMenu()
        menu.font = NSFont.systemFont(ofSize: 12)
        for (title, replacement) in entries {
            let item = NSMenuItem(
                title: title,
                action: #selector(insertTitleSlashCommand(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = SlashCommand(slashLocation: slashLocation, replacement: replacement)
            menu.addItem(item)
        }

        let popPoint = NSPoint(x: 0, y: titleField.bounds.maxY + 2)
        menu.popUp(positioning: nil, at: popPoint, in: titleField)
    }

    @objc private func insertTitleSlashCommand(_ sender: NSMenuItem) {
        guard let cmd = sender.representedObject as? SlashCommand else { return }
        let str = titleField.stringValue as NSString
        let loc = cmd.slashLocation
        guard loc >= 0, loc < str.length else { return }
        let existing = str.substring(with: NSRange(location: loc, length: 1))
        guard existing == "/" else { return }

        let newValue = str.replacingCharacters(
            in: NSRange(location: loc, length: 1),
            with: cmd.replacement
        )
        titleField.stringValue = newValue
        note.title = newValue
        titleLabel.text = newValue

        if let editor = titleField.currentEditor() {
            let newPos = loc + (cmd.replacement as NSString).length
            editor.selectedRange = NSRange(location: newPos, length: 0)
        }
        scheduleSave()
    }

    private func refreshMarkerVisibility() {
        let selection = textView.selectedRange()
        MarkdownStyler.updateMarkerVisibility(in: textStorage, selection: selection)
        let full = NSRange(location: 0, length: textStorage.length)
        layoutManager.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.ensureLayout(for: layoutManager.textContainers[0])
    }

    private func updateDateLabel() {
        dateLabel.stringValue = relativeDateString(for: Date())
    }

    private func relativeDateString(for date: Date) -> String {
        let cal = Calendar.current
        let formatted = NoteWindowController.humanDateFormatter.string(from: date)
        if cal.isDateInToday(date) {
            return "Today, \(formatted)"
        } else if cal.isDateInYesterday(date) {
            return "Yesterday, \(formatted)"
        } else {
            return formatted
        }
    }

    // MARK: - NSLayoutManagerDelegate

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard let storage = layoutManager.textStorage else { return 0 }

        var modified = false
        var newProps = [NSLayoutManager.GlyphProperty](repeating: .null, count: glyphRange.length)
        for i in 0..<glyphRange.length {
            var prop = props[i]
            let charIdx = charIndexes[i]
            if charIdx < storage.length {
                let attrs = storage.attributes(at: charIdx, effectiveRange: nil)
                if attrs[.mdHidden] != nil {
                    prop = .null
                    modified = true
                }
            }
            newProps[i] = prop
        }

        guard modified else { return 0 }

        newProps.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(
                glyphs,
                properties: buffer.baseAddress!,
                characterIndexes: charIndexes,
                font: aFont,
                forGlyphRange: glyphRange
            )
        }
        return glyphRange.length
    }

    // MARK: - Collapse

    private func performToggleCollapse() {
        guard let window = window else { return }
        note.collapsed.toggle()
        var frame = window.frame
        if note.collapsed {
            // Commit any in-flight title edit before collapsing.
            if window.firstResponder === titleField || titleField.currentEditor() != nil {
                window.makeFirstResponder(window)
            }
            preCollapseHeight = frame.size.height

            titleLabel.text = note.title
            titleLabel.isHidden = false
            bodyContainer.isHidden = true
            bodyHeightZeroConstraint.isActive = true

            backgroundView.layer?.cornerRadius = 5
            dragZoneHeightConstraint.constant = NoteWindowController.collapsedHeight

            let newHeight = NoteWindowController.collapsedHeight
            frame.origin.y += frame.size.height - newHeight
            frame.size.height = newHeight
            window.setFrame(frame, display: true, animate: true)
        } else {
            titleLabel.isHidden = true
            bodyContainer.isHidden = false
            bodyHeightZeroConstraint.isActive = false

            backgroundView.layer?.cornerRadius = 12
            dragZoneHeightConstraint.constant = NoteWindowController.chromeHeight

            let newHeight = preCollapseHeight
            frame.origin.y -= newHeight - frame.size.height
            frame.size.height = newHeight
            window.setFrame(frame, display: true, animate: true)
            note.height = Double(newHeight)
        }
        updateExpandButtonIcon()
        updateChromeVisibility()
        scheduleSave()
    }

    // MARK: - External change sync

    @objc private func handleStoreChange() {
        guard let updated = store.loadNote(id: note.id) else { return }
        let contentChanged = updated.content != note.content
        let titleChanged = updated.title != note.title
        if !contentChanged && !titleChanged { return }

        if let win = window, win.isKeyWindow {
            let editing = win.firstResponder === textView ||
                titleField.currentEditor() != nil
            if editing {
                pendingExternalContent = updated.content
                return
            }
        }
        applyExternalNote(updated)
    }

    private func applyExternalNote(_ updated: Note) {
        if updated.title != note.title {
            note.title = updated.title
            titleField.stringValue = updated.title
            titleLabel.text = updated.title
        }
        if updated.content != note.content {
            note.content = updated.content
            let oldSelection = textView.selectedRange()
            let fullRange = NSRange(location: 0, length: textStorage.length)
            textStorage.replaceCharacters(in: fullRange, with: updated.content)
            MarkdownStyler.apply(to: textView)
            refreshMarkerVisibility()
            updateDateLabel()
            let len = textStorage.length
            let clamped = NSRange(location: min(oldSelection.location, len), length: 0)
            textView.setSelectedRange(clamped)
        }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.note.updatedAt = Date()
            self.store.save(self.note)
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
}
