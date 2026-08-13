import AppKit

/// Singleton floating window pinned to today's Obsidian daily note. Reads
/// and writes the underlying `.md` as raw markdown — no frontmatter
/// injection — so Obsidian and other plugins remain authoritative for
/// formatting. Window chrome (position / size / color) is persisted to
/// `<vault>/StickyNotes/_daily.json` via `DailyNote.saveState`.
final class DailyNoteWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, TodoTextViewDelegate, NoteDragZoneDelegate {
    /// Only used to locate the attachments folder. The daily note itself is a
    /// vault file rather than a stored note, but its pasted images belong in
    /// the same place as everyone else's.
    private lazy var attachmentStore = NoteStore()


    private var state: DailyNoteState
    private var currentURL: URL?
    private var currentDay: Date  // start-of-day for the URL we're showing
    private var lastLoadedContent: String = ""

    private let dragZone: NoteDragZone
    private let dateLabel: CenteredTitleLabel
    private let closeButton: NSButton
    private let collapseButton: NSButton
    private let backgroundView: HoverTrackingView
    private let textView: TodoTextView
    private let textStorage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private let scrollView: NSScrollView

    private var saveWorkItem: DispatchWorkItem?
    private var fileWatcher: FileWatcher?
    private var midnightTimer: Timer?
    private var pendingExternalContent: String?

    /// Height used when expanding back from a collapsed state. Captured at
    /// collapse time, since while collapsed the live window frame is just
    /// the chrome strip.
    private var preCollapseHeight: CGFloat

