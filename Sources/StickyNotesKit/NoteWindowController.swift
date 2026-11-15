import AppKit

@MainActor
final class NoteWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NoteDragZoneDelegate {
    /// The note's text, labels and file. The window draws it and forwards
    /// every change to it; none of the save rules live here.
    let noteDocument: NoteDocument
    private var note: Note { noteDocument.buffer }
    private let store: NoteStore
    /// Where this Mac keeps the window: the note's file holds none of it.
    private let layoutStore: DeviceLayoutStore
    private var geometry: NoteLayout
    private let clock: AppClock
    private let scheduler: Scheduler
    private let onClosed: (UUID) -> Void
    /// Called when the user archives this note, with everything needed to put
    /// it back exactly where it was.
    var onArchived: ((Note) -> Void)?
    /// Called when closing was refused because the text could not be saved.
    /// The argument runs the close again.
    var onCloseRefused: ((_ retry: @escaping () -> Void) -> Void)?
    /// Called when a label was removed with its chip, with what puts it back.
    var onLabelRemoved: ((_ label: String, _ restore: @escaping () -> Void) -> Void)?
    /// Called when the note left the active folder under typed text, and the text
    /// was written where the note went.
    var onTextKept: ((NoteDocument.KeptIn) -> Void)?

    /// How long a motion of the given nominal length lasts. Reduce Motion makes
    /// every one of them instant; a test replaces it to choose either case.
    var motionDuration: (TimeInterval) -> TimeInterval = { Appearance.animationDuration($0) }

    /// Where the menu-bar icon is, in screen coordinates, when it can be found.
    /// An archived note fades toward it.
    var archiveDestination: (() -> NSRect?)?

    /// The two motions of a note's life: it fades in when it is made, and fades
    /// out when it is archived.
    static let appearDuration: TimeInterval = 0.12
    static let archiveFadeDuration: TimeInterval = 0.12
    static let appearScale: CGFloat = 0.98
    static let appearAnimationKey = "noteAppear"

    /// True from the moment an archived note starts fading until its window is
    /// gone. The fade moves the window, which is not the person putting it
    /// somewhere, so none of it is recorded as the note's place.
    private(set) var isFadingOut = false

    /// Labels currently on this note. Read by the app delegate to decide
    /// whether the window belongs on screen under the label filter.
    var labels: [String] { note.labels }

    /// Identity of the note this window is showing.
    var noteId: UUID { note.id }

    /// The collapsed title bar is all you can see of a collapsed note, so a
    /// task list shows its remaining count there. Every path that changes the
    /// title or the body routes through here so the two can't drift apart.
    private func refreshCollapsedTitle() {
        let name = note.title.isEmpty ? "Untitled" : note.title
        guard let progress = MarkdownEditing.checkboxProgress(in: note.content) else {
            titleLabel.text = note.title
            titleLabel.spokenTitle = name
            return
        }
        let count = "\(progress.done)/\(progress.total)"
        titleLabel.text = note.title.isEmpty ? count : "\(note.title)   \(count)"
        titleLabel.spokenTitle = "\(name), \(progress.done) of \(progress.total) tasks done"
    }

    private let dragZone: NoteDragZone
    private let expandButton: NSButton
    private let trashButton: NSButton
    private let colorButton: NSButton
    let titleField: FlushLeftTextField            // editable; visible expanded
    private let titleLabel: CenteredTitleLabel    // read-only; visible collapsed
    private let dateLabel: NSTextField
    private let footerView: NSView
    private let labelButton: NSButton
    private let labelStack: NSStackView
    /// Container that holds titleField + scrollView + footer. We collapse the
    /// note by forcing this view's height to 0; otherwise its subviews'
    /// constraints would keep dictating the window's minimum content height.
    private let bodyContainer: NSView
    private var bodyHeightZeroConstraint: NSLayoutConstraint!

    /// The title is seven points above the body, so it follows the text size.
    static var titleExpandedFont: NSFont {
        NSFont.systemFont(ofSize: MarkdownStyler.baseFontSize + 7, weight: .bold)
    }
    private static let titleCollapsedFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    private var dragZoneHeightConstraint: NSLayoutConstraint!
    private var titleHeightConstraint: NSLayoutConstraint!

