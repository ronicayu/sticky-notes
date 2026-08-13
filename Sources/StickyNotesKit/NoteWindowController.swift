import AppKit

final class NoteWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate, NSLayoutManagerDelegate, NoteDragZoneDelegate, TodoTextViewDelegate {
    private var note: Note
    private let store: NoteStore
    private let onClosed: (UUID) -> Void

    /// Labels currently on this note. Read by the app delegate to decide
    /// whether the window belongs on screen under the label filter.
    var labels: [String] { note.labels }

    /// The collapsed title bar is all you can see of a collapsed note, so a
    /// task list shows its remaining count there. Every path that changes the
    /// title or the body routes through here so the two can't drift apart.
    private func refreshCollapsedTitle() {
        guard let progress = MarkdownEditing.checkboxProgress(in: note.content) else {
            titleLabel.text = note.title
            return
        }
        let count = "\(progress.done)/\(progress.total)"
        titleLabel.text = note.title.isEmpty ? count : "\(note.title)   \(count)"
    }

    private let dragZone: NoteDragZone
    private let expandButton: NSButton
    private let trashButton: NSButton
    private let colorButton: NSButton
    private let titleField: FlushLeftTextField    // editable; visible expanded
    private let titleLabel: CenteredTitleLabel    // read-only; visible collapsed
    private let dateLabel: NSTextField
    private let footerView: NSView
    private let labelButton: NSButton
    private let labelStack: NSStackView
    private let labelPanel = LabelCompletionPanel()
    /// Character index of the `#` that triggered the active autocomplete
    /// session, if any. Cleared when the panel is dismissed.
    private var labelTriggerStart: Int?
    /// Container that holds titleField + scrollView + footer. We collapse the
    /// note by forcing this view's height to 0; otherwise its subviews'
    /// constraints would keep dictating the window's minimum content height.
    private let bodyContainer: NSView
    private var bodyHeightZeroConstraint: NSLayoutConstraint!

    private static let titleExpandedFont = NSFont.systemFont(ofSize: MarkdownStyler.baseFontSize + 7, weight: .bold)
    private static let titleCollapsedFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    private var dragZoneHeightConstraint: NSLayoutConstraint!

    private let textView: TodoTextView
    private let textStorage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private let scrollView: NSScrollView
    private let backgroundView: HoverTrackingView

    private var saveWorkItem: DispatchWorkItem?
    private var savingDisabled = false
    private var preCollapseHeight: CGFloat
    private var isHovering = false
    private var pendingExternalContent: String?

    /// True until the user types into this note. An untouched note left by a
    /// misfired hotkey is swept up on blur; a note that was typed into is
    /// never discarded automatically, even if it is empty now.
    private(set) var wasNeverEdited = true

