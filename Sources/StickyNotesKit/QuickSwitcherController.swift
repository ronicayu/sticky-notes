import AppKit

/// Spotlight-style palette for jumping to any note — active or archived — by
/// typing. The notes panel is a browser; this is the keyboard path for when you
/// already know what you're looking for.
final class QuickSwitcherController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    /// What the caller should do with the chosen note. Archived notes are
    /// restored first, which is why the controller reports intent rather than
    /// acting on the store itself.
    struct Selection {
        let id: UUID
        let wasArchived: Bool
    }

    private let store: NoteStore
    private let onChoose: (Selection) -> Void

    private let searchField = QuickSwitcherSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")

    /// Every candidate, loaded once per invocation. Re-reading the store on
    /// each keystroke would be wasted work — the cache makes it cheap, but the
    /// results shouldn't shift under the user mid-type either.
    private var candidates: [Note] = []
    private var archivedIds: Set<UUID> = []
    private var results: [NoteMatch] = []

    init(store: NoteStore, onChoose: @escaping (Selection) -> Void) {
        self.store = store
        self.onChoose = onChoose

        let panel = QuickSwitcherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        super.init(window: panel)
        panel.onCancel = { [weak self] in self?.dismiss() }
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Presentation

    func show() {
        reloadCandidates()
        searchField.stringValue = ""
        runQuery("")
        positionOnActiveScreen()

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(searchField)
    }

    func dismiss() {
        window?.orderOut(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Centered horizontally and set slightly high on whichever screen has the
    /// pointer — where a launcher is expected, rather than wherever it last sat.
    private func positionOnActiveScreen() {
        guard let window = window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { window.center(); return }

        let size = window.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + visible.height * 0.62 - size.height / 2
        )
        window.setFrameOrigin(origin)
    }

    private func reloadCandidates() {
        let active = store.loadActive()
        let archived = store.loadArchived()
        archivedIds = Set(archived.map(\.id))
        candidates = active + archived
    }

    // MARK: - UI

    private func setupUI() {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search notes…  (#label to filter by label)"
        searchField.font = NSFont.systemFont(ofSize: 20, weight: .regular)
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.onMoveSelection = { [weak self] delta in self?.moveSelection(by: delta) }
        searchField.onCommit = { [weak self] in self?.activateSelection() }

        let divider = NSBox()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.boxType = .separator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 46
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.style = .inset
        tableView.gridStyleMask = []
        tableView.backgroundColor = .clear
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .center

        let container = NSView()
        container.addSubview(searchField)
        container.addSubview(divider)
        container.addSubview(scrollView)
        container.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),

            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),

            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])

        window?.contentView = container
    }

    // MARK: - Query

    func controlTextDidChange(_ obj: Notification) {
        runQuery(searchField.stringValue)
    }

    /// Type `query` into the palette programmatically — used to open it
    /// pre-filled, and by tests to drive it without synthesizing key events.
    func search(_ query: String) {
        searchField.stringValue = query
        runQuery(query)
    }

    /// How many notes the current query matched.
    var resultCount: Int { results.count }

    private func runQuery(_ query: String) {
        results = NoteSearch.rank(candidates, query: query)
        tableView.reloadData()
        if !results.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
        updateStatus(query: query)
    }

    private func updateStatus(query: String) {
        if candidates.isEmpty {
            statusLabel.stringValue = "No notes yet — ⌘⇧S makes one"
        } else if results.isEmpty {
            statusLabel.stringValue = "No matches for “\(query)”"
        } else {
            let noun = results.count == 1 ? "note" : "notes"
            statusLabel.stringValue = "\(results.count) \(noun)  ·  ↑↓ to move  ·  ↩ to open  ·  esc to close"
        }
    }

    // MARK: - Selection

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = tableView.selectedRow
        let next = max(0, min(results.count - 1, (current < 0 ? 0 : current) + delta))
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0 && row < results.count else { return }
        choose(results[row])
    }

    /// Open the highlighted result — what Return does.
    func activateSelection() {
        let row = tableView.selectedRow
        guard row >= 0 && row < results.count else { return }
        choose(results[row])
    }

    private func choose(_ match: NoteMatch) {
        dismiss()
        onChoose(Selection(id: match.note.id, wasArchived: archivedIds.contains(match.note.id)))
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: QuickSwitcherCell.reuseIdentifier, owner: self) as? QuickSwitcherCell
            ?? QuickSwitcherCell()
        let match = results[row]
        cell.configure(with: match, archived: archivedIds.contains(match.note.id))
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
}

// MARK: - Panel

/// Borderless-ish panel that can take key focus and closes on escape.
private final class QuickSwitcherPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Text field that hands arrow keys and return to the controller instead of
/// letting the field editor swallow them.
private final class QuickSwitcherSearchField: NSTextField {
    var onMoveSelection: ((Int) -> Void)?
    var onCommit: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { currentEditor()?.selectedRange = NSRange(location: stringValue.count, length: 0) }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 125: onMoveSelection?(1)      // down arrow
        case 126: onMoveSelection?(-1)     // up arrow
        case 36, 76: onCommit?()           // return, enter
        default: super.keyDown(with: event)
        }
    }

    /// ⌃N / ⌃P as arrow synonyms, matching the emacs bindings macOS text
    /// fields already honor elsewhere.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .control, let key = event.charactersIgnoringModifiers?.lowercased() {
            if key == "n" { onMoveSelection?(1); return true }
            if key == "p" { onMoveSelection?(-1); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Row

private final class QuickSwitcherCell: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("quickSwitcherCell")

    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = QuickSwitcherCell.reuseIdentifier

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
        dot.layer?.borderWidth = 0.5

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.usesSingleLineMode = true

        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        badge.textColor = .tertiaryLabelColor
        badge.alignment = .right
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(dot)
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(badge)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 16),
            dot.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with match: NoteMatch, archived: Bool) {
        dot.layer?.backgroundColor = NSColor(hex: match.note.color.bodyHex)?.cgColor

        let heading = NoteSearch.summary(of: match.note)
        titleLabel.stringValue = heading.isEmpty ? "(empty note)" : heading
        titleLabel.textColor = heading.isEmpty ? .tertiaryLabelColor : .labelColor

        // Only repeat the excerpt when it says something the heading doesn't.
        let excerpt = match.excerpt
        detailLabel.stringValue = (excerpt == heading) ? relativeDate(match.note) : excerpt

        // Task progress earns the badge slot over the archived marker — it
        // changes, and it's the thing you're deciding on.
        if let progress = MarkdownEditing.checkboxProgress(in: match.note.content) {
            badge.stringValue = archived
                ? "\(progress.done)/\(progress.total) · archived"
                : "\(progress.done)/\(progress.total)"
        } else {
            badge.stringValue = archived ? "archived" : ""
        }
    }

    /// A note edited seconds ago reads as "in 0 seconds" through
    /// RelativeDateTimeFormatter, and a save that lands a moment in the future
    /// reads worse. Collapse the whole recent window to "just now".
    private func relativeDate(_ note: Note) -> String {
        let age = Date().timeIntervalSince(note.updatedAt)
        if age < 60 { return "just now" }
        return QuickSwitcherCell.relativeFormatter.localizedString(for: note.updatedAt, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}