    /// The Markdown editor this window hosts.
    let editor: MarkdownEditorController
    var textView: TodoTextView { editor.textView }
    private let scrollView: NSScrollView
    private let backgroundView: HoverTrackingView
    private let resizeGrip = ResizeGripView()

    private var preCollapseHeight: CGFloat
    private var isHovering = false

    /// True when this note was never touched and holds nothing: the shape a
    /// mis-pressed ⌘⇧S leaves behind.
    var isAbandonedCapture: Bool { noteDocument.isAbandonedCapture }

    /// True once a file exists for this note. A new note has none until it is
    /// typed into, and is not gone for lacking one.
    var hasFile: Bool { noteDocument.hasFile }

    /// Try to write the note again, after the debounce.
    func requestSave() { noteDocument.requestSave() }

    /// The note's file is gone and its text could not be written anywhere.
    var isStranded: Bool { noteDocument.isStranded }

    /// Discard without archiving. Used for abandoned captures, which should
    /// leave no trace at all. Text that arrived from outside since the window
    /// was opened is on screen now, and the note stays.
    func discardAbandonedCapture() {
        closeThroughDocument(.discard)
    }

    /// Height of the chrome strip when expanded.
    static let chromeHeight: CGFloat = 22
    /// Height of the title row sitting below the chrome when expanded: 28 at the
    /// default text size, taller when a large title would not fit in it.
    static func titleRowHeight(for font: NSFont) -> CGFloat {
        max(28, ceil(font.ascender - font.descender + font.leading) + 4)
    }
    /// Window height when collapsed (matches the chrome strip exactly).
    static let collapsedHeight: CGFloat = 22

    private static let humanDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let blurAlpha: CGFloat = 0.7
    private static let activeAlpha: CGFloat = 1.0
    private static var chromeColor: NSColor { Appearance.chromeInk }

