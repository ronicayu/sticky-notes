import AppKit

/// Single panel that lists every sticky note (active + archived). Toggle with a
/// segmented control. Active rows focus their on-desktop note window when
/// clicked; archived rows can be restored or permanently deleted.
final class NotesPanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    enum Mode: Int { case active = 0, archived = 1 }

    /// Ordering for the list. Search results ignore this and use relevance —
    /// re-sorting them by date would throw away the ranking.
    enum SortOrder: Int, CaseIterable {
        case updated, created, title, color

        var title: String {
            switch self {
            case .updated: return "Last edited"
            case .created: return "Date created"
            case .title:   return "Title"
            case .color:   return "Color"
            }
        }
    }

    private let store: NoteStore
    private let onActivate: (UUID) -> Void

    private var mode: Mode = .active
    private var sortOrder: SortOrder = .updated
    /// nil means "all labels".
    private var labelFilter: String?
    private var rows: [NoteMatch] = []

    private let segmented = NSSegmentedControl()
    private let labelPopUp = NSPopUpButton()
    private let sortPopUp = NSPopUpButton()
    private let searchField = NSSearchField()
    private let tableView = NotesPanelTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let restoreButton = NSButton(title: "Restore", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)

    init(store: NoteStore, onActivate: @escaping (UUID) -> Void) {
        self.store = store
        self.onActivate = onActivate

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Notes"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 320)

        super.init(window: window)
        setupUI()
        reload()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStoreChange),
            name: NoteStore.didChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleStoreChange() {
        DispatchQueue.main.async { [weak self] in
            self?.reload()
        }
    }

    private func setupUI() {
        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.segmentCount = 2
        segmented.setLabel("Active", forSegment: 0)
        segmented.setLabel("Archived", forSegment: 1)
        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(segmentChanged)
        segmented.segmentStyle = .rounded
        segmented.setContentCompressionResistancePriority(.required, for: .horizontal)
        segmented.setContentHuggingPriority(.required, for: .horizontal)

        labelPopUp.translatesAutoresizingMaskIntoConstraints = false
        labelPopUp.target = self
        labelPopUp.action = #selector(labelFilterChanged)
        labelPopUp.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        sortPopUp.translatesAutoresizingMaskIntoConstraints = false
        sortPopUp.target = self
        sortPopUp.action = #selector(sortChanged)
        for order in SortOrder.allCases {
            let item = NSMenuItem(title: order.title, action: nil, keyEquivalent: "")
            item.representedObject = order.rawValue
            sortPopUp.menu?.addItem(item)
        }
        sortPopUp.selectItem(at: 0)
        sortPopUp.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search titles, labels, and text"
        searchField.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.title = "Notes"
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 44
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.style = .inset
        tableView.gridStyleMask = []
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.onActivate = { [weak self] in self?.activateSelectedRow() }
        tableView.onArchive = { [weak self] in self?.archiveSelectedRow() }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.isHidden = true

        restoreButton.translatesAutoresizingMaskIntoConstraints = false
        restoreButton.target = self
        restoreButton.action = #selector(restoreSelected)
        restoreButton.bezelStyle = .rounded

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        deleteButton.bezelStyle = .rounded
        deleteButton.hasDestructiveAction = true

        let container = NSView()
        container.addSubview(segmented)
        container.addSubview(labelPopUp)
        container.addSubview(sortPopUp)
        container.addSubview(searchField)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        container.addSubview(restoreButton)
        container.addSubview(deleteButton)

        NSLayoutConstraint.activate([
            segmented.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            segmented.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),

            labelPopUp.leadingAnchor.constraint(equalTo: segmented.trailingAnchor, constant: 8),
            labelPopUp.centerYAnchor.constraint(equalTo: segmented.centerYAnchor),

            sortPopUp.leadingAnchor.constraint(greaterThanOrEqualTo: labelPopUp.trailingAnchor, constant: 8),
            sortPopUp.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            sortPopUp.centerYAnchor.constraint(equalTo: segmented.centerYAnchor),

            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 10),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: deleteButton.topAnchor, constant: -10),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20),

            deleteButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            deleteButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),

            restoreButton.leadingAnchor.constraint(equalTo: deleteButton.trailingAnchor, constant: 8),
            restoreButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])

        window?.contentView = container
        updateBottomBarVisibility()
    }

    // MARK: - Controls

    @objc private func segmentChanged() {
        mode = Mode(rawValue: segmented.selectedSegment) ?? .active
        updateBottomBarVisibility()
        reload()
    }

    @objc private func labelFilterChanged() {
        labelFilter = labelPopUp.selectedItem?.representedObject as? String
        reload()
    }

    @objc private func sortChanged() {
        if let raw = sortPopUp.selectedItem?.representedObject as? Int,
           let order = SortOrder(rawValue: raw) {
            sortOrder = order
        }
        reload()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        reload()
    }

    private func updateBottomBarVisibility() {
        let archived = mode == .archived
        restoreButton.isHidden = !archived
        deleteButton.isHidden = !archived
    }

    // MARK: - Data

    func reload() {
        let previousSelection = selectedNote()?.id
        rebuildLabelMenu()

        let source = mode == .active ? store.loadActive() : store.loadArchived()
        let scoped = labelFilter.map { label in source.filter { $0.labels.contains(label) } } ?? source

        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let ranked = NoteSearch.rank(scoped, query: query)
        // Relevance order is the point of a search; only impose the chosen
        // sort when the user isn't searching.
        rows = query.isEmpty ? sorted(ranked) : ranked

        tableView.reloadData()
        restoreSelection(previousSelection)
        updateEmptyState(query: query)
    }

    private func sorted(_ matches: [NoteMatch]) -> [NoteMatch] {
        switch sortOrder {
        case .updated:
            return matches.sorted { $0.note.updatedAt > $1.note.updatedAt }
        case .created:
            return matches.sorted { $0.note.createdAt > $1.note.createdAt }
        case .title:
            return matches.sorted {
                NoteSearch.summary(of: $0.note).localizedCaseInsensitiveCompare(NoteSearch.summary(of: $1.note)) == .orderedAscending
            }
        case .color:
            let order = Dictionary(uniqueKeysWithValues: NoteColor.allCases.enumerated().map { ($1, $0) })
            return matches.sorted {
                let a = order[$0.note.color] ?? 0, b = order[$1.note.color] ?? 0
                if a != b { return a < b }
                return $0.note.updatedAt > $1.note.updatedAt
            }
        }
    }

    /// Rebuild the label menu in place, preserving the current choice. A label
    /// that no longer exists on any note falls back to "All labels".
    private func rebuildLabelMenu() {
        let labels = store.allLabels()
        let menu = NSMenu()

        let allItem = NSMenuItem(title: "All labels", action: nil, keyEquivalent: "")
        allItem.representedObject = nil
        menu.addItem(allItem)

        if !labels.isEmpty {
            menu.addItem(.separator())
            for label in labels {
                let item = NSMenuItem(title: "#\(label)", action: nil, keyEquivalent: "")
                item.representedObject = label
                menu.addItem(item)
            }
        }
        labelPopUp.menu = menu
        labelPopUp.isEnabled = !labels.isEmpty

        if let current = labelFilter, labels.contains(current) {
            labelPopUp.selectItem(at: (labels.firstIndex(of: current) ?? 0) + 2)
        } else {
            labelFilter = nil
            labelPopUp.selectItem(at: 0)
        }
    }

    private func updateEmptyState(query: String) {
        guard rows.isEmpty else {
            emptyLabel.isHidden = true
            return
        }
        emptyLabel.isHidden = false
        if !query.isEmpty {
            emptyLabel.stringValue = "No notes match “\(query)”"
        } else if let label = labelFilter {
            emptyLabel.stringValue = "No \(mode == .active ? "active" : "archived") notes tagged #\(label)"
        } else if mode == .active {
            emptyLabel.stringValue = "No active notes.\nPress ⌘⇧S to make one."
        } else {
            emptyLabel.stringValue = "Nothing archived yet."
        }
        emptyLabel.maximumNumberOfLines = 0
    }

    // MARK: - Selection

    private func selectedNote() -> Note? {
        let row = tableView.selectedRow
        guard row >= 0 && row < rows.count else { return nil }
        return rows[row].note
    }

    private func restoreSelection(_ id: UUID?) {
        guard let id = id, let index = rows.firstIndex(where: { $0.note.id == id }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0 && row < rows.count, mode == .active else { return }
        onActivate(rows[row].note.id)
    }

    /// Return on a selected row: focus an active note, restore an archived one.
    private func activateSelectedRow() {
        guard let note = selectedNote() else { return }
        if mode == .archived {
            store.restore(note)
        }
        onActivate(note.id)
    }

    /// ⌘⌫ archives an active note, matching the note window's close button.
    private func archiveSelectedRow() {
        guard mode == .active, let note = selectedNote() else { return }
        store.archive(note)
    }

    @objc private func restoreSelected() {
        guard mode == .archived, let note = selectedNote() else { return }
        store.restore(note)
        onActivate(note.id)
    }

    @objc private func deleteSelected() {
        guard mode == .archived, let note = selectedNote() else { return }

        let alert = NSAlert()
        alert.messageText = "Delete this note permanently?"
        alert.informativeText = NoteSearch.summary(of: note).isEmpty ? "(empty note)" : NoteSearch.summary(of: note)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            store.deleteForever(note)
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NotesPanelCell.reuseIdentifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NotesPanelCell
            ?? NotesPanelCell()
        cell.configure(with: rows[row])
        return cell
    }

    // MARK: - Programmatic control
    //
    // The same operations the controls perform, callable directly so the panel
    // can be opened pre-filtered and driven without synthesizing UI events.

    /// Number of rows the current mode, label filter, and query produce.
    var rowCount: Int { rows.count }

    /// Headings of the listed rows, in display order.
    var visibleTitles: [String] { rows.map { NoteSearch.summary(of: $0.note) } }

    func search(_ query: String) {
        searchField.stringValue = query
        reload()
    }

    /// Pass nil to clear the filter and show every label.
    func filterByLabel(_ label: String?) {
        labelFilter = label
        reload()
    }

    func sort(by order: SortOrder) {
        sortOrder = order
        sortPopUp.selectItem(at: order.rawValue)
        reload()
    }

    func showMode(_ newMode: Mode) {
        mode = newMode
        segmented.selectedSegment = newMode.rawValue
        updateBottomBarVisibility()
        reload()
    }
}