    /// A note is disposable when nothing was ever typed into it and it holds
    /// nothing — the exact shape a mis-pressed ⌘⇧S leaves behind.
    var isAbandonedCapture: Bool {
        wasNeverEdited
            && note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Discard without archiving. Used for abandoned captures, which should
    /// leave no trace at all.
    func discardAbandonedCapture() {
        savingDisabled = true
        saveWorkItem?.cancel()
        saveWorkItem = nil
        store.discardActive(note)
        window?.close()
        onClosed(note.id)
    }

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
        let rawFrame = NSRect(x: note.positionX, y: note.positionY, width: note.width, height: displayHeight)
        let frame = NoteWindow.clampToVisibleScreen(rawFrame)
        if frame.origin != rawFrame.origin || frame.size != rawFrame.size {
            self.note.positionX = Double(frame.origin.x)
            self.note.positionY = Double(frame.origin.y)
            self.note.width = Double(frame.size.width)
            if !note.collapsed {
                self.note.height = Double(frame.size.height)
                self.preCollapseHeight = frame.size.height
            }
        }
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
        colorButton = NoteWindowController.makeChromeButton(
            symbol: "paintpalette",
            tooltip: "Change color"
        )
        labelButton = NoteWindowController.makeChromeButton(
            symbol: "tag",
            tooltip: "Add or edit labels"
        )
        labelStack = NSStackView()
        labelStack.translatesAutoresizingMaskIntoConstraints = false
        labelStack.orientation = .horizontal
        labelStack.spacing = 4
        labelStack.alignment = .centerY
        labelStack.distribution = .gravityAreas
        labelStack.setHuggingPriority(.defaultLow, for: .horizontal)

        // Two title surfaces:
        // - titleField: editable NSTextField shown when the note is expanded
        // - titleLabel: read-only NSView with manually-centered text shown
        //   when collapsed (NSTextField doesn't reliably center in tight bars)
        titleField = FlushLeftTextField()
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.stringValue = note.title
        titleField.placeholderString = "Title"
        titleField.setAccessibilityLabel("Note title")
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

        textView = TodoTextView(frame: .zero, textContainer: container)
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

        // Footer: relative date only — color is now changed via the t-shirt
        // button in the chrome row.
        dateLabel = NSTextField(labelWithString: "")
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        dateLabel.textColor = NSColor.black.withAlphaComponent(0.40)
        dateLabel.lineBreakMode = .byClipping

        footerView = NSView()
        footerView.translatesAutoresizingMaskIntoConstraints = false
        footerView.addSubview(dateLabel)
        footerView.addSubview(labelStack)
        footerView.addSubview(labelButton)

        backgroundView.addSubview(bodyContainer)
        backgroundView.addSubview(dragZone)
        bodyContainer.addSubview(titleField)
        bodyContainer.addSubview(scrollView)
        bodyContainer.addSubview(footerView)
        dragZone.addSubview(titleLabel)
        dragZone.addSubview(colorButton)
        dragZone.addSubview(expandButton)
        dragZone.addSubview(trashButton)

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
            // Order from right to left: trash, color (t-shirt), expand.
            trashButton.trailingAnchor.constraint(equalTo: dragZone.trailingAnchor, constant: -7),
            trashButton.centerYAnchor.constraint(equalTo: dragZone.centerYAnchor),
            trashButton.widthAnchor.constraint(equalToConstant: 13),
            trashButton.heightAnchor.constraint(equalToConstant: 13),

            colorButton.trailingAnchor.constraint(equalTo: trashButton.leadingAnchor, constant: -6),
            colorButton.centerYAnchor.constraint(equalTo: dragZone.centerYAnchor),
            colorButton.widthAnchor.constraint(equalToConstant: 13),
            colorButton.heightAnchor.constraint(equalToConstant: 13),

            expandButton.trailingAnchor.constraint(equalTo: colorButton.leadingAnchor, constant: -6),
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
            footerView.heightAnchor.constraint(equalToConstant: 18),

            dateLabel.leadingAnchor.constraint(equalTo: footerView.leadingAnchor),
            dateLabel.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),