    /// `layout` holds this Mac's window for every note. A note it has no entry
    /// for is placed by `placing`, given the size the note was saved at, which
    /// is where a note from another Mac or from Obsidian first appears.
    init(
        note: Note,
        store: NoteStore,
        layout layoutStore: DeviceLayoutStore = DeviceLayoutStore(),
        placing: ((CGSize) -> CGRect)? = nil,
        clock: AppClock = SystemClock(),
        scheduler: Scheduler = MainScheduler(),
        onClosed: @escaping (UUID) -> Void
    ) {
        // Every caller hands over a note as just saved or as last read, so
        // the file watcher's echo of it is not an outside edit.
        let document = NoteDocument(note: note, repository: store, scheduler: scheduler, clock: clock)
        document.createsFileOnFirstEdit = true
        self.noteDocument = document
        self.store = store
        self.layoutStore = layoutStore
        self.clock = clock
        self.scheduler = scheduler
        self.onClosed = onClosed
        var layout = NoteWindowController.resolveLayout(
            for: note, in: layoutStore, placing: placing ?? NoteWindowController.placeOnPointerScreen
        )
        self.geometry = layout
        self.preCollapseHeight = CGFloat(layout.height)

        let displayHeight: CGFloat = layout.collapsed
            ? NoteWindowController.collapsedHeight
            : CGFloat(layout.height)
        let rawFrame = NSRect(x: layout.x, y: layout.y, width: layout.width, height: displayHeight)
        let frame = NoteWindow.clampToVisibleScreen(rawFrame)
        if frame.origin != rawFrame.origin || frame.size != rawFrame.size {
            layout.x = Double(frame.origin.x)
            layout.y = Double(frame.origin.y)
            layout.width = Double(frame.size.width)
            if !layout.collapsed { layout.height = Double(frame.size.height) }
            self.geometry = layout
            layoutStore.set(layout, for: note.id)
            if !layout.collapsed { self.preCollapseHeight = frame.size.height }
        }
        let window = NoteWindow(contentRect: frame)

        backgroundView = HoverTrackingView(frame: .zero)
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = layout.collapsed ? 5 : 12
        backgroundView.layer?.masksToBounds = true
        backgroundView.layer?.backgroundColor = NSColor(hex: note.color.bodyHex)?.cgColor

        // Drag zone — fills the top edge, handles drag + double-click.
        dragZone = NoteDragZone()
        dragZone.translatesAutoresizingMaskIntoConstraints = false

        expandButton = NoteWindowController.makeChromeButton(
            symbol: layout.collapsed ? "chevron.down" : "chevron.up",
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
        titleLabel.isHidden = !layout.collapsed
        titleLabel.spokenTitle = note.title.isEmpty ? "Untitled" : note.title
        dragZone.reportsSingleClick = layout.collapsed

        bodyContainer = NSView()
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.wantsLayer = true
        bodyContainer.layer?.masksToBounds = true

        editor = MarkdownEditorController(text: note.content, store: store, clock: clock, options: .note)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = editor.textView

        // Footer: relative date only — color is now changed via the t-shirt
        // button in the chrome row.
        dateLabel = NSTextField(labelWithString: "")
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        dateLabel.textColor = Appearance.secondaryInk
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

        resizeGrip.translatesAutoresizingMaskIntoConstraints = false
        resizeGrip.alphaValue = 0
        backgroundView.addSubview(resizeGrip)
        dragZone.addSubview(colorButton)
        dragZone.addSubview(expandButton)
        dragZone.addSubview(trashButton)

        let initialChromeHeight: CGFloat = layout.collapsed
            ? NoteWindowController.collapsedHeight
            : NoteWindowController.chromeHeight
        dragZoneHeightConstraint = dragZone.heightAnchor.constraint(equalToConstant: initialChromeHeight)

        titleHeightConstraint = titleField.heightAnchor.constraint(
            equalToConstant: NoteWindowController.titleRowHeight(for: NoteWindowController.titleExpandedFont)
        )

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
            resizeGrip.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
            resizeGrip.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor),
            resizeGrip.widthAnchor.constraint(equalToConstant: 18),
            resizeGrip.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: dragZone.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: dragZone.trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: dragZone.topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: dragZone.bottomAnchor),