/// Table that reports Return and ⌘⌫ instead of beeping at them.
private final class NotesPanelTableView: NSTableView {
    var onActivate: (() -> Void)?
    var onArchive: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let isDelete = event.keyCode == 51 || event.keyCode == 117

        if isReturn {
            onActivate?()
        } else if isDelete && mods.contains(.command) {
            onArchive?()
        } else {
            super.keyDown(with: event)
        }
    }
}

final class NotesPanelCell: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("notesPanelCell")

    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = NotesPanelCell.reuseIdentifier

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
        dot.layer?.borderWidth = 0.5

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.font = NSFont.systemFont(ofSize: 12)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
        detail.usesSingleLineMode = true
        detail.font = NSFont.systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = NSFont.systemFont(ofSize: 10)
        timeLabel.textColor = NSColor.secondaryLabelColor
        timeLabel.alignment = .right
        timeLabel.lineBreakMode = .byClipping
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(dot)
        addSubview(label)
        addSubview(detail)
        addSubview(timeLabel)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 14),
            dot.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            detail.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 1),

            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with match: NoteMatch) {
        let note = match.note
        dot.layer?.backgroundColor = NSColor(hex: note.color.bodyHex)?.cgColor

        let heading = NoteSearch.summary(of: note)
        if heading.isEmpty {
            label.stringValue = "(empty note)"
            label.textColor = .tertiaryLabelColor
        } else {
            label.stringValue = NotesPanelCell.stripMarkdown(heading)
            label.textColor = .labelColor
        }

        // Show why this row matched, unless that just repeats the heading.
        detail.stringValue = match.excerpt == heading ? labelSummary(note) : match.excerpt
        detail.isHidden = detail.stringValue.isEmpty

        timeLabel.stringValue = NotesPanelCell.relativeFormatter.localizedString(for: note.updatedAt, relativeTo: Date())
    }

    private func labelSummary(_ note: Note) -> String {
        note.labels.isEmpty ? "" : note.labels.map { "#\($0)" }.joined(separator: "  ")
    }

    private static func stripMarkdown(_ line: String) -> String {
        var s = line
        // leading heading markers
        while s.hasPrefix("#") { s.removeFirst() }
        if s.hasPrefix(" ") { s.removeFirst() }
        // leading list markers
        if s.hasPrefix("- ") || s.hasPrefix("* ") { s.removeFirst(2) }
        // strip surrounding bold/italic/code markers (cosmetic only)
        s = s.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "~~", with: "")
            .replacingOccurrences(of: "`", with: "")
        return s
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}
