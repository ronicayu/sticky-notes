import AppKit

/// Singleton floating window pinned to today's Obsidian daily note. Reads
/// and writes the underlying `.md` as raw markdown — no frontmatter
/// injection — so Obsidian and other plugins remain authoritative for
/// formatting. Window chrome (position / size / color) is persisted to
/// `<vault>/StickyNotes/_daily.json` via `DailyNote.saveState`.
@MainActor
final class DailyNoteWindowController: NSWindowController, NSWindowDelegate, NoteDragZoneDelegate {
    private let settings: Settings
    private let clock: AppClock

    /// Which file today's note is, what it holds, and every save and merge
    /// rule. The window draws it and forwards typing.
    let dailyDocument: DailyDocument

    private var state: DailyNoteState

    private let dragZone: NoteDragZone
    private let dateLabel: CenteredTitleLabel
    private let closeButton: NSButton
    private let collapseButton: NSButton
    private let backgroundView: HoverTrackingView
    /// The Markdown editor this window hosts. Its pasted images go to the same
    /// attachments folder as everyone else's, although the daily note itself is
    /// a vault file rather than a stored note.
    let editor: MarkdownEditorController
    var textView: TodoTextView { editor.textView }
    private let scrollView: NSScrollView

    private var fileWatcher: FileWatcher?

    /// Height used when expanding back from a collapsed state. Captured at
    /// collapse time, since while collapsed the live window frame is just
    /// the chrome strip.
    private var preCollapseHeight: CGFloat

    private static let chromeHeight: CGFloat = 26
    private static let collapsedTotalHeight: CGFloat = 26
    private static let placeholder = "Waiting for today's note to download…"