            labelButton.trailingAnchor.constraint(equalTo: footerView.trailingAnchor),
            labelButton.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),
            labelButton.widthAnchor.constraint(equalToConstant: 13),
            labelButton.heightAnchor.constraint(equalToConstant: 13),

            labelStack.leadingAnchor.constraint(equalTo: dateLabel.trailingAnchor, constant: 6),
            labelStack.trailingAnchor.constraint(lessThanOrEqualTo: labelButton.leadingAnchor, constant: -6),
            labelStack.centerYAnchor.constraint(equalTo: footerView.centerYAnchor)
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
        textView.todoDelegate = self
        applyFloatLevel()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyAppearanceColors),
            name: Appearance.didChange,
            object: nil
        )
        textView.attachmentHandler = { [weak self] pasteboard in
            guard let self = self else { return nil }
            return Attachments.handlePaste(pasteboard, for: self.store)
        }
        titleField.delegate = self
        layoutManager.delegate = self
        dragZone.delegate = self

        expandButton.target = self
        expandButton.action = #selector(toggleCollapse)
        trashButton.target = self
        trashButton.action = #selector(closeNote)
        colorButton.target = self
        colorButton.action = #selector(showColorMenu)
        labelButton.target = self
        labelButton.action = #selector(showLabelMenu)

        labelPanel.onAccept = { [weak self] item in
            self?.acceptLabelCompletion(item)
        }

        backgroundView.onHoverChange = { [weak self] hovering in
            self?.isHovering = hovering
            self?.updateAlpha()
            self?.updateChromeVisibility()
        }

        updateDateLabel()
        updateChromeVisibility(animated: false)
        rebuildLabelChips()
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
    /// Put the caret at the end of the body. Used when a note arrives with
    /// text already in it, so the user can keep typing after it.
    func focusBodyEnd() {
        guard let window = window else { return }
        window.makeFirstResponder(textView)
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.scrollRangeToVisible(NSRange(location: end, length: 0))
    }

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
        // Mark the symbol as a template so contentTintColor always wins over
        // any default multicolor / hierarchical rendering the symbol ships
        // with — otherwise icons like `paintpalette` render in their built-in
        // colors and effectively disappear against pastel note backgrounds.
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(chromeSymbolConfig)
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = NoteWindowController.chromeColor
        button.toolTip = tooltip
        // Icon-only buttons have no title for VoiceOver to read.
        button.setAccessibilityLabel(tooltip)
        button.setAccessibilityRole(.button)
        button.alphaValue = 0
        return button
    }

    private func updateExpandButtonIcon() {
        let symbol = note.collapsed ? "chevron.down" : "chevron.up"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Collapse / expand")?
            .withSymbolConfiguration(NoteWindowController.chromeSymbolConfig)
        image?.isTemplate = true
        expandButton.image = image
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
                ctx.duration = Appearance.animationDuration(0.16)
                trashButton.animator().alphaValue = target
                expandButton.animator().alphaValue = target
                colorButton.animator().alphaValue = target
                labelButton.animator().alphaValue = target
            }
        } else {
            trashButton.alphaValue = target
            expandButton.alphaValue = target
            colorButton.alphaValue = target
            labelButton.alphaValue = target
        }
    }

    // MARK: - Actions

    @objc private func toggleCollapse() {
        performToggleCollapse()
    }

    @objc private func closeNote() {
        savingDisabled = true
        saveWorkItem?.cancel()
        saveWorkItem = nil
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

    // MARK: - Color picker

    @objc private func showColorMenu() {
        let menu = NSMenu()
        for color in NoteColor.allCases {
            let item = NSMenuItem(
                title: color.displayName,
                action: #selector(pickColor(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = color.rawValue
            item.image = NoteWindowController.colorSwatch(for: color)
            if color == note.color { item.state = .on }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for level in NoteFloatLevel.allCases {
            let item = NSMenuItem(
                title: level.displayName,
                action: #selector(pickFloatLevel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = level.rawValue
            if level == note.floatLevel { item.state = .on }
            menu.addItem(item)
        }

        let p = NSPoint(x: colorButton.bounds.minX, y: colorButton.bounds.maxY + 4)
        menu.popUp(positioning: nil, at: p, in: colorButton)
    }

    @objc private func pickFloatLevel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let level = NoteFloatLevel(rawValue: raw) else { return }
        note.floatLevel = level
        applyFloatLevel()
        scheduleSave()
    }

    /// A desktop-level note sits below other apps but above the wallpaper, and
    /// stops following you across Spaces — it belongs to the desk it's on.
    private func applyFloatLevel() {
        guard let window = window else { return }
        switch note.floatLevel {
        case .floating:
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        case .desktop:
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.collectionBehavior = [.stationary]
        }
    }

    @objc private func pickColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let color = NoteColor(rawValue: raw) else { return }
        note.color = color
        applyAppearanceColors()
        scheduleSave()
    }

    /// Repaint everything whose color depends on the note's color or the
    /// system appearance. Note windows are borderless and paint their own
    /// paper, so AppKit's automatic appearance handling never reaches them.
    @objc func applyAppearanceColors() {
        backgroundView.layer?.backgroundColor = NSColor(hex: note.color.bodyHex)?.cgColor
        titleField.textColor = MarkdownStyler.bodyTextColor
        titleLabel.textColor = MarkdownStyler.bodyTextColor
        textView.insertionPointColor = MarkdownStyler.bodyTextColor
        textView.typingAttributes[.foregroundColor] = MarkdownStyler.bodyTextColor
        MarkdownStyler.apply(to: textView)
        refreshMarkerVisibility()
        textView.needsDisplay = true
    }

    private static func colorSwatch(for color: NoteColor) -> NSImage {
        return NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let path = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                xRadius: 3,
                yRadius: 3
            )
            NSColor(hex: color.bodyHex)?.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.18).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
    }

    // MARK: - NSWindowDelegate

    func dragZoneDidEndDrag(suppressSnapping: Bool) {
        guard !suppressSnapping, let window = window else { return }
        let others = NSApp.windows
            .filter { $0 !== window && $0 is NoteWindow && $0.isVisible }
            .map { $0.frame }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        guard !screen.isEmpty else { return }

        let snapped = WindowArrangement.snap(window.frame, toScreen: screen, others: others)
        guard snapped != window.frame else { return }
        window.setFrameOrigin(snapped.origin)
    }

    /// Move this note to `frame`, animated. Used by the Arrange command.
    func setArrangedFrame(_ frame: NSRect, animated: Bool = true) {
        guard let window = window else { return }
        window.setFrame(frame, display: true, animate: animated)
        note.positionX = Double(frame.origin.x)
        note.positionY = Double(frame.origin.y)
        scheduleSave()
    }

    /// Current frame and whether the note is collapsed — the Arrange command
    /// needs both to lay notes out without resizing them.
    var arrangementSize: NSSize { window?.frame.size ?? NSSize(width: note.width, height: note.height) }

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
        // A hotkey misfire leaves an untouched empty note on the desk forever.
        // Sweep it up when focus moves on, but only if nothing was ever typed.
        if isAbandonedCapture {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isAbandonedCapture else { return }
                self.discardAbandonedCapture()
            }
            return
        }
        updateAlpha()
        updateChromeVisibility()
        hideLabelCompletion()
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
        let active = !note.collapsed || isKey || isHovering
        let faded = !active && Appearance.allowsFadedNotes
        let target: CGFloat = faded ? NoteWindowController.blurAlpha : NoteWindowController.activeAlpha
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Appearance.animationDuration(0.18)
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

    /// macOS sometimes resizes borderless+resizable windows when the display
    /// configuration changes (e.g. an external monitor is plugged in). Snap
    /// the frame back to the persisted dimensions so a collapsed note never
    /// blows up to the full screen width.
    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = window else { return }
        let storedWidth = CGFloat(note.width)
        let storedHeight: CGFloat = note.collapsed
            ? NoteWindowController.collapsedHeight
            : CGFloat(note.height)
        var frame = window.frame
        if abs(frame.size.width - storedWidth) < 0.5 &&
           abs(frame.size.height - storedHeight) < 0.5 { return }
        frame.origin.y += frame.size.height - storedHeight
        frame.size.width = storedWidth
        frame.size.height = storedHeight
        window.setFrame(frame, display: true, animate: false)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        note.content = textView.string
        wasNeverEdited = false
        refreshCollapsedTitle()
        MarkdownStyler.apply(to: textView)
        refreshMarkerVisibility()
        updateDateLabel()
        scheduleSave()
        detectSlashTrigger()
        detectLabelTrigger()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        refreshMarkerVisibility()
        // Caret moved away from the active `#word` → kill the panel.
        if labelTriggerStart != nil { detectLabelTrigger() }
    }

    // MARK: - NSTextFieldDelegate (title)

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === titleField else { return }
        note.title = titleField.stringValue
        wasNeverEdited = false
        refreshCollapsedTitle()
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

    /// Body editor key handling.
    /// - Up arrow on the first line → jump to title.
    /// - Enter inside a bullet/ordered/checkbox item → continue the list (or
    ///   strip the marker if the current item is empty, exiting the list).
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === self.textView else { return false }

        // While the autocomplete panel is up, arrow/enter/escape drive the
        // panel instead of the editor.
        if labelPanel.isVisible {
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                labelPanel.selectNext()
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                labelPanel.selectPrevious()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
               commandSelector == #selector(NSResponder.insertTab(_:)) {
                if labelPanel.acceptSelection() { return true }
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                hideLabelCompletion()
                return true
            }
        }

        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            let selection = textView.selectedRange()
            let str = textView.string as NSString
            let firstNewline = str.range(of: "\n")
            let onFirstLine = firstNewline.location == NSNotFound || selection.location <= firstNewline.location
            guard onFirstLine else { return false }
            focusTitle()
            return true
        }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            return handleListContinuation()
        }

        // Tab indents a list item; anywhere else it keeps its normal meaning.
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            return self.textView.indentSelection(outdent: false)
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            return self.textView.indentSelection(outdent: true)
        }

        return false
    }

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
        if let regex = try? NSRegularExpression(pattern: #"^([ \t]*)-\s\[[ xX]\]\s(.*)$"#),
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
        refreshCollapsedTitle()

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

            refreshCollapsedTitle()
            titleLabel.isHidden = false
            bodyContainer.isHidden = true
            bodyHeightZeroConstraint.isActive = true

            backgroundView.layer?.cornerRadius = 5
            dragZoneHeightConstraint.constant = NoteWindowController.collapsedHeight

            let newHeight = NoteWindowController.collapsedHeight
            frame.origin.y += frame.size.height - newHeight
            frame.size.height = newHeight
            window.setFrame(frame, display: true, animate: !Appearance.reduceMotion)
        } else {
            titleLabel.isHidden = true
            bodyContainer.isHidden = false
            bodyHeightZeroConstraint.isActive = false

            backgroundView.layer?.cornerRadius = 12
            dragZoneHeightConstraint.constant = NoteWindowController.chromeHeight

            let newHeight = preCollapseHeight
            frame.origin.y -= newHeight - frame.size.height
            frame.size.height = newHeight
            window.setFrame(frame, display: true, animate: !Appearance.reduceMotion)
            note.height = Double(newHeight)
        }
        updateExpandButtonIcon()
        updateChromeVisibility()
        updateAlpha()
        scheduleSave()
    }

    // MARK: - TodoTextViewDelegate

    /// Flip the bracket character (`[ ]` ↔ `[x]`) inside the markdown source
    /// for the checkbox at the given character index. The checkbox visual is
    /// re-rendered automatically when MarkdownStyler runs in textDidChange.
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
            refreshCollapsedTitle()
        }
        if updated.labels != note.labels {
            note.labels = updated.labels
            rebuildLabelChips()
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

    // MARK: - Labels

    private func rebuildLabelChips() {
        for view in labelStack.arrangedSubviews {
            labelStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for label in note.labels {
            let chip = LabelChipView(labelName: label)
            chip.onRemove = { [weak self] in
                self?.removeLabel(label)
            }
            labelStack.addArrangedSubview(chip)
        }
    }

    private func addLabel(_ raw: String) {
        let normalized = NoteLabel.normalize(raw)
        guard !normalized.isEmpty, !note.labels.contains(normalized) else { return }
        note.labels.append(normalized)
        rebuildLabelChips()
        scheduleSave()
    }

    private func removeLabel(_ name: String) {
        guard let idx = note.labels.firstIndex(of: name) else { return }
        note.labels.remove(at: idx)
        rebuildLabelChips()
        scheduleSave()
    }

    @objc private func showLabelMenu() {
        let menu = NSMenu()
        menu.font = NSFont.systemFont(ofSize: 12)

        let known = store.allLabels()
        let union = Array(Set(known).union(note.labels)).sorted()

        if union.isEmpty {
            let empty = NSMenuItem(title: "No labels yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for label in union {
                let item = NSMenuItem(
                    title: "#\(label)",
                    action: #selector(toggleLabelFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = label
                if note.labels.contains(label) { item.state = .on }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let createItem = NSMenuItem(
            title: "New Label…",
            action: #selector(createLabelFromMenu),
            keyEquivalent: ""
        )
        createItem.target = self
        menu.addItem(createItem)

        let p = NSPoint(x: labelButton.bounds.minX, y: labelButton.bounds.maxY + 4)
        menu.popUp(positioning: nil, at: p, in: labelButton)
    }

    @objc private func toggleLabelFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if note.labels.contains(name) {
            removeLabel(name)
        } else {
            addLabel(name)
        }
    }

    @objc private func createLabelFromMenu() {
        let alert = NSAlert()
        alert.messageText = "New Label"
        alert.informativeText = "Lowercase, no spaces. Other characters are stripped."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        field.placeholderString = "label-name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            addLabel(field.stringValue)
        }
    }

    // MARK: - Label autocomplete

    /// Look back from the caret for an active `#word` token and either show
    /// or update the autocomplete panel. Dismiss it when the cursor leaves
    /// the token's span.
    private func detectLabelTrigger() {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { hideLabelCompletion(); return }
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
                hideLabelCompletion()
                return
            }
            // Spaces / newlines end the token.
            if ch == " " || ch == "\t" || ch == "\n" {
                hideLabelCompletion()
                return
            }
            i -= 1
        }
        hideLabelCompletion()
    }

    private func showLabelCompletion(at hashLocation: Int, typed: String) {
        let normalizedQuery = NoteLabel.normalize(typed)
        let known = store.allLabels()
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
            hideLabelCompletion()
            return
        }

        labelTriggerStart = hashLocation
        labelPanel.setItems(items)
        positionLabelPanel(below: hashLocation)
        if !labelPanel.isVisible {
            labelPanel.orderFront(nil)
        }
    }

    private func hideLabelCompletion() {
        if labelPanel.isVisible { labelPanel.orderOut(nil) }
        labelTriggerStart = nil
    }

    private func positionLabelPanel(below charIndex: Int) {
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
        var frame = labelPanel.frame
        // Place panel so its TOP edge sits at the caret line.
        frame.origin = NSPoint(x: screenPoint.x, y: screenPoint.y - frame.size.height)
        labelPanel.setFrame(frame, display: false)
    }

    private func acceptLabelCompletion(_ item: LabelCompletionPanel.Item) {
        guard let start = labelTriggerStart else { return }
        let cursor = textView.selectedRange().location
        let length = max(0, cursor - start)
        guard start + length <= textStorage.length else {
            hideLabelCompletion()
            return
        }
        let range = NSRange(location: start, length: length)
        if textView.shouldChangeText(in: range, replacementString: "") {
            textStorage.replaceCharacters(in: range, with: "")
            textView.didChangeText()
            note.content = textView.string
        }
        addLabel(item.labelName)
        hideLabelCompletion()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        guard !savingDisabled else { return }
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, !self.savingDisabled else { return }
            self.note.updatedAt = Date()
            self.store.save(self.note)
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Tear down without persisting anything else. Used when the underlying
    /// file disappeared externally (e.g. an agent processed and removed the
    /// note) — without this guard, an in-flight debounced save would
    /// resurrect the file right after `reconcileOpenWindows` closed the
    /// window.
    func closeAfterExternalDeletion() {
        savingDisabled = true
        saveWorkItem?.cancel()
        saveWorkItem = nil
        window?.close()
    }
}
