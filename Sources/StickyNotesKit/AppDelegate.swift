import AppKit
import KeyboardShortcuts

public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SettingsCoordinator {
    public override init() { super.init() }

    private var statusItem: NSStatusItem!
    private let noteStore = NoteStore()
    private var windowControllers: [UUID: NoteWindowController] = [:]
    private var notesPanelController: NotesPanelController?
    private var notesHidden = false
    private var hideAllItem: NSMenuItem!
    private var dailyNoteItem: NSMenuItem!
    private var storageWarningItem: NSMenuItem!
    private var permissionWarningItem: NSMenuItem!
    private var showLabelsItem: NSMenuItem!
    private var dailyNoteController: DailyNoteWindowController?
    private var settingsController: SettingsWindowController?
    private var quickSwitcher: QuickSwitcherController?
    /// Anchor for the new-note cascade. Reset when the last note is closed so
    /// a fresh desk starts from the top again.
    private var lastNewNoteFrame: NSRect?
    private let toasts = ToastController()

    private lazy var prefetcher = ICloudPrefetcher { [weak self] in
        // Manual nudge in case FSEvents missed the materialization.
        self?.handleStoreChange()
    }

    /// URL handling has to be registered before launch finishes, or a URL that
    /// launched the app is delivered before anyone is listening.
    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        NSApp.servicesProvider = self
        Appearance.startObserving()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        setupMenuBar()
        registerHotkeys()
        restoreActiveNotes()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStoreChange),
            name: NoteStore.didChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshStorageHealth),
            name: NoteStore.healthDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWikiLinkClick(_:)),
            name: TodoTextView.didClickWikiLink,
            object: nil
        )

        prefetcher.start(at: noteStore.rootURL)
        restoreDailyNoteIfNeeded()

        // A first launch showing an empty screen looks like a failed one.
        if let welcome = WelcomeNote.makeIfNeeded(
            store: noteStore,
            needsAccessibilityPermission: !HotkeyAdvice.hasAccessibilityPermission
        ) {
            presentWindow(for: welcome)
        }
    }

    private func restoreDailyNoteIfNeeded() {
        guard Settings.shared.obsidianVaultPath != nil,
              Settings.shared.dailyNotesPattern != nil else { return }
        let state = DailyNote.loadState()
        guard state.visible else { return }
        if dailyNoteController == nil {
            dailyNoteController = DailyNoteWindowController()
        }
        dailyNoteController?.show()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Bring open windows in line with what's on disk. Triggered by
    /// `NoteStore.didChange`, which fires both for our own writes (no-op here)
    /// and for external file changes — Obsidian edits, files arriving via
    /// iCloud Drive, archives created on another Mac, etc.
    @objc private func handleStoreChange() {
        DispatchQueue.main.async { [weak self] in
            self?.reconcileOpenWindows()
        }
    }

    private func reconcileOpenWindows() {
        let active = noteStore.loadActive()
        let activeIds = Set(active.map { $0.id })

        // Close windows whose underlying note is no longer active (archived
        // or deleted on another machine). Cancel pending debounced saves so
        // an in-flight save can't resurrect a file that was just deleted.
        for id in Array(windowControllers.keys) where !activeIds.contains(id) {
            if let controller = windowControllers.removeValue(forKey: id) {
                controller.closeAfterExternalDeletion()
            }
        }

        // Open windows for active notes that aren't visible yet (created on
        // another machine and synced in).
        for note in active where windowControllers[note.id] == nil {
            presentWindow(for: note, activate: false)
        }

        // Also catches label edits, which change whether a note belongs on
        // screen without changing whether its window exists.
        applyVisibility()
    }

    /// Even though we're an accessory (no Dock icon, no system menu bar),
    /// installing a main menu lets standard key equivalents like ⌘C / ⌘V /
    /// ⌘X / ⌘A / ⌘Z reach the focused text view via `performKeyEquivalent`.
    /// It also gives us a home for ⌘, → Settings.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…",
                        action: #selector(openSettings),
                        keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sticky Notes",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(undoLastAction(_:)), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        let pastePlainItem = editMenu.addItem(
            withTitle: "Paste and Match Style",
            action: Selector(("pasteAsPlainText:")),
            keyEquivalent: "V"
        )
        pastePlainItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Text size follows the platform convention rather than hiding in
        // Settings — it is the shortcut people already know.
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Bigger Text", action: #selector(increaseTextSize), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Smaller Text", action: #selector(decreaseTextSize), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(resetTextSize), keyEquivalent: "0")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            applyNormalMenuBarIcon(to: button)
        }

        let menu = NSMenu()
        menu.delegate = self

        let versionItem = NSMenuItem(
            title: "Sticky Notes \(AppDelegate.appVersionString)",
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        // Hidden unless a write has actually failed; see refreshStorageHealth.
        storageWarningItem = NSMenuItem(title: "",
                                        action: #selector(showStorageFailure),
                                        keyEquivalent: "")
        storageWarningItem.isHidden = true
        menu.addItem(storageWarningItem)

        // Shown only while hotkeys can't actually be registered.
        permissionWarningItem = NSMenuItem(title: HotkeyAdvice.permissionMenuTitle,
                                           action: #selector(openAccessibilitySettings),
                                           keyEquivalent: "")
        permissionWarningItem.isHidden = true
        menu.addItem(permissionWarningItem)

        menu.addItem(.separator())

        // Capture first — the things you actually do. Everything that
        // manages notes rather than making them goes in one submenu, which
        // keeps the top level at a glanceable seven rows.
        menu.addItem(withTitle: "New Note  ⌘⇧S", action: #selector(newNote), keyEquivalent: "")
        menu.addItem(withTitle: "New from Clipboard  ⌥⌘⇧V",
                     action: #selector(newNoteFromClipboard),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Find Note…  ⌘⇧F", action: #selector(toggleQuickSwitcher), keyEquivalent: "")

        dailyNoteItem = NSMenuItem(title: "Today's Daily Note",
                                   action: #selector(toggleDailyNote),
                                   keyEquivalent: "")
        menu.addItem(dailyNoteItem)

        menu.addItem(.separator())

        let notesItem = NSMenuItem(title: "Notes", action: nil, keyEquivalent: "")
        let notesMenu = NSMenu(title: "Notes")
        notesMenu.addItem(withTitle: "All Notes…  ⌘⇧L",
                          action: #selector(showNotesPanel),
                          keyEquivalent: "").target = self

        hideAllItem = NSMenuItem(title: "Hide All Notes  ⌘⇧H",
                                 action: #selector(toggleHideAll),
                                 keyEquivalent: "")
        hideAllItem.target = self
        notesMenu.addItem(hideAllItem)

        showLabelsItem = NSMenuItem(title: "Show Labels", action: nil, keyEquivalent: "")
        notesMenu.addItem(showLabelsItem)

        let arrangeItem = NSMenuItem(title: "Arrange", action: nil, keyEquivalent: "")
        let arrangeMenu = NSMenu()
        let gridItem = NSMenuItem(title: "Grid", action: #selector(arrangeGrid), keyEquivalent: "")
        gridItem.target = self
        arrangeMenu.addItem(gridItem)
        let cascadeItem = NSMenuItem(title: "Cascade", action: #selector(arrangeCascade), keyEquivalent: "")
        cascadeItem.target = self
        arrangeMenu.addItem(cascadeItem)
        arrangeItem.submenu = arrangeMenu
        notesMenu.addItem(arrangeItem)

        notesItem.submenu = notesMenu
        menu.addItem(notesItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…  ⌘,", action: #selector(openSettings), keyEquivalent: "")
        menu.addItem(withTitle: "Show Storage Folder", action: #selector(revealStorage), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
    }

    /// Version stamped into Info.plist by `scripts/build-app.sh`. Falls back
    /// to "dev" when running from `swift run` (no bundle = no Info.plist).
    private static var appVersionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        if let raw = info["CFBundleShortVersionString"] as? String,
           !raw.isEmpty,
           raw != "__APP_VERSION__" {
            return "v\(raw)"
        }
        return "dev"
    }

    public func menuWillOpen(_ menu: NSMenu) {
        hideAllItem.title = (notesHidden ? "Show All Notes  ⌘⇧H" : "Hide All Notes  ⌘⇧H")
        hideAllItem.isEnabled = !windowControllers.isEmpty

        // Rebuilt on open so newly added labels appear without a relaunch.
        showLabelsItem.submenu = makeLabelVisibilityMenu()
        let hiddenCount = Settings.shared.hiddenLabels.count
        showLabelsItem.title = hiddenCount == 0 ? "Show Labels" : "Show Labels  (\(hiddenCount) hidden)"

        // Re-checked on every open: the user may have just granted it, and
        // the warning should disappear without a relaunch.
        permissionWarningItem.isHidden = HotkeyAdvice.hasAccessibilityPermission

        let canShowDaily = Settings.shared.obsidianVaultPath != nil
            && Settings.shared.dailyNotesPattern != nil
        dailyNoteItem.isHidden = !canShowDaily
        if canShowDaily {
            let visible = dailyNoteController?.window?.isVisible ?? false
            dailyNoteItem.title = visible ? "Hide Today's Daily Note" : "Show Today's Daily Note"
        }
    }

    private func registerHotkeys() {
        KeyboardShortcuts.onKeyDown(for: .newNote) { [weak self] in
            self?.newNote()
        }
        KeyboardShortcuts.onKeyDown(for: .notesPanel) { [weak self] in
            self?.showNotesPanel()
        }
        KeyboardShortcuts.onKeyDown(for: .hideAll) { [weak self] in
            self?.toggleHideAll()
        }
        KeyboardShortcuts.onKeyDown(for: .quickSwitcher) { [weak self] in
            self?.toggleQuickSwitcher()
        }
        KeyboardShortcuts.onKeyDown(for: .newFromClipboard) { [weak self] in
            self?.newNoteFromClipboard()
        }
    }

    /// Pressing the hotkey again while the palette is up closes it, so the
    /// same chord opens and dismisses.
    @objc func toggleQuickSwitcher() {
        if quickSwitcher?.isVisible == true {
            quickSwitcher?.dismiss()
            return
        }
        if quickSwitcher == nil {
            quickSwitcher = QuickSwitcherController(store: noteStore) { [weak self] outcome in
                self?.handle(outcome)
            }
        }
        quickSwitcher?.show()
    }

    /// Act on a quick-switcher result. Picking one should always end with a
    /// note on screen — un-hiding, un-archiving, or creating as needed.
    private func handle(_ outcome: QuickSwitcherController.Outcome) {
        switch outcome {
        case let .open(id, wasArchived):
            if wasArchived, let note = noteStore.loadNote(id: id, archived: true) {
                noteStore.restore(note)
            }
            if notesHidden { toggleHideAll() }
            focusNote(id: id)

        case let .create(title):
            // Searching for a note that isn't there is a capture intent —
            // keep the typed words as the title and start in the body.
            makeNote(title: title)
        }
    }

    @objc func toggleHideAll() {
        let dailyVisible = dailyNoteController?.window?.isVisible ?? false
        guard !windowControllers.isEmpty || dailyVisible else { return }

        let wasVisible = windowControllers.values.filter { $0.window?.isVisible == true }.count
        notesHidden.toggle()
        applyVisibility()

        if notesHidden {
            offerUndoForHiding(count: wasVisible, label: nil) { [weak self] in
                guard let self = self, self.notesHidden else { return }
                self.notesHidden = false
                self.applyVisibility()
            }
        } else {
            toasts.dismiss()
        }
    }

    /// Single place that decides which note windows are on screen. "Hide all"
    /// wins over everything; otherwise a note is off screen when one of its
    /// labels is hidden.
    /// Only acts on windows whose state actually needs to change. This runs on
    /// every store change, including the debounced save behind each keystroke —
    /// ordering already-visible windows to the front would make notes jump
    /// above other apps while you type.
    private func applyVisibility() {
        let hiddenLabels = Settings.shared.hiddenLabels
        for controller in windowControllers.values {
            let shouldHide = notesHidden || hiddenLabels.contains(where: controller.labels.contains)
            setVisible(controller.window, !shouldHide)
        }

        // The daily note has no labels; only "hide all" applies to it, and
        // its own state.visible flag decides whether it should come back.
        setVisible(dailyNoteController?.window, !notesHidden && DailyNote.loadState().visible)
    }

    private func setVisible(_ window: NSWindow?, _ visible: Bool) {
        guard let window = window, window.isVisible != visible else { return }
        if visible { window.orderFront(nil) } else { window.orderOut(nil) }
    }

    @objc private func arrangeGrid() { arrange(using: WindowArrangement.grid(sizes:in:gap:)) }
    @objc private func arrangeCascade() { arrange(using: WindowArrangement.cascade(sizes:in:step:)) }

    /// Lay every visible note out on the screen the pointer is on. Notes keep
    /// their own sizes; only positions move.
    private func arrange(using layout: ([CGSize], CGRect, CGFloat) -> [CGRect]) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let controllers = windowControllers.values
            .filter { $0.window?.isVisible == true }
            // Left-to-right, top-to-bottom, so an arrange broadly preserves
            // where things already were rather than shuffling them.
            .sorted { a, b in
                let fa = a.window?.frame ?? .zero, fb = b.window?.frame ?? .zero
                if fa.minY != fb.minY { return fa.minY > fb.minY }
                return fa.minX < fb.minX
            }
        guard !controllers.isEmpty else { return }

        let frames = layout(controllers.map(\.arrangementSize), visible, 12)
        for (controller, frame) in zip(controllers, frames) {
            controller.setArrangedFrame(frame)
        }
    }

    private func makeLabelVisibilityMenu() -> NSMenu {
        let menu = NSMenu(title: "Show Labels")
        let labels = noteStore.allLabels()
        guard !labels.isEmpty else {
            let empty = NSMenuItem(title: "No labels yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        let hidden = Settings.shared.hiddenLabels
        for label in labels {
            let item = NSMenuItem(title: "#\(label)",
                                  action: #selector(toggleLabelVisibility(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = label
            item.state = hidden.contains(label) ? .off : .on
            menu.addItem(item)
        }

        if !hidden.isEmpty {
            menu.addItem(.separator())
            let showAll = NSMenuItem(title: "Show All Labels",
                                     action: #selector(showAllLabels),
                                     keyEquivalent: "")
            showAll.target = self
            menu.addItem(showAll)
        }
        return menu
    }

    @objc private func toggleLabelVisibility(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String else { return }
        var hidden = Settings.shared.hiddenLabels
        let hiding = !hidden.contains(label)

        let affected = windowControllers.values.filter {
            $0.labels.contains(label) && $0.window?.isVisible == true
        }.count

        if hiding { hidden.insert(label) } else { hidden.remove(label) }
        Settings.shared.hiddenLabels = hidden
        applyVisibility()

        guard hiding else { toasts.dismiss(); return }
        offerUndoForHiding(count: affected, label: label) { [weak self] in
            guard let self = self else { return }
            var current = Settings.shared.hiddenLabels
            current.remove(label)
            Settings.shared.hiddenLabels = current
            self.applyVisibility()
        }
    }

    @objc private func showAllLabels() {
        Settings.shared.hiddenLabels = []
        applyVisibility()
    }

    private func restoreActiveNotes() {
        for note in noteStore.loadActive() {
            presentWindow(for: note)
        }
        // Labels hidden in a previous session stay hidden across a relaunch.
        applyVisibility()
    }

    /// Pressing the chord again while an untouched new note is focused means
    /// "never mind" — the same toggle the quick switcher has.
    @objc func newNote() {
        if let focused = focusedController(), focused.isAbandonedCapture {
            focused.discardAbandonedCapture()
            return
        }
        makeNote()
    }

    private func focusedController() -> NoteWindowController? {
        windowControllers.values.first { $0.window?.isKeyWindow == true }
    }

    /// Create, save, and present a note. Everything that captures a note —
    /// the hotkey, the clipboard, a Service, a URL — comes through here.
    @discardableResult
    private func makeNote(
        title: String? = nil,
        text: String = "",
        color: NoteColor? = nil,
        labels: [String] = []
    ) -> UUID {
        // Creating a new note while everything is hidden should bring all
        // notes back so the new one isn't the only thing visible.
        if notesHidden { toggleHideAll() }

        var note = Note.makeNew(frame: nextNoteFrame())
        if let title = title { note.title = title }
        if let color = color { note.color = color }
        note.content = text
        note.labels = labels
        noteStore.save(note)
        presentWindow(for: note)

        // An empty note starts in the title — that's where the user should be
        // naming the thing. One that arrived with text starts in the body,
        // after what's already there.
        if text.isEmpty {
            windowControllers[note.id]?.focusTitle()
        } else {
            windowControllers[note.id]?.focusBodyEnd()
        }
        return note.id
    }

    /// Frame for the next new note: cascading from the last one created this
    /// session, on whichever screen the pointer is on.
    private func nextNoteFrame() -> NSRect {
        let screen = NotePlacement.screenUnderPointer(
            mouse: NSEvent.mouseLocation,
            screens: NSScreen.screens.map(\.visibleFrame),
            main: NSScreen.main?.visibleFrame
        ) ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let frame = NotePlacement.next(previous: lastNewNoteFrame, screen: screen)
        lastNewNoteFrame = frame
        return frame
    }

    /// New note pre-filled from the clipboard. Pasted images and files are
    /// saved as attachments the same way an in-editor paste would.
    @objc func newNoteFromClipboard() {
        let pasteboard = NSPasteboard.general
        if let markdown = Attachments.handlePaste(pasteboard, for: noteStore) {
            makeNote(text: markdown)
            return
        }
        let text = pasteboard.string(forType: .string) ?? ""
        makeNote(text: text)
    }

    // MARK: - Services

    /// Wired up by the `NSServices` entry in Info.plist, so any app's
    /// right-click menu can send a selection straight into a new note.
    @objc func makeNoteFromService(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            error?.pointee = "No text was selected." as NSString
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        makeNote(text: text)
    }

    // MARK: - URL scheme

    /// Handles `stickynotes://` URLs. Registered in
    /// `applicationWillFinishLaunching`, which is early enough to catch a URL
    /// that launched the app.
    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string),
              let command = CaptureCommand.parse(url) else { return }
        perform(command)
    }

    func perform(_ command: CaptureCommand) {
        switch command {
        case let .new(title, text, color, labels):
            NSApp.activate(ignoringOtherApps: true)
            makeNote(title: title, text: text, color: color, labels: labels)

        case let .search(query):
            if quickSwitcher == nil {
                quickSwitcher = QuickSwitcherController(store: noteStore) { [weak self] outcome in
                    self?.handle(outcome)
                }
            }
            quickSwitcher?.show()
            if !query.isEmpty { quickSwitcher?.search(query) }

        case .daily:
            NSApp.activate(ignoringOtherApps: true)
            openTodaysDailyNote()
        }
    }

    @objc func showNotesPanel() {
        if notesPanelController == nil {
            notesPanelController = NotesPanelController(store: noteStore, onActivate: { [weak self] id in
                self?.focusNote(id: id)
            })
        } else {
            notesPanelController?.reload()
        }
        notesPanelController?.showWindow(nil)
        notesPanelController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func focusNote(id: UUID) {
        if let controller = windowControllers[id] {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Fallback: load from disk and present (e.g. file appeared via iCloud sync).
        if let note = noteStore.loadActive().first(where: { $0.id == id }) {
            presentWindow(for: note)
        }
    }

    @objc func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(coordinator: self)
        }
        settingsController?.show()
    }

    @objc func toggleDailyNote() {
        guard Settings.shared.obsidianVaultPath != nil,
              Settings.shared.dailyNotesPattern != nil else { return }
        if let controller = dailyNoteController, controller.window?.isVisible == true {
            controller.window?.orderOut(nil)
            return
        }
        if dailyNoteController == nil {
            dailyNoteController = DailyNoteWindowController()
        }
        dailyNoteController?.show()
    }

    @objc func revealStorage() {
        NSWorkspace.shared.activateFileViewerSelecting([noteStore.activeURL])
    }

    /// A `[[wiki link]]` points at one of our notes when a title matches;
    /// otherwise it's probably a note elsewhere in the vault, so hand it to
    /// Obsidian rather than doing nothing.
    @objc private func handleWikiLinkClick(_ notification: Notification) {
        guard let target = notification.userInfo?["target"] as? String else { return }

        if let match = WikiLink.resolve(target, in: noteStore.loadActive()) {
            focusNote(id: match.id)
            return
        }
        if let archived = WikiLink.resolve(target, in: noteStore.loadArchived()) {
            noteStore.restore(archived)
            focusNote(id: archived.id)
            return
        }
        if let vault = Settings.shared.obsidianVaultPath,
           let url = WikiLink.obsidianURL(vaultPath: vault, target: target) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAccessibilitySettings() {
        guard let url = HotkeyAdvice.accessibilitySettingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Text size

    @objc func increaseTextSize() { adjustTextSize(by: 1) }
    @objc func decreaseTextSize() { adjustTextSize(by: -1) }
    @objc func resetTextSize() { applyTextSize(Settings.defaultBodyFontSize) }

    private func adjustTextSize(by delta: CGFloat) {
        applyTextSize(Settings.shared.bodyFontSize + delta)
    }

    /// One size for every note — a per-note size would be a setting nobody
    /// asked for and a lot of state to keep straight.
    private func applyTextSize(_ size: CGFloat) {
        let clamped = Settings.clampFontSize(size)
        guard clamped != Settings.shared.bodyFontSize else { return }
        Settings.shared.bodyFontSize = clamped
        for controller in windowControllers.values {
            controller.applyAppearanceColors()
        }
        dailyNoteController?.restyleForTextSize()
    }

    // MARK: - Undo

    /// Archiving makes a note vanish with no recourse short of opening the
    /// panel and hunting for it. Offer to put it back.
    private func offerUndoForArchive(of note: Note) {
        toasts.show(Toast(message: Toast.archivedMessage(noteName: NoteSearch.summary(of: note))) { [weak self] in
            guard let self = self else { return }
            self.noteStore.restore(note)
            self.focusNote(id: note.id)
        })
    }

    /// Hiding notes looks identical to them crashing. Same treatment.
    private func offerUndoForHiding(count: Int, label: String?, restore: @escaping () -> Void) {
        guard count > 0 else { return }
        toasts.show(Toast(
            message: Toast.hiddenMessage(count: count, label: label),
            undoTitle: "Show",
            undo: restore
        ))
    }

    /// ⌘Z with a toast on screen undoes that action. Routed through the main
    /// menu so it works no matter which of our windows has focus.
    @objc func undoLastAction(_ sender: Any?) {
        if toasts.performUndo() { return }
        // Nothing pending — let the focused text view handle its own undo.
        NSApp.sendAction(Selector(("undo:")), to: nil, from: sender)
    }

    // MARK: - Storage health

    /// Swap the menu-bar icon for a warning and expose the failing file while
    /// notes aren't reaching disk. A silently failed save looks identical to a
    /// successful one, so this is the only signal the user gets.
    @objc private func refreshStorageHealth() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem?.button else { return }
            if let failure = self.noteStore.lastFailure {
                button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                       accessibilityDescription: "Sticky Notes — can't save")
                button.image?.isTemplate = true
                button.toolTip = "Sticky Notes can't save to \(failure.fileName)"
                self.storageWarningItem.title = "⚠︎ Couldn't save \(failure.fileName)"
                self.storageWarningItem.isHidden = false
            } else {
                self.applyNormalMenuBarIcon(to: button)
                button.toolTip = nil
                self.storageWarningItem.isHidden = true
            }
        }
    }

    /// Custom template image renders as the sticky-note silhouette and gets
    /// tinted automatically by the system (light/dark/click).
    private func applyNormalMenuBarIcon(to button: NSStatusBarButton) {
        if let icon = NSImage(named: "MenuBarIcon") {
            icon.isTemplate = true
            button.image = icon
        } else {
            button.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Sticky Notes")
        }
    }

    @objc private func showStorageFailure() {
        guard let failure = noteStore.lastFailure else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't save \(failure.fileName)"
        alert.informativeText = """
        \(failure.error.localizedDescription)

        The note is still open and its text is safe — it just isn't on disk \
        yet. Sticky Notes keeps retrying as you edit. Check that the storage \
        folder exists and the disk isn't full.

        Location: \(failure.url.deletingLastPathComponent().path)
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Show Storage Folder")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            revealStorage()
        }
    }

    // MARK: - SettingsCoordinator

    func applyStorageMode(_ mode: SettingsWindowController.StorageMode) {
        let previousVault = Settings.shared.obsidianVaultPath

        let newRoot: URL
        let format: StorageFormat
        switch mode {
        case .local:
            Settings.shared.obsidianVaultPath = nil
            Settings.shared.useICloud = false
            newRoot = Settings.localRootURL.appendingPathComponent("StickyNotes", isDirectory: true)
            format = .json
        case .iCloud:
            Settings.shared.obsidianVaultPath = nil
            guard Settings.iCloudAvailable, let icloud = Settings.iCloudRootURL else {
                // Caller's UI should disable this, but stay safe.
                Settings.shared.useICloud = false
                newRoot = Settings.localRootURL.appendingPathComponent("StickyNotes", isDirectory: true)
                format = .json
                break
            }
            Settings.shared.useICloud = true
            newRoot = icloud.appendingPathComponent("StickyNotes", isDirectory: true)
            format = .json
        case .vault(let path):
            Settings.shared.obsidianVaultPath = path
            newRoot = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("StickyNotes", isDirectory: true)
            format = .markdown
        }

        noteStore.reconfigure(rootURL: newRoot, format: format)
        prefetcher.start(at: noteStore.rootURL)

        // Daily note feature requires a vault — tear down its window when
        // we leave vault mode.
        let nowVault = Settings.shared.obsidianVaultPath != nil
        if previousVault != nil && !nowVault {
            dailyNoteController?.window?.orderOut(nil)
            dailyNoteController = nil
        } else if nowVault {
            dailyNoteController?.patternDidChange()
        }
    }

    func applyDailyPattern(_ pattern: String?) {
        Settings.shared.dailyNotesPattern = pattern
        if pattern == nil {
            dailyNoteController?.window?.orderOut(nil)
            dailyNoteController = nil
        } else {
            dailyNoteController?.patternDidChange()
        }
    }

    func applyDailyTemplate(_ path: String?) {
        Settings.shared.dailyTemplatePath = path
        dailyNoteController?.templateDidChange()
    }

    func revealStorageFolder() {
        revealStorage()
    }

    func openTodaysDailyNote() {
        toggleDailyNote()
        // toggleDailyNote toggles — if it was already visible we just hid it.
        // Make sure it ends up visible regardless.
        if dailyNoteController?.window?.isVisible != true {
            if dailyNoteController == nil {
                dailyNoteController = DailyNoteWindowController()
            }
            dailyNoteController?.show()
        }
    }

    private func presentWindow(for note: Note, activate: Bool = true) {
        if let existing = windowControllers[note.id] {
            existing.showWindow(nil)
            if activate {
                existing.window?.makeKeyAndOrderFront(nil)
            } else {
                existing.window?.orderFront(nil)
            }
            return
        }
        let controller = NoteWindowController(note: note, store: noteStore) { [weak self] id in
            self?.windowControllers.removeValue(forKey: id)
        }
        controller.onArchived = { [weak self] archived in
            self?.offerUndoForArchive(of: archived)
        }
        windowControllers[note.id] = controller
        controller.showWindow(nil)
        if activate {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Sync-induced presentation: float the window in without yanking
            // focus from whatever the user is doing.
            controller.window?.orderFront(nil)
        }
    }
}