    private static let chromeHeight: CGFloat = 26
    private static let collapsedTotalHeight: CGFloat = 26
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        f.locale = Locale.autoupdatingCurrent
        return f
    }()

    init() {
        self.state = DailyNote.loadState()
        self.currentDay = Calendar.current.startOfDay(for: Date())
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
        dateLabel.textColor = NSColor.black.withAlphaComponent(0.55)
        dateLabel.placeholder = ""

        closeButton = DailyNoteWindowController.makeChromeButton(
            symbol: "xmark",
            tooltip: "Hide"
        )
        collapseButton = DailyNoteWindowController.makeChromeButton(
            symbol: state.collapsed ? "chevron.down" : "chevron.up",
            tooltip: "Collapse / expand"
        )

        textStorage = NSTextStorage()
        layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        container.lineFragmentPadding = TodoTextView.leadingPaddingForCheckbox
        layoutManager.addTextContainer(container)

        // NSScrollView's documentView relies on autoresizingMask, not Auto
        // Layout — leave `translatesAutoresizingMaskIntoConstraints` at its
        // default `true` and rely on `autoresizingMask` + min/maxSize so
        // the text view resizes with the scroll view's clip view. Setting
        // this to false (as an earlier draft did) leaves the text view
        // sized at zero so clicks never land on real text positions.
        textView = TodoTextView(frame: .zero, textContainer: container)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: MarkdownStyler.baseFontSize),
            .foregroundColor: MarkdownStyler.bodyTextColor
        ]
        textView.insertionPointColor = MarkdownStyler.bodyTextColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        super.init(window: window)
        window.delegate = self
        textView.delegate = self
        textView.todoDelegate = self
        textView.attachmentHandler = { [weak self] pasteboard in
            guard let self = self else { return nil }
            return Attachments.handlePaste(pasteboard, for: self.attachmentStore)
        }

        setupLayout()
        closeButton.target = self
        closeButton.action = #selector(hideNote)
        collapseButton.target = self
        collapseButton.action = #selector(toggleCollapse)
        dragZone.delegate = self

        loadCurrentFile()
        startWatching()
        scheduleMidnightRollover()
        observeWake()
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
        button.contentTintColor = NSColor.black.withAlphaComponent(0.55)
        button.toolTip = tooltip
        return button
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        midnightTimer?.invalidate()
        fileWatcher?.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
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

    // MARK: - File I/O

    /// Resolve today's URL, load its body into the text view, and refresh
    /// the date label. If the file doesn't exist yet and a template is
    /// configured, the rendered template seeds the body and is written to
    /// disk immediately — so Obsidian sees the same file the user is
    /// editing here, with the same template Obsidian itself would apply.
    private func loadCurrentFile() {
        currentDay = Calendar.current.startOfDay(for: Date())
        currentURL = DailyNote.resolvedURL(for: currentDay)
        dateLabel.text = "Daily Note · " + DailyNoteWindowController.dateFormatter.string(from: currentDay)

        guard let url = currentURL else {
            lastLoadedContent = ""
            applyExternalBody("")
            return
        }

        if let raw = try? String(contentsOf: url, encoding: .utf8) {
            lastLoadedContent = raw
            applyExternalBody(raw)
            return
        }

        // File doesn't exist yet. Seed from template if configured.
        if let templated = DailyNote.renderedTemplate(for: currentDay, fileURL: url) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? templated.write(to: url, atomically: true, encoding: .utf8)
            lastLoadedContent = templated
            applyExternalBody(templated)
        } else {
            lastLoadedContent = ""
            applyExternalBody("")
        }
    }

    /// Reload from disk if the underlying file changed externally.
    private func reloadIfExternallyChanged() {
        guard let url = currentURL else { return }
        let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if body == lastLoadedContent { return }

        if let win = window, win.isKeyWindow,
           win.firstResponder === textView {
            // Defer the merge until the user steps away — overwriting an
            // active edit would be jarring.
            pendingExternalContent = body
            return
        }
        lastLoadedContent = body
        applyExternalBody(body)
    }

    private func applyExternalBody(_ body: String) {
        let oldSelection = textView.selectedRange()
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.replaceCharacters(in: fullRange, with: body)
        MarkdownStyler.apply(to: textView)
        MarkdownStyler.updateMarkerVisibility(in: textStorage, selection: textView.selectedRange())
        let len = textStorage.length
        let clamped = NSRange(location: min(oldSelection.location, len), length: 0)
        textView.setSelectedRange(clamped)
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func saveNow() {
        guard let url = currentURL else { return }
        let body = textView.string
        if body == lastLoadedContent { return }

        // Make sure the parent folder exists — Obsidian creates it lazily;
        // we should too rather than failing the first write.
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            lastLoadedContent = body
        } catch {
            // Best-effort — the next debounce will retry.
        }
    }

    // MARK: - Watching

    private func startWatching() {
        fileWatcher?.stop()
        guard let url = currentURL else { return }
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let watcher = FileWatcher { [weak self] in
            self?.reloadIfExternallyChanged()
        }
        watcher.watch([parent])
        fileWatcher = watcher
    }

    // MARK: - Midnight rollover

    private func scheduleMidnightRollover() {
        midnightTimer?.invalidate()
        let calendar = Calendar.current
        guard let next = calendar.nextDate(
            after: Date(),
            matching: DateComponents(hour: 0, minute: 0, second: 1),
            matchingPolicy: .strict
        ) else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            self?.handleMidnight()
        }
        RunLoop.main.add(timer, forMode: .common)
        midnightTimer = timer
    }

    private func handleMidnight() {
        // Flush any pending edits to the old day's file before swapping.
        saveWorkItem?.cancel()
        saveWorkItem = nil
        saveNow()

        loadCurrentFile()
        startWatching()
        scheduleMidnightRollover()
    }

    /// Swap to today's note if the calendar day advanced since we last
    /// resolved the file. The midnight `Timer` doesn't fire while the Mac
    /// sleeps, so a machine that slept through midnight keeps showing the
    /// old day until something forces a re-resolve. Cheap no-op when the
    /// day is unchanged.
    private func rolloverIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date())
        guard today != currentDay else { return }
        handleMidnight()
    }

    private func observeWake() {
        // Waking is exactly when the missed-midnight case surfaces — roll
        // over immediately so an always-open window catches up without
        // waiting for the next reopen, and re-arm the timer (the prior one
        // may have fired late or been coalesced during sleep).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func handleWake() {
        rolloverIfNeeded()
        scheduleMidnightRollover()
    }

    // MARK: - State persistence

    private func persistChrome() {
        guard let frame = window?.frame else { return }
        state.positionX = Double(frame.origin.x)
        state.positionY = Double(frame.origin.y)
        state.width = Double(frame.size.width)
        state.height = Double(frame.size.height)
        DailyNote.saveState(state)
    }

    private func persistVisibility(_ visible: Bool) {
        state.visible = visible
        DailyNote.saveState(state)
    }

    func setColor(_ color: NoteColor) {
        state.color = color
        backgroundView.layer?.backgroundColor = NSColor(hex: color.bodyHex)?.cgColor
        DailyNote.saveState(state)
    }

    /// Re-resolve the URL when the user changes the pattern at runtime.
    func patternDidChange() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        saveNow()  // flush against the previous URL if it's still valid
        loadCurrentFile()
        startWatching()
    }

    /// Re-seed today's note from the template if the file is currently
    /// empty. Called when the template path setting changes — covers the
    /// "I just configured a template, please apply it to today" case.
    func templateDidChange() {
        guard let url = currentURL else { return }
        let body = textView.string
        let isEmpty = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard isEmpty else { return }

        if let templated = DailyNote.renderedTemplate(for: currentDay, fileURL: url) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? templated.write(to: url, atomically: true, encoding: .utf8)
            lastLoadedContent = templated
            applyExternalBody(templated)
        }
    }

    // MARK: - Show / hide

    func show() {
        // Re-resolve in case the day rolled over while hidden (the
        // belt-and-suspenders companion to the midnight timer and wake
        // observer — covers a reopen that races ahead of either).
        rolloverIfNeeded()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        persistVisibility(true)
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
        DailyNote.saveState(state)
    }

    /// Re-apply styling after the shared text size changes.
    func restyleForTextSize() {
        textView.font = NSFont.systemFont(ofSize: MarkdownStyler.baseFontSize)
        MarkdownStyler.apply(to: textView)
        MarkdownStyler.updateMarkerVisibility(in: textStorage, selection: textView.selectedRange())
    }

    func dragZoneDidClick() {
        guard DailyNote.loadState().collapsed else { return }
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

    @objc private func hideNote() {
        // Flush before disappearing so an immediate reopen sees fresh content.
        saveWorkItem?.cancel()
        saveWorkItem = nil
        saveNow()
        window?.orderOut(nil)
        persistVisibility(false)
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
            DailyNote.saveState(state)
        } else {
            persistChrome()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if pendingExternalContent != nil {
            pendingExternalContent = nil
            reloadIfExternallyChanged()
        }
    }

    // MARK: - Text editing

    func textDidChange(_ notification: Notification) {
        MarkdownStyler.apply(to: textView)
        MarkdownStyler.updateMarkerVisibility(in: textStorage, selection: textView.selectedRange())
        scheduleSave()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        MarkdownStyler.updateMarkerVisibility(in: textStorage, selection: textView.selectedRange())
    }

    // MARK: - TodoTextViewDelegate

    func textViewDidToggleCheckbox(at charIndex: Int) {
        // Locate the bracket between `[` and `]` on the same line and flip
        // its character. Mirrors the editing path used for regular notes.
        let nsString = textStorage.string as NSString
        let lineRange = nsString.lineRange(for: NSRange(location: charIndex, length: 0))
        let line = nsString.substring(with: lineRange)
        guard let openIdx = line.firstIndex(of: "["),
              let closeIdx = line.firstIndex(of: "]"),
              line.distance(from: openIdx, to: closeIdx) >= 2 else { return }
        let bracketCharIdx = line.index(after: openIdx)
        let absoluteCharIdx = lineRange.location + line.distance(from: line.startIndex, to: bracketCharIdx)
        let current = (line[bracketCharIdx])
        let replacement = (current == " ") ? "x" : " "
        let replaceRange = NSRange(location: absoluteCharIdx, length: 1)
        guard textView.shouldChangeText(in: replaceRange, replacementString: replacement) else { return }
        textStorage.replaceCharacters(in: replaceRange, with: replacement)
        textView.didChangeText()
        MarkdownStyler.apply(to: textView)
        MarkdownStyler.updateMarkerVisibility(in: textStorage, selection: textView.selectedRange())
        scheduleSave()
    }
}
