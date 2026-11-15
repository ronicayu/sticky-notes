import AppKit

/// What is on the desk: the note windows and the daily note window, which of
/// them are showing, where new ones go, and what happens to them when the store
/// changes underneath them. Capture, menus and storage settings all act on the
/// desk through this one object.
@MainActor final class DeskController: NSObject {
    private let store: NoteStore
    private let settings: Settings
    /// Where every note window sits on this Mac. Never synced.
    let layout: DeviceLayoutStore
    private let clock: AppClock
    private let undo: UndoCenter
    private let recovery: RecoveryFiles
    private let scheduler: Scheduler

    private(set) var windowControllers: [UUID: NoteWindowController] = [:]
    private(set) var notesHidden = false
    private var dailyNoteController: DailyNoteWindowController?
    private var notesPanelController: NotesPanelController?
    var notesPanel: NotesPanelController? { notesPanelController }
    private var quickSwitcher: QuickSwitcherController?
    /// Anchor for the new-note cascade. Reset when the last note is closed so
    /// a fresh desk starts from the top again.
    private var lastNewNoteFrame: NSRect?

    init(
        store: NoteStore, settings: Settings, clock: AppClock, undo: UndoCenter, recovery: RecoveryFiles,
        scheduler: Scheduler = MainScheduler(), layout: DeviceLayoutStore? = nil
    ) {
        self.scheduler = scheduler
        self.store = store
        self.settings = settings
        self.layout = layout ?? DeviceLayoutStore(url: settings.layoutURL, scheduler: scheduler)
        self.clock = clock
        self.undo = undo
        self.recovery = recovery
        super.init()
        MarkdownStyler.baseFontSize = settings.bodyFontSize
        // The store sweeps on the main queue. A window with unsaved text writes
        // it before its conflict versions are merged, so the merge has it.
        store.beforeResolvingConflicts = { [weak self] id in
            MainActor.assumeIsolated { self?.windowControllers[id]?.flushPendingSave() ?? true }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Listen for the Mac waking, store changes and wiki-link clicks. Kept apart
    /// from `init` so a test can build a desk that hears nothing.
    func startObserving() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeDidChange(_:)),
            name: NoteStore.didChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWikiLinkClick(_:)),
            name: TodoTextView.didClickWikiLink,
            object: nil
        )
    }

    /// Open a window for every active note. Labels hidden in a previous session
    /// stay hidden across a relaunch.
    func restoreActiveNotes() {
        for note in store.loadActive() {
            presentWindow(for: note)
        }
        applyVisibility()
    }

    /// A note brought back from the archive opens expanded, wherever this Mac last
    /// had it, and grows downward from where its bar was. A note this Mac has no
    /// layout for that an older build left collapsed gets an expanded one from the
    /// old keys; any other note is placed when its window opens.
    private func openExpanded(restored id: UUID) {
        let bar = NoteWindowController.collapsedHeight
        if layout.layout(for: id) != nil {
            layout.update(id) { entry in
                guard entry.collapsed else { return }
                entry.collapsed = false
                entry.y -= entry.height - Double(bar)
            }
        } else if let note = store.loadNote(id: id), let old = note.legacyPlacement, old.collapsed {
            layout.set(
                NoteLayout(x: old.x, y: old.y - (note.height - Double(bar)), width: note.width, height: note.height),
                for: id
            )
        }
    }

    /// Forget the layout of notes that exist nowhere: not in the notes, the
    /// archive or the trash. A note that may only be unreadable or not downloaded
    /// yet is kept. Run once at launch, so `layout.json` does not grow for ever.
    func pruneLayout() {
        guard let active = store.listActive() else { return }
        let known = Set((active + store.loadArchived() + store.loadTrashed()).map(\.id))
        layout.prune { id in
            if known.contains(id) { return true }
            if case .missing = store.whereIs(id: id) { return false }
            return true
        }
    }

    /// The Mac woke: the midnight timer does not fire in sleep, so a daily note
    /// left open across midnight is brought to today now.
    @objc func handleWake() {
        dailyNoteController?.dailyDocument.wakeDidHappen()
    }

    // MARK: - Windows

    var hasWindows: Bool { !windowControllers.isEmpty }

    func focusedController() -> NoteWindowController? {
        windowControllers.values.first { $0.window?.isKeyWindow == true }
    }

    func presentWindow(for note: Note, activate: Bool = true) {
        if let existing = windowControllers[note.id] {
            existing.showWindow(nil)
            if activate {
                existing.window?.makeKeyAndOrderFront(nil)
            } else {
                existing.window?.orderFront(nil)
            }
            return
        }
        let controller = NoteWindowController(
            note: note, store: store, layout: layout,
            placing: { [weak self] size in
                self?.nextNoteFrame(size: size) ?? NoteWindowController.placeOnPointerScreen(size: size)
            },
            clock: clock, scheduler: scheduler
        ) { [weak self] id in
            guard let self = self else { return }
            self.windowControllers.removeValue(forKey: id)
            // An emptied desk should start the cascade from the top again.
            if self.windowControllers.isEmpty { self.lastNewNoteFrame = nil }
        }
        controller.onArchived = { [weak self] archived in
            self?.offerUndoForArchive(of: archived)
        }
        controller.onTextKept = { [weak self] place in
            switch place {
            case .recoveredCopy: self?.undo.tellRecoveredCopy(in: "Trash")
            case .trash: self?.undo.tellDeletedElsewhere()
            case .archive: break
            }
        }
        controller.onCloseRefused = { [weak self, weak controller] retry in
            guard let self = self, let controller = controller else { return }
            // The note is gone and nothing can take its text: a retry would only
            // fail again, so the person's close takes the way out that reconcile
            // and quit use.
            if controller.isStranded, self.closeKeepingText(of: controller) {
                self.windowControllers.removeValue(forKey: controller.noteId)
                return
            }
            self.undo.offerRetryAfterRefusedClose(retry)
        }
        windowControllers[note.id] = controller
        controller.showWindow(nil)
        if activate {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Sync-induced presentation: float the window in without yanking
            // focus from whatever the user is doing. It never becomes key, so
            // nothing else would lift it out of the faded-away state.
            controller.window?.orderFront(nil)
            controller.refreshAlpha()
        }
    }

    private func offerUndoForArchive(of archived: Note) {
        undo.offerUndoForArchive(of: archived) { [weak self] in
            guard let self = self else { return }
            self.store.restore(archived)
            self.focusNote(id: archived.id)
        }
    }

    /// Archive a note from somewhere that is not its window, such as the notes
    /// panel. A note with a window goes through the window's own close, which
    /// writes what was typed first and offers the undo.
    func archiveNote(_ note: Note) {
        if let controller = windowControllers[note.id] {
            controller.closeNote()
            return
        }
        store.archive(note)
        offerUndoForArchive(of: note)
    }

    func focusNote(id: UUID) {
        if id == DailyNote.candidateID {
            focusDailyNote()
            return
        }
        if let controller = windowControllers[id] {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Fallback: load from disk and present (e.g. file appeared via iCloud sync).
        if let note = store.loadActive().first(where: { $0.id == id }) {
            presentWindow(for: note)
        }
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

    /// Create, save, and present a note. Everything that captures a note —
    /// the hotkey, the clipboard, a Service, a URL — comes through here.
    @discardableResult
    func makeNote(
        title: String? = nil,
        text: String = "",
        color: NoteColor? = nil,
        labels: [String] = []
    ) -> UUID {
        // Creating a new note while everything is hidden should bring all
        // notes back so the new one isn't the only thing visible. Clear the
        // flag directly — `toggleHideAll` refuses when there are no windows
        // to unhide, which would leave the note we're about to make hidden.
        showAllIfHidden()

        let frame = nextNoteFrame()
        var note = Note.makeNew(frame: frame, color: settings.defaultNoteColor, now: clock.now())
        layout.set(NoteLayout(frame: frame), for: note.id)
        if let title = title { note.title = title }
        if let color = color { note.color = color }
        note.content = text
        note.labels = labels
        // A note the caller gave something to is edited content and is written
        // now. An empty one gets its file with the first edit, so a misfired
        // hotkey touches no file.
        // Blank as `NoteDocument` judges it, so the blur sweep and this agree:
        // colour and labels are already in the buffer and go out with a first edit.
        let isBlank = (text + (title ?? "")).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var written = true
        if !isBlank {
            if case .failed = store.save(note) { written = false }
        }
        presentWindow(for: note)
        // A capture that could not be written is held by the window alone. Arm a
        // save, so a quit flush tries again and, failing that, makes a recovery file.
        if !written { windowControllers[note.id]?.requestSave() }

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
    private func nextNoteFrame(size: CGSize = NotePlacement.defaultSize) -> NSRect {
        let screen = NotePlacement.screenUnderPointer(
            mouse: NSEvent.mouseLocation,
            screens: NSScreen.screens.map(\.visibleFrame),
            main: NSScreen.main?.visibleFrame
        ) ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let frame = NotePlacement.next(previous: lastNewNoteFrame, screen: screen, size: size)
        lastNewNoteFrame = frame
        return frame
    }

    // MARK: - Visibility

    /// Bring everything back after "hide all", so a note opened or made now is
    /// not the only thing on screen. Clears the flag directly: `toggleHideAll`
    /// refuses when there are no note windows to unhide.
    private func showAllIfHidden() {
        guard notesHidden else { return }
        notesHidden = false
        applyVisibility()
        // The "Hidden N notes — Undo" toast has nothing left to undo.
        undo.dismiss()
    }

    @objc func toggleHideAll() {
        let dailyVisible = dailyNoteController?.window?.isVisible ?? false
        // With only the daily note on the desk, "hide all" hid it, and the same
        // command has to bring it back.
        guard !windowControllers.isEmpty || dailyVisible || notesHidden else { return }

        let wasVisible = windowControllers.values.filter { $0.window?.isVisible == true }.count
            + (dailyVisible ? 1 : 0)
        notesHidden.toggle()
        applyVisibility()

        if notesHidden {
            undo.offerUndoForHiding(count: wasVisible, label: nil) { [weak self] in
                guard let self = self, self.notesHidden else { return }
                self.notesHidden = false
                self.applyVisibility()
            }
        } else {
            undo.dismiss()
        }
    }

    /// Single place that decides which note windows are on screen. "Hide all"
    /// wins over everything; otherwise a note is off screen when one of its
    /// labels is hidden.
    /// Only acts on windows whose state actually needs to change. This runs on
    /// every store change, including the debounced save behind each keystroke —
    /// ordering already-visible windows to the front would make notes jump
    /// above other apps while you type.
    func applyVisibility() {
        let hiddenLabels = settings.hiddenLabels
        for controller in windowControllers.values {
            let shouldHide = notesHidden || hiddenLabels.contains(where: controller.labels.contains)
            setVisible(controller.window, !shouldHide)
        }

        // The daily note has no labels; only "hide all" applies to it, and
        // its own state.visible flag decides whether it should come back.
        setVisible(dailyNoteController?.window, !notesHidden && DailyNote.loadState(settings: settings).visible)
    }

    private func setVisible(_ window: NSWindow?, _ visible: Bool) {
        guard let window = window, window.isVisible != visible else { return }
        if visible { window.orderFront(nil) } else { window.orderOut(nil) }
    }

    /// Hide or show every note carrying `label`, offering to undo a hide.
    func toggleLabelVisibility(_ label: String) {
        var hidden = settings.hiddenLabels
        let hiding = !hidden.contains(label)

        let affected = windowControllers.values.filter {
            $0.labels.contains(label) && $0.window?.isVisible == true
        }.count

        if hiding { hidden.insert(label) } else { hidden.remove(label) }
        settings.hiddenLabels = hidden
        applyVisibility()

        guard hiding else { undo.dismiss(); return }
        undo.offerUndoForHiding(count: affected, label: label) { [weak self] in
            guard let self = self else { return }
            var current = self.settings.hiddenLabels
            current.remove(label)
            self.settings.hiddenLabels = current
            self.applyVisibility()
        }
    }

    func showAllLabels() {
        settings.hiddenLabels = []
        applyVisibility()
    }

    // MARK: - Arrange

    @objc func arrangeGrid() { arrange(using: WindowArrangement.grid(sizes:in:gap:)) }
    @objc func arrangeCascade() { arrange(using: WindowArrangement.cascade(sizes:in:step:)) }

    /// Lay every visible note, and the daily note, out on the screen the pointer
    /// is on. Windows keep their own sizes; only positions move.
    func arrange(animated: Bool = true, using layout: ([CGSize], CGRect, CGFloat) -> [CGRect]) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        var items: [(frame: NSRect, size: CGSize, move: (NSRect) -> Void)] = []
        for controller in windowControllers.values where controller.window?.isVisible == true {
            items.append((controller.window?.frame ?? .zero, controller.arrangementSize, { controller.setArrangedFrame($0, animated: animated) }))
        }
        if let daily = dailyNoteController, daily.window?.isVisible == true {
            items.append((daily.window?.frame ?? .zero, daily.arrangementSize, { daily.setArrangedFrame($0, animated: animated) }))
        }
        // Left-to-right, top-to-bottom, so an arrange broadly preserves
        // where things already were rather than shuffling them.
        items.sort { a, b in
            if a.frame.minY != b.frame.minY { return a.frame.minY > b.frame.minY }
            return a.frame.minX < b.frame.minX
        }
        guard !items.isEmpty else { return }

        let frames = layout(items.map(\.size), visible, 12)
        for (item, frame) in zip(items, frames) {
            item.move(frame)
        }
    }

    // MARK: - Store changes

    /// Bring open windows in line with what's on disk. Triggered by
    /// `NoteStore.didChange`, which fires both for our own writes and for
    /// external file changes — Obsidian edits, files arriving via iCloud
    /// Drive, archives created on another Mac, etc.
    @objc func storeDidChange(_ notification: Notification) {
        if case let .moved(id, from: .archive, to: .active) = NoteStore.change(in: notification) {
            openExpanded(restored: id)
        }
        // A save by this store of a note that already has a window changes
        // nothing on disk the app does not know. All that can differ is
        // whether its labels now hide it.
        if case let .saved(id) = NoteStore.change(in: notification),
           notification.object as AnyObject === store, windowControllers[id] != nil {
            DispatchQueue.main.async { [weak self] in
                self?.applyVisibility()
            }
            return
        }
        handleStoreChange()
    }

    func handleStoreChange() {
        DispatchQueue.main.async { [weak self] in
            self?.reconcileOpenWindows()
        }
    }

    func reconcileOpenWindows() {
        // A folder that cannot be listed says nothing about any note.
        guard let active = store.listActive() else { return }
        let activeIds = Set(active.map { $0.id })

        // Close windows whose underlying note is no longer active (archived
        // or deleted on another machine). Cancel pending debounced saves so
        // an in-flight save can't resurrect a file that was just deleted.
        for id in Array(windowControllers.keys) where !activeIds.contains(id) {
            guard let controller = windowControllers[id], isGone(controller) else { continue }
            if closeKeepingText(of: controller) {
                windowControllers.removeValue(forKey: id)
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

    /// A window is closed for a missing note only when the note is known to be
    /// gone: it had a file, and the folders were listed and no longer hold it. A
    /// listing that is missing the note proves nothing, because a file that is
    /// still downloading or unreadable is missing from it too.
    private func isGone(_ controller: NoteWindowController) -> Bool {
        guard controller.hasFile else { return false }
        switch store.whereIs(id: controller.noteId) {
        case .archived, .trashed, .missing: return true
        case .active, .unknown: return false
        }
    }

    /// Close a window whose note is gone. Text typed into it is written where the
    /// note went; if the store cannot take it, to a recovery file. Only when
    /// neither works does the window stay open, with a retry armed.
    private func closeKeepingText(of controller: NoteWindowController) -> Bool {
        if controller.closeAfterExternalDeletion() { return true }
        guard recovery.write(controller.bufferedNote) else { return false }
        undo.tellRecoveredCopy(in: "the Recovered folder")
        return controller.closeAfterExternalDeletion(textKeptElsewhere: true)
    }

    // MARK: - Panel and switcher

    @objc func showNotesPanel() {
        if notesPanelController == nil {
            notesPanelController = NotesPanelController(
                store: store,
                dailyNote: { [weak self] in self?.dailyCandidate() },
                onActivate: { [weak self] id in self?.focusNote(id: id) },
                onArchive: { [weak self] note in self?.archiveNote(note) }
            )
        } else {
            notesPanelController?.reload()
        }
        notesPanelController?.showWindow(nil)
        notesPanelController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Pressing the hotkey again while the palette is up closes it, so the
    /// same chord opens and dismisses.
    var switcher: QuickSwitcherController? { quickSwitcher }

    @objc func toggleQuickSwitcher() {
        if quickSwitcher?.isVisible == true {
            quickSwitcher?.dismiss()
            return
        }
        showQuickSwitcher()
    }

    /// Open the palette, optionally with a query already typed.
    func showQuickSwitcher(query: String = "") {
        if quickSwitcher == nil {
            quickSwitcher = QuickSwitcherController(
                store: store, dailyNote: { [weak self] in self?.dailyCandidate() }
            ) { [weak self] outcome in
                self?.handle(outcome)
            }
        }
        quickSwitcher?.show()
        if !query.isEmpty { quickSwitcher?.search(query) }
    }

    /// Act on a quick-switcher result. Picking one should always end with a
    /// note on screen — un-hiding, un-archiving, or creating as needed.
    private func handle(_ outcome: QuickSwitcherController.Outcome) {
        switch outcome {
        case let .open(id, wasArchived):
            if wasArchived, let note = store.loadNote(id: id, archived: true) {
                store.restore(note)
            }
            if notesHidden { toggleHideAll() }
            focusNote(id: id)

        case .openDaily:
            focusDailyNote()

        case let .create(title):
            // Searching for a note that isn't there is a capture intent —
            // keep the typed words as the title and start in the body.
            makeNote(title: title)
        }
    }

    /// A `[[wiki link]]` points at one of our notes when a title matches, at
    /// today's daily note when it says "Today" or names that file. Anything else
    /// is probably a note elsewhere in the vault, so it goes to Obsidian
    /// rather than doing nothing.
    @objc private func handleWikiLinkClick(_ notification: Notification) {
        guard let target = notification.userInfo?["target"] as? String else { return }

        if let match = WikiLink.resolve(target, in: store.loadActive()) {
            focusNote(id: match.id)
            return
        }
        if canShowDailyNote,
           DailyNote.linkNamesDailyNote(target, fileURL: DailyNote.resolvedURL(for: clock.now(), settings: settings),
                                        settings: settings) {
            focusDailyNote()
            return
        }
        if let archived = WikiLink.resolve(target, in: store.loadArchived()) {
            store.restore(archived)
            focusNote(id: archived.id)
            return
        }
        if let vault = settings.obsidianVaultPath,
           let url = WikiLink.obsidianURL(vaultPath: vault, target: target) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Text size

    @objc func increaseTextSize() { applyTextSize(settings.bodyFontSize + 1) }
    @objc func decreaseTextSize() { applyTextSize(settings.bodyFontSize - 1) }
    @objc func resetTextSize() { applyTextSize(Settings.defaultBodyFontSize) }

    /// One size for every note — a per-note size would be a setting nobody
    /// asked for and a lot of state to keep straight.
    private func applyTextSize(_ size: CGFloat) {
        let clamped = Settings.clampFontSize(size)
        guard clamped != settings.bodyFontSize else { return }
        settings.bodyFontSize = clamped
        MarkdownStyler.baseFontSize = clamped
        for controller in windowControllers.values {
            controller.restyleForTextSize()
        }
        dailyNoteController?.restyleForTextSize()
    }

    // MARK: - Daily note

    /// The daily note window, if one exists.
    var dailyNote: DailyNoteWindowController? { dailyNoteController }

    var isDailyNoteVisible: Bool { dailyNoteController?.window?.isVisible ?? false }

    /// Daily notes need a vault and a filename pattern.
    var canShowDailyNote: Bool {
        settings.obsidianVaultPath != nil && settings.dailyNotesPattern != nil
    }

    private func makeDailyNoteController() -> DailyNoteWindowController {
        let controller = DailyNoteWindowController(settings: settings, store: store, clock: clock, scheduler: scheduler)
        controller.dailyDocument.saveRecovery = { [recovery] body, day in
            recovery.writeDaily(body: body, day: day)
        }
        return controller
    }

    func restoreDailyNoteIfNeeded() {
        guard canShowDailyNote else { return }
        let state = DailyNote.loadState(settings: settings)
        guard state.visible else { return }
        if dailyNoteController == nil {
            dailyNoteController = makeDailyNoteController()
        }
        // Reopening what was already on screen isn't a fresh request for
        // today's note, so it doesn't create the file — every Mac does this
        // unattended at launch, and only one of them should be creating.
        dailyNoteController?.show(userInitiated: false)
    }

    @objc func toggleDailyNote() {
        guard canShowDailyNote else { return }
        if let controller = dailyNoteController, controller.window?.isVisible == true {
            controller.hide()
            return
        }
        if dailyNoteController == nil {
            dailyNoteController = makeDailyNoteController()
        }
        dailyNoteController?.show()
    }

    /// Today's note as the switcher and the panel list it: titled "Today", with
    /// the text the window holds or, before a window exists, what the file holds
    /// now. It only reads: listing the note never creates its file. Nil when no
    /// daily note is set up.
    func dailyCandidate() -> Note? {
        guard canShowDailyNote else { return nil }
        let color = DailyNote.loadState(settings: settings).color
        if let document = dailyNoteController?.dailyDocument {
            return DailyNote.candidate(
                body: document.isUnavailable ? "" : document.body, day: document.day,
                modified: document.url.flatMap(Self.modificationDate(of:)), color: color
            )
        }
        let now = clock.now()
        let url = DailyNote.resolvedURL(for: now, settings: settings)
        let body = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return DailyNote.candidate(
            body: body, day: Calendar.current.startOfDay(for: now),
            modified: url.flatMap(Self.modificationDate(of:)), color: color
        )
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Open today's note and bring it forward, undoing "hide all" first. The
    /// person chose it, so it may create the file, exactly as the menu does.
    func focusDailyNote() {
        guard canShowDailyNote else { return }
        showAllIfHidden()
        if dailyNoteController == nil {
            dailyNoteController = makeDailyNoteController()
        }
        dailyNoteController?.show()
    }

    func openTodaysDailyNote() {
        toggleDailyNote()
        // toggleDailyNote toggles — if it was already visible we just hid it.
        // Make sure it ends up visible regardless.
        if dailyNoteController?.window?.isVisible != true {
            if dailyNoteController == nil {
                dailyNoteController = makeDailyNoteController()
            }
            dailyNoteController?.show()
        }
    }

    /// Close the daily note window for good. Unsaved text goes to disk first, or
    /// to a recovery file: the controller and its pending save go with it.
    func tearDownDailyNote() {
        if let controller = dailyNoteController, !controller.flushPendingSave() {
            _ = recovery.writeDaily(controller.dailyDocument)
        }
        dailyNoteController?.window?.orderOut(nil)
        dailyNoteController = nil
    }

    func dailyNotePatternDidChange() {
        dailyNoteController?.patternDidChange()
    }

    func dailyNoteTemplateDidChange() {
        dailyNoteController?.templateDidChange()
    }

    // MARK: - Quitting

    /// Drains every window's debounce. Returns the windows whose text did not reach disk.
    func flushPendingSaves() -> [NoteWindowController] {
        windowControllers.values.filter { !$0.flushPendingSave() }
    }

    /// Saves are debounced, so quitting has to drain them before the process
    /// goes away — otherwise everything typed since the last pause is lost.
    ///
    /// A window whose save fails here (a full disk, a revoked permission) has
    /// text that is about to exist nowhere. Each such buffer is written to a
    /// recovery file outside the storage root. Returns how many buffers are
    /// still nowhere after that.
    func flushForQuit() -> Int {
        layout.flush()
        let unsaved = flushPendingSaves()
        let dailyLost = dailyNoteController.map { !$0.flushPendingSave() && !recovery.writeDaily($0.dailyDocument) } ?? false
        let unrecovered = unsaved.filter { !recovery.write($0.bufferedNote) }
        return unrecovered.count + (dailyLost ? 1 : 0)
    }
}