    init(settings: Settings, store: NoteStore, clock: AppClock, scheduler: Scheduler = MainScheduler()) {
        self.settings = settings
        self.clock = clock
        self.dailyDocument = DailyDocument(settings: settings, clock: clock, scheduler: scheduler)
        self.state = DailyNote.loadState(settings: settings)
        self.preCollapseHeight = CGFloat(state.height)

        let displayHeight: CGFloat = state.collapsed
            ? DailyNoteWindowController.collapsedTotalHeight
            : CGFloat(state.height)
        let rawFrame = NSRect(
            x: state.positionX,
            y: state.positionY,
            width: state.width,
            height: displayHeight
        )
        let frame = NoteWindow.clampToVisibleScreen(rawFrame)
        if frame.origin != rawFrame.origin || frame.size != rawFrame.size {
            self.state.positionX = Double(frame.origin.x)
            self.state.positionY = Double(frame.origin.y)
            self.state.width = Double(frame.size.width)
            if !state.collapsed {
                self.state.height = Double(frame.size.height)
                self.preCollapseHeight = frame.size.height
            }
        }
        let window = NoteWindow(contentRect: frame)

        backgroundView = HoverTrackingView(frame: .zero)
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 12
        backgroundView.layer?.masksToBounds = true
        backgroundView.layer?.backgroundColor = NSColor(hex: state.color.bodyHex)?.cgColor

        dragZone = NoteDragZone()
        dragZone.translatesAutoresizingMaskIntoConstraints = false

        dateLabel = CenteredTitleLabel(frame: .zero)
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        dateLabel.textColor = Appearance.chromeInk
        dateLabel.placeholder = ""

        closeButton = DailyNoteWindowController.makeChromeButton(
            symbol: "xmark",
            tooltip: "Hide"
        )
        collapseButton = DailyNoteWindowController.makeChromeButton(
            symbol: state.collapsed ? "chevron.down" : "chevron.up",
            tooltip: "Collapse / expand"
        )

        editor = MarkdownEditorController(store: store, clock: clock, options: .daily)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = editor.textView

        super.init(window: window)
        window.delegate = self
        editor.onTextChange = { [weak self] text in self?.dailyDocument.setBody(text) }

        setupLayout()
        closeButton.target = self
        closeButton.action = #selector(hideNote)
        collapseButton.target = self
        collapseButton.action = #selector(toggleCollapse)
        dragZone.delegate = self

        dailyDocument.isEditing = { [weak self] in
            guard let self = self, let window = self.window, window.isKeyWindow else { return false }
            return window.firstResponder === self.textView
        }
        dailyDocument.onBodyReplaced = { [weak self] in self?.showDocument() }
        dailyDocument.onFileChanged = { [weak self] in self?.startWatching() }
        dailyDocument.load()
        startWatching()
        dailyDocument.startRollover()
        // Borderless window painting its own paper: nothing here follows the
        // system appearance on its own.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyAppearanceColors),
            name: Appearance.didChange,
            object: nil
        )
        // Match the on-disk collapsed flag without animating — the window
        // already opened at the right height so this is just sizing the
        // scroll view side of things.
        if state.collapsed { applyCollapse(true, animated: false) }
        dragZone.reportsSingleClick = state.collapsed
    }

    private static func makeChromeButton(symbol: String, tooltip: String) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = Appearance.chromeInk
        button.toolTip = tooltip
        return button
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        fileWatcher?.stop()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Layout

    private func setupLayout() {
        guard let window = self.window else { return }
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(backgroundView)
        backgroundView.addSubview(dragZone)
        backgroundView.addSubview(dateLabel)
        backgroundView.addSubview(closeButton)
        backgroundView.addSubview(collapseButton)
        backgroundView.addSubview(scrollView)

        window.contentView = content
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: content.topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            dragZone.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
            dragZone.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
            dragZone.topAnchor.constraint(equalTo: backgroundView.topAnchor),
            dragZone.heightAnchor.constraint(equalToConstant: DailyNoteWindowController.chromeHeight),

            dateLabel.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 30),
            dateLabel.trailingAnchor.constraint(equalTo: collapseButton.leadingAnchor, constant: -8),
            dateLabel.topAnchor.constraint(equalTo: dragZone.topAnchor),
            dateLabel.bottomAnchor.constraint(equalTo: dragZone.bottomAnchor),

            closeButton.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: dragZone.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 13),
            closeButton.heightAnchor.constraint(equalToConstant: 13),

            collapseButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            collapseButton.centerYAnchor.constraint(equalTo: dragZone.centerYAnchor),
            collapseButton.widthAnchor.constraint(equalToConstant: 13),
            collapseButton.heightAnchor.constraint(equalToConstant: 13),

            scrollView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: dragZone.bottomAnchor, constant: 2),
            scrollView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -8)
        ])
    }

    // MARK: - Showing the document

    /// Draw what the document holds. While today's file cannot be read the text
    /// is a placeholder, and the view is read-only so nothing typed into it can
    /// be lost when the file arrives.
    private func showDocument() {
        dateLabel.text = "Daily Note · " + DailyNote.shortDate(dailyDocument.day)
        textView.isEditable = !dailyDocument.isUnavailable
        let text = dailyDocument.isUnavailable ? DailyNoteWindowController.placeholder : dailyDocument.body
        guard textView.string != text else { return }
        editor.replaceText(text)
    }

    @objc private func applyAppearanceColors() {
        backgroundView.layer?.backgroundColor = NSColor(hex: state.color.bodyHex)?.cgColor
        dateLabel.textColor = Appearance.chromeInk
        for button in [closeButton, collapseButton] {
            button.contentTintColor = Appearance.chromeInk
        }
        editor.applyColors()
    }

    /// Write any debounced edit immediately, so quitting mid-sentence doesn't
    /// drop it. False when the text did not reach disk.
    @discardableResult
    func flushPendingSave() -> Bool {
        dailyDocument.flush()
    }

    // MARK: - Watching

    private func startWatching() {
        fileWatcher?.stop()
        guard let url = dailyDocument.url else { return }
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let watcher = FileWatcher(
            accepts: DailyNote.watchFilter(for: url), confirmsOwnWrite: { OwnWriteLog.shared.confirms($0) }
        ) { [weak self] events in
            guard let self else { return }
            // A change of attributes alone is iCloud touching the file after a write, or
            // flagging a conflict: that is looked at without reading the file.
            if events.everything || !events.changed.isEmpty {
                self.dailyDocument.storeDidChange()
            } else {
                self.dailyDocument.attributesDidChange()
            }
        }
        watcher.watch([parent])
        fileWatcher = watcher
    }

    // MARK: - State persistence

    private func persistChrome() {
        guard let frame = window?.frame else { return }
        state.positionX = Double(frame.origin.x)
        state.positionY = Double(frame.origin.y)
        state.width = Double(frame.size.width)
        state.height = Double(frame.size.height)
        DailyNote.saveState(state, settings: settings)
    }

    private func persistVisibility(_ visible: Bool) {
        state.visible = visible
        DailyNote.saveState(state, settings: settings)
    }

    func setColor(_ color: NoteColor) {
        state.color = color
        backgroundView.layer?.backgroundColor = NSColor(hex: color.bodyHex)?.cgColor
        DailyNote.saveState(state, settings: settings)
    }

    /// Re-resolve the URL when the user changes the pattern at runtime.
    func patternDidChange() {
        dailyDocument.patternDidChange()
    }

    /// Re-seed today's note from the template if the file is currently
    /// empty. Called when the template path setting changes — covers the
    /// "I just configured a template, please apply it to today" case.
    func templateDidChange() {
        dailyDocument.templateDidChange()
    }

    // MARK: - Show / hide

    /// - Parameter userInitiated: true when the user asked for today's note
    ///   (menu bar, hotkey, the notes panel). Choosing to open it is a
    ///   deliberate enough act to create the file, so it shows up in Obsidian
    ///   whether or not they end up typing. Pass false for the launch-time
    ///   restore: that isn't a fresh choice, and it runs unattended on every
    ///   Mac, which is the shape of thing that collides.
    func show(userInitiated: Bool = true) {
        // Re-resolve in case the day rolled over while hidden (the
        // belt-and-suspenders companion to the midnight timer and wake
        // observer — covers a reopen that races ahead of either).
        dailyDocument.rolloverIfNeeded(now: clock.now())
        if userInitiated { dailyDocument.createTodaysFileIfMissing() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        persistVisibility(true)
    }

    /// Write today's note out if it isn't on disk yet. See
    /// `DailyDocument.createTodaysFileIfMissing`.
    func createTodaysFileIfMissing() {
        dailyDocument.createTodaysFileIfMissing()
    }

    // MARK: - Collapse / expand

    @objc private func toggleCollapse() {
        let target = !state.collapsed
        if target {
            // Capture the live expanded height so a later expand restores it.
            if let frame = window?.frame {
                preCollapseHeight = frame.size.height
                state.height = Double(frame.size.height)
            }
        }
        state.collapsed = target
        dragZone.reportsSingleClick = target
        applyCollapse(target, animated: true)
        DailyNote.saveState(state, settings: settings)
    }

    /// Re-apply styling after the shared text size changes.
    func restyleForTextSize() {
        editor.applyTextSize()
    }

    func dragZoneDidClick() {
        guard DailyNote.loadState(settings: settings).collapsed else { return }
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
        if snapped != window.frame { window.setFrameOrigin(snapped.origin) }
    }

    func dragZoneDidDoubleClick() { toggleCollapse() }

    /// The size the Arrange command lays this window out with: the window's own.
    var arrangementSize: NSSize { window?.frame.size ?? .zero }

    /// Move the window to `frame` for the Arrange command. The move is saved
    /// like a drag.
    func setArrangedFrame(_ frame: NSRect, animated: Bool = true) {
        window?.setFrame(frame, display: true, animate: animated)
    }

    private func applyCollapse(_ collapsed: Bool, animated: Bool) {
        guard let window = window else { return }
        scrollView.isHidden = collapsed
        backgroundView.layer?.cornerRadius = collapsed ? 5 : 12

        let chevronSymbol = collapsed ? "chevron.down" : "chevron.up"
        if let image = NSImage(systemSymbolName: chevronSymbol, accessibilityDescription: "Collapse / expand")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) {
            image.isTemplate = true
            collapseButton.image = image
        }

        var frame = window.frame
        let target: CGFloat = collapsed
            ? DailyNoteWindowController.collapsedTotalHeight
            : preCollapseHeight
        // Keep the top edge anchored so a collapse pulls the bottom up
        // rather than the title sliding off-screen.
        frame.origin.y += frame.size.height - target
        frame.size.height = target
        if animated {
            window.animator().setFrame(frame, display: true)
        } else {
            window.setFrame(frame, display: true)
        }
    }

    /// Hide and remember it, so neither the next store change nor the next
    /// launch brings the note back.
    func hide() {
        // Flush before disappearing so an immediate reopen sees fresh content.
        flushPendingSave()
        window?.orderOut(nil)
        persistVisibility(false)
    }

    @objc private func hideNote() {
        hide()
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) { persistChrome() }
    func windowDidResize(_ notification: Notification) {
        if state.collapsed {
            // Don't overwrite `state.height` (the expanded height) with the
            // collapsed strip's height — only persist position changes.
            guard let frame = window?.frame else { return }
            state.positionX = Double(frame.origin.x)
            state.positionY = Double(frame.origin.y)
            state.width = Double(frame.size.width)
            DailyNote.saveState(state, settings: settings)
        } else {
            persistChrome()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        dailyDocument.blur()
    }
}