            // Expanded title field sits at the top of the body container.
            titleField.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor, constant: 14),
            titleField.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor, constant: -14),
            titleField.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            titleHeightConstraint,

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
        if layout.collapsed {
            bodyContainer.isHidden = true
            bodyHeightZeroConstraint.isActive = true
        }

        super.init(window: window)
        window.delegate = self
        window.alphaValue = NoteWindowController.blurAlpha
        window.initialFirstResponder = textView
        window.minSize = NSSize(width: 120, height: NoteWindowController.collapsedHeight)
        window.contentMinSize = NSSize(width: 120, height: NoteWindowController.collapsedHeight)
        editor.onTextChange = { [weak self] text in
            guard let self = self else { return }
            self.noteDocument.setBody(text)
            self.refreshCollapsedTitle()
            self.updateDateLabel()
        }
        editor.onMoveUpFromFirstLine = { [weak self] in self?.focusTitle() }
        editor.labelProvider = { [weak store] in store?.allLabels() ?? [] }
        editor.onLabelTyped = { [weak self] name in self?.addLabel(name) }
        textView.onCommandDragEnded = { [weak self] in
            self?.dragZoneDidEndDrag(suppressSnapping: false)
        }
        applyFloatLevel()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyAppearanceColors),
            name: Appearance.didChange,
            object: nil
        )
        titleField.delegate = self
        dragZone.delegate = self

        noteDocument.isEditing = { [weak self] in
            guard let self = self, let window = self.window, window.isKeyWindow else { return false }
            return window.firstResponder === self.textView || self.titleField.currentEditor() != nil
        }
        noteDocument.isEditingTitle = { [weak self] in
            self?.titleField.currentEditor() != nil
        }
        noteDocument.didApplyExternal = { [weak self] applied in
            self?.showExternalChange(applied)
        }
        noteDocument.didKeepText = { [weak self] place in
            self?.onTextKept?(place)
        }

        titleLabel.onPress = { [weak self] in self?.dragZoneDidClick() }
        resizeGrip.onResize = { [weak self] dx, dy in self?.resizeByAccessibilityAction(dx: dx, dy: dy) }
        updateButtonAccessibility()

        expandButton.target = self
        expandButton.action = #selector(toggleCollapse)
        trashButton.target = self
        trashButton.action = #selector(closeNote)
        colorButton.target = self
        colorButton.action = #selector(showColorMenu)
        labelButton.target = self
        labelButton.action = #selector(showLabelMenu)

        backgroundView.onHoverChange = { [weak self] hovering in
            self?.isHovering = hovering
            self?.updateAlpha()
            self?.updateChromeVisibility()
        }

        updateDateLabel()
        updateChromeVisibility(animated: false)
        rebuildLabelChips()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeDidChange(_:)),
            name: NoteStore.didChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The layout this Mac has for `note`. Without one, a note whose file still
    /// has the keys an older build wrote takes its window from them, once; any
    /// other note is placed by `placing` at the size it was saved at. Either way
    /// the result is kept, so the note stays where it was put.
    static func resolveLayout(
        for note: Note, in store: DeviceLayoutStore, placing: (CGSize) -> CGRect
    ) -> NoteLayout {
        if let known = store.layout(for: note.id) { return known }
        let layout: NoteLayout
        if let legacy = note.legacyPlacement {
            layout = NoteLayout(
                x: legacy.x, y: legacy.y, width: note.width, height: note.height, collapsed: legacy.collapsed
            )
        } else {
            layout = NoteLayout(frame: placing(CGSize(width: note.width, height: note.height)))
        }
        store.set(layout, for: note.id)
        return layout
    }

    /// A first placement for a window made without a desk: on the screen the
    /// pointer is on.
    static func placeOnPointerScreen(size: CGSize) -> CGRect {
        let screen = NotePlacement.screenUnderPointer(
            mouse: NSEvent.mouseLocation,
            screens: NSScreen.screens.map(\.visibleFrame),
            main: NSScreen.main?.visibleFrame
        ) ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NotePlacement.next(previous: nil, screen: screen, size: size)
    }

    /// Record where the window is now, and the size as the hint the next save
    /// of the note writes. The note file is not touched.
    private func recordFrame(_ frame: NSRect, resized: Bool) {
        guard !isFadingOut else { return }
        geometry.x = Double(frame.origin.x)
        geometry.y = Double(frame.origin.y)
        if resized {
            geometry.width = Double(frame.size.width)
            if !geometry.collapsed {
                geometry.height = Double(frame.size.height)
                preCollapseHeight = frame.size.height
            }
            let width = geometry.width, height = geometry.height
            noteDocument.adjust(save: false) { $0.width = width; $0.height = height }
        }
        layoutStore.set(geometry, for: note.id)
    }

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

    /// What VoiceOver says for the chrome buttons that change with the note.
    private func updateButtonAccessibility() {
        expandButton.setAccessibilityLabel(geometry.collapsed ? "Expand note" : "Collapse note")
        colorButton.setAccessibilityRole(.menuButton)
        colorButton.setAccessibilityLabel("Color and float level")
        colorButton.setAccessibilityValue(note.color.displayName)
        labelButton.setAccessibilityRole(.menuButton)
        labelButton.setAccessibilityLabel("Labels")
        resizeGrip.isResizable = !geometry.collapsed
    }

    /// Change the size as the corner drag would, for VoiceOver. The top-left
    /// corner stays where it is.
    private func resizeByAccessibilityAction(dx: CGFloat, dy: CGFloat) {
        guard let window = window, !geometry.collapsed else { return }
        var frame = window.frame
        let size = NSSize(
            width: max(window.minSize.width, frame.width + dx),
            height: max(window.minSize.height, frame.height + dy)
        )
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(NoteWindow.clampToVisibleScreen(frame), display: true, animate: false)
    }

    private func updateExpandButtonIcon() {
        let symbol = geometry.collapsed ? "chevron.down" : "chevron.up"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Collapse / expand")?
            .withSymbolConfiguration(NoteWindowController.chromeSymbolConfig)
        image?.isTemplate = true
        expandButton.image = image
    }

    /// Chrome buttons appear only when the note is expanded AND focused (or
    /// hovered) — like TickTick. Hidden the rest of the time so the unfocused
    /// note is just paper + content.
    private func updateChromeVisibility(animated: Bool = true) {
        guard !isFadingOut else { return }
        let isKey = window?.isKeyWindow ?? false
        let shouldShow = !geometry.collapsed && (isKey || isHovering)
        let target: CGFloat = shouldShow ? 1.0 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Appearance.animationDuration(0.16)
                trashButton.animator().alphaValue = target
                expandButton.animator().alphaValue = target
                colorButton.animator().alphaValue = target
                labelButton.animator().alphaValue = target
                resizeGrip.animator().alphaValue = target
            }
        } else {
            trashButton.alphaValue = target
            expandButton.alphaValue = target
            colorButton.alphaValue = target
            resizeGrip.alphaValue = target
            labelButton.alphaValue = target
        }
    }

    // MARK: - Actions

    @objc func toggleCollapse() {
        performToggleCollapse()
    }

    var isCollapsed: Bool { geometry.collapsed }

    /// Open the find bar over the body, for ⌘F. A collapsed note shows no body.
    func showFindBar() {
        guard !geometry.collapsed, let window = window else { return }
        window.makeFirstResponder(textView)
        let show = NSMenuItem()
        show.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(show)
    }

    @objc func closeNote() {
        // Capture the frame first: the window is about to close, and undo
        // should restore the note where it actually sat.
        if let frame = window?.frame { recordFrame(frame, resized: false) }
        closeThroughDocument(.archive)
    }

    private func closeThroughDocument(_ reason: NoteDocument.CloseReason) {
        switch noteDocument.close(reason) {
        case .refused:
            // A note to be discarded that turned out to hold text just stays.
            guard reason == .archive else { return }
            NSSound.beep()
            onCloseRefused?({ [weak self] in self?.closeNote() })
            return
        case let .closed(archived):
            if let archived = archived { onArchived?(archived) }
        }
        // The note is saved and gone from the desk's books by now; only the
        // picture of it is still on screen for the length of the fade.
        let id = note.id
        closeWindow(fading: reason == .archive)
        onClosed(id)
    }

    /// Close the window. An archived note that is on screen fades toward the
    /// menu-bar icon first, unless the person asked for less motion.
    private func closeWindow(fading: Bool) {
        guard let window = window else { return }
        let duration = fading && window.isVisible
            ? motionDuration(NoteWindowController.archiveFadeDuration) : 0
        guard duration > 0 else {
            window.close()
            return
        }
        isFadingOut = true
        window.ignoresMouseEvents = true
        var target = window.frame
        if let icon = archiveDestination?() {
            target.origin.x += (icon.midX - target.midX) * 0.2
            target.origin.y += (icon.midY - target.midY) * 0.2
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            window.animator().alphaValue = 0
            window.animator().setFrame(target, display: true)
        }
        _ = scheduler.schedule(after: duration) { [self] in
            self.window?.close()
        }
    }

    /// A new note comes in: it fades up from 98 % of its size, growing from its
    /// top-left corner, the corner the cascade of new notes is anchored to.
    func animateIn() {
        let duration = motionDuration(NoteWindowController.appearDuration)
        guard duration > 0, let layer = backgroundView.layer else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        let size = layer.bounds.size
        let scale = NoteWindowController.appearScale
        let anchor = CGPoint(x: layer.anchorPoint.x * size.width, y: layer.anchorPoint.y * size.height)
        let corner = CGPoint(x: 0, y: size.height)
        let shift = CATransform3DMakeTranslation(
            (corner.x - anchor.x) * (1 - scale), (corner.y - anchor.y) * (1 - scale), 0
        )

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: CATransform3DScale(shift, scale, scale, 1))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        let group = CAAnimationGroup()
        group.animations = [fade, grow]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: NoteWindowController.appearAnimationKey)
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
        setFloatLevel(level)
    }

    var floatLevel: NoteFloatLevel { note.floatLevel }

    func setFloatLevel(_ level: NoteFloatLevel) {
        guard level != note.floatLevel else { return }
        noteDocument.edit { $0.floatLevel = level }
        applyFloatLevel()
    }

    /// A desktop-level note sits below other apps but above the wallpaper, and
    /// stops following you across Spaces — it belongs to the desk it's on.
    private func applyFloatLevel() {
        guard let window = window else { return }
        switch note.floatLevel {
        case .floating:
            window.level = .floating
        case .desktop:
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        }
        window.collectionBehavior = NoteWindow.collectionBehavior(for: note.floatLevel)
    }

    @objc private func pickColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let color = NoteColor(rawValue: raw) else { return }
        setColor(color)
    }

    var color: NoteColor { note.color }

    func setColor(_ color: NoteColor) {
        guard color != note.color else { return }
        noteDocument.edit { $0.color = color }
        colorButton.setAccessibilityValue(color.displayName)
        applyAppearanceColors()
    }

    /// Repaint everything whose color depends on the note's color or the
    /// system appearance. Note windows are borderless and paint their own
    /// paper, so AppKit's automatic appearance handling never reaches them.
    @objc func applyAppearanceColors() {
        backgroundView.layer?.backgroundColor = NSColor(hex: note.color.bodyHex)?.cgColor
        titleField.textColor = MarkdownStyler.bodyTextColor
        titleLabel.textColor = MarkdownStyler.bodyTextColor

        // Chrome paints itself on the note's paper, so nothing here follows
        // the system appearance on its own.
        for button in [expandButton, trashButton, colorButton, labelButton] {
            button.contentTintColor = NoteWindowController.chromeColor
        }
        dateLabel.textColor = Appearance.secondaryInk
        rebuildLabelChips()
        resizeGrip.needsDisplay = true

        editor.applyColors()
    }

    /// Re-apply styling after the shared text size changes.
    func restyleForTextSize() {
        let font = NoteWindowController.titleExpandedFont
        titleField.font = font
        titleField.currentEditor()?.font = font
        titleHeightConstraint.constant = NoteWindowController.titleRowHeight(for: font)
        editor.applyTextSize()
    }

    static func colorSwatch(for color: NoteColor) -> NSImage {
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

    /// A collapsed note is an 18pt bar whose only affordance is knowing to
    /// double-click it. One click expands.
    func dragZoneDidClick() {
        guard geometry.collapsed else { return }
        dragZoneDidDoubleClick()
    }

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
        flashSnapFeedback()
    }

    /// Snapping teleports the note on drop with no acknowledgement, which
    /// reads as a glitch the first time. A brief pulse of the border shows
    /// what happened and teaches the feature by demonstrating it.
    private func flashSnapFeedback() {
        guard !Appearance.reduceMotion, let layer = backgroundView.layer else { return }
        layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        layer.borderWidth = 2
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            guard let layer = self?.backgroundView.layer else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                layer.borderWidth = 0
            }
        }
    }

    /// Move this note to `frame`, animated. Used by the Arrange command.
    func setArrangedFrame(_ frame: NSRect, animated: Bool = true) {
        guard let window = window else { return }
        window.setFrame(frame, display: true, animate: animated)
        recordFrame(frame, resized: false)
    }

    /// Current frame and whether the note is collapsed — the Arrange command
    /// needs both to lay notes out without resizing them.
    var arrangementSize: NSSize { window?.frame.size ?? NSSize(width: geometry.width, height: geometry.height) }

    func windowDidMove(_ notification: Notification) {
        guard let frame = window?.frame else { return }
        recordFrame(frame, resized: false)
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
        editor.dismissLabelCompletion()
        noteDocument.blur()
    }

    /// Refresh the window's opacity from the outside, for a window that was
    /// ordered in without ever becoming key.
    func refreshAlpha() {
        updateAlpha()
    }

    private func updateAlpha() {
        guard let window = window, !isFadingOut else { return }
        let isKey = window.isKeyWindow
        let active = !geometry.collapsed || isKey || isHovering
        let faded = !active && Appearance.allowsFadedNotes
        let target: CGFloat = faded ? NoteWindowController.blurAlpha : NoteWindowController.activeAlpha
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Appearance.animationDuration(0.18)
            window.animator().alphaValue = target
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let frame = window?.frame else { return }
        recordFrame(frame, resized: true)
    }

    /// macOS sometimes resizes borderless+resizable windows when the display
    /// configuration changes (e.g. an external monitor is plugged in). Snap
    /// the frame back to the persisted dimensions so a collapsed note never
    /// blows up to the full screen width.
    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = window else { return }
        let storedWidth = CGFloat(geometry.width)
        let storedHeight: CGFloat = geometry.collapsed
            ? NoteWindowController.collapsedHeight
            : CGFloat(geometry.height)
        var frame = window.frame
        if abs(frame.size.width - storedWidth) < 0.5 &&
           abs(frame.size.height - storedHeight) < 0.5 { return }
        frame.origin.y += frame.size.height - storedHeight
        frame.size.width = storedWidth
        frame.size.height = storedHeight
        // The display arrangement just changed, so the stored geometry can
        // easily describe a spot that no longer exists — a monitor that was
        // unplugged. Clamping only at launch stranded the note until relaunch.
        frame = NoteWindow.clampToVisibleScreen(frame)
        window.setFrame(frame, display: true, animate: false)
        recordFrame(frame, resized: false)
    }

    // MARK: - NSTextFieldDelegate (title)

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === titleField else { return }
        noteDocument.setTitle(titleField.stringValue)
        refreshCollapsedTitle()
        updateDateLabel()
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

    private func updateDateLabel() {
        dateLabel.stringValue = relativeDateString(for: clock.now())
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

    // MARK: - Collapse

    private func performToggleCollapse() {
        guard let window = window else { return }
        geometry.collapsed.toggle()
        layoutStore.set(geometry, for: note.id)
        var frame = window.frame
        if geometry.collapsed {
            // Commit any in-flight title edit, and take focus out of the hidden
            // body so typing and paste cannot reach text nobody can see.
            if let responder = window.firstResponder as? NSView, responder.isDescendant(of: bodyContainer) {
                window.makeFirstResponder(nil)
            }
            preCollapseHeight = frame.size.height

            refreshCollapsedTitle()
            titleLabel.isHidden = false
            dragZone.reportsSingleClick = true
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
            dragZone.reportsSingleClick = false
            bodyContainer.isHidden = false
            bodyHeightZeroConstraint.isActive = false

            backgroundView.layer?.cornerRadius = 12
            dragZoneHeightConstraint.constant = NoteWindowController.chromeHeight

            let newHeight = preCollapseHeight
            frame.origin.y -= newHeight - frame.size.height
            frame.size.height = newHeight
            // A collapsed note dragged near the bottom edge would otherwise
            // expand straight off the screen, leaving only its title bar.
            frame = NoteWindow.clampToVisibleScreen(frame)
            window.setFrame(frame, display: true, animate: !Appearance.reduceMotion)
            recordFrame(frame, resized: true)
            window.makeFirstResponder(textView)
        }
        updateExpandButtonIcon()
        updateButtonAccessibility()
        updateChromeVisibility()
        updateAlpha()
    }

    // MARK: - External change sync

    @objc private func storeDidChange(_ notification: Notification) {
        // A save by this store is already in memory, and another note's save
        // is not about this file: neither is worth a disk read.
        if case let .saved(id) = NoteStore.change(in: notification) {
            if id == note.id, notification.object as AnyObject !== store,
               let written = store.snapshot(id: id) {
                // Another store wrote this note. This store's cache cannot
                // hold that write, so the file itself is the only place to look.
                noteDocument.externalChange(written.note, fingerprint: written.fingerprint)
            }
            return
        }
        handleStoreChange()
    }

    @objc func handleStoreChange() {
        noteDocument.storeDidChange()
    }

    /// Draw the parts of the buffer that an outside version just replaced.
    /// Setting the field and the storage directly does not call back into the
    /// delegate methods, so this never counts as an edit.
    private func showExternalChange(_ applied: NoteDocument.Applied) {
        if applied.title {
            titleField.stringValue = note.title
            refreshCollapsedTitle()
        }
        if applied.labels {
            rebuildLabelChips()
        }
        if applied.content {
            // The collapsed bar shows a checkbox count drawn from the body,
            // so a content-only edit has to refresh it too.
            refreshCollapsedTitle()
            editor.replaceText(note.content)
            updateDateLabel()
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
                self?.removeLabelOfferingUndo(label)
            }
            labelStack.addArrangedSubview(chip)
        }
    }

    private func addLabel(_ raw: String) {
        let normalized = NoteLabel.normalize(raw)
        guard !normalized.isEmpty, !note.labels.contains(normalized) else { return }
        noteDocument.edit { $0.labels.append(normalized) }
        rebuildLabelChips()
    }

    private func removeLabel(_ name: String) {
        guard let idx = note.labels.firstIndex(of: name) else { return }
        noteDocument.adjust { $0.labels.remove(at: idx) }
        rebuildLabelChips()
    }

    /// A chip is one click or key press, so removing a label that way can be
    /// taken back: the label returns to the place it had.
    func removeLabelOfferingUndo(_ name: String) {
        guard let idx = note.labels.firstIndex(of: name) else { return }
        removeLabel(name)
        onLabelRemoved?(name) { [weak self] in
            guard let self = self, !self.note.labels.contains(name) else { return }
            self.noteDocument.adjust { $0.labels.insert(name, at: min(idx, $0.labels.count)) }
            self.rebuildLabelChips()
        }
    }

    @objc func showLabelMenu() {
        guard !geometry.collapsed else { return }
        let menu = makeLabelMenu()
        let p = NSPoint(x: labelButton.bounds.minX, y: labelButton.bounds.maxY + 4)
        menu.popUp(positioning: nil, at: p, in: labelButton)
    }

    /// The labels to toggle on this note. A new one is made by typing `#name`
    /// in the body, so the menu offers no way to type one.
    func makeLabelMenu() -> NSMenu {
        let menu = NSMenu()
        menu.font = NSFont.systemFont(ofSize: 12)

        let known = store.allLabels()
        let union = Array(Set(known).union(note.labels)).sorted()

        if union.isEmpty {
            let empty = NSMenuItem(title: "No labels yet. Type #name in the note.", action: nil, keyEquivalent: "")
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
        return menu
    }

    @objc private func toggleLabelFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if note.labels.contains(name) {
            removeLabel(name)
        } else {
            addLabel(name)
        }
    }

    // MARK: - Persistence

    /// Write any debounced edit immediately. Quitting (or archiving) mid-sentence
    /// would otherwise drop everything typed since the last pause.
    ///
    /// Returns false when the text did not reach disk, so a caller that is
    /// about to end the process can save it somewhere else.
    @discardableResult
    func flushPendingSave() -> Bool {
        noteDocument.flush()
    }

    /// The note as the window shows it now, which may be ahead of the file.
    var bufferedNote: Note { note }

    /// Tear down without persisting anything else. Used when the underlying
    /// file disappeared externally (e.g. an agent processed and removed the
    /// note) — without this guard, an in-flight debounced save would
    /// resurrect the file right after `reconcileOpenWindows` closed the
    /// window.
    ///
    /// Text typed since the last save is written where the note went first. When
    /// that cannot be done the window stays open, a retry is armed, and this
    /// returns false. `textKeptElsewhere` is for a caller that has put the text
    /// in a recovery file itself.
    @discardableResult
    func closeAfterExternalDeletion(textKeptElsewhere: Bool = false) -> Bool {
        guard case .closed = noteDocument.close(textKeptElsewhere ? .externalDeletionTextKept : .externalDeletion) else {
            return false
        }
        window?.close()
        return true
    }
}
