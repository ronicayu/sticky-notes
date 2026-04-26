import AppKit

/// Single panel that lists every sticky note (active + archived). Toggle with a
/// segmented control. Active rows focus their on-desktop note window when
/// clicked; archived rows can be restored or permanently deleted.
final class NotesPanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    enum Mode: Int { case active = 0, archived = 1 }

    private let store: NoteStore
    private let onActivate: (UUID) -> Void

    private var mode: Mode = .active
    private var notes: [Note] = []

    private let segmented = NSSegmentedControl()
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let restoreButton = NSButton(title: "Restore", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)

    init(store: NoteStore, onActivate: @escaping (UUID) -> Void) {
        self.store = store
        self.onActivate = onActivate

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Notes"
        window.center()
        window.isReleasedWhenClosed = false

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

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search notes"
        searchField.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.title = "Notes"
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 40
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.style = .inset
        tableView.gridStyleMask = []
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

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
        container.addSubview(searchField)
        container.addSubview(scrollView)
        container.addSubview(restoreButton)
        container.addSubview(deleteButton)

        NSLayoutConstraint.activate([
            segmented.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            segmented.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),

            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 10),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: deleteButton.topAnchor, constant: -10),

            deleteButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            deleteButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),

            restoreButton.leadingAnchor.constraint(equalTo: deleteButton.trailingAnchor, constant: 8),
            restoreButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])

        window?.contentView = container
        updateBottomBarVisibility()
    }

    @objc private func segmentChanged() {
        mode = Mode(rawValue: segmented.selectedSegment) ?? .active
        updateBottomBarVisibility()
        reload()
    }

    private func updateBottomBarVisibility() {
        let archived = mode == .archived
        restoreButton.isHidden = !archived
        deleteButton.isHidden = !archived
    }

    func reload() {
        let raw: [Note]
        switch mode {
        case .active:
            raw = store.loadActive().sorted { $0.updatedAt > $1.updatedAt }
        case .archived:
            raw = store.loadArchived()
        }
        notes = filter(raw)
        tableView.reloadData()
    }

    private func filter(_ raw: [Note]) -> [Note] {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return raw }
        return raw.filter { $0.content.range(of: query, options: .caseInsensitive) != nil }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        reload()
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0 && row < notes.count else { return }
        guard mode == .active else { return }
        onActivate(notes[row].id)
    }

    @objc private func restoreSelected() {
        let row = tableView.selectedRow
        guard mode == .archived, row >= 0 && row < notes.count else { return }
        let note = notes[row]
        store.restore(note)
        onActivate(note.id)
    }

    @objc private func deleteSelected() {
        let row = tableView.selectedRow
        guard mode == .archived, row >= 0 && row < notes.count else { return }
        let note = notes[row]

        let alert = NSAlert()
        alert.messageText = "Delete this note permanently?"
        alert.informativeText = preview(note)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            store.deleteForever(note)
        }
    }

    private func preview(_ note: Note) -> String {
        let trimmed = note.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "(empty note)" }
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
        return String(firstLine.prefix(120))
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { notes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NotesPanelCell.reuseIdentifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NotesPanelCell
            ?? NotesPanelCell()
        cell.configure(with: notes[row])
        return cell
    }
}

final class NotesPanelCell: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("notesPanelCell")

    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
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

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = NSFont.systemFont(ofSize: 10)
        timeLabel.textColor = NSColor.secondaryLabelColor
        timeLabel.alignment = .right
        timeLabel.lineBreakMode = .byClipping
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(dot)
        addSubview(label)
        addSubview(timeLabel)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 14),
            dot.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with note: Note) {
        dot.layer?.backgroundColor = NSColor(hex: note.color.bodyHex)?.cgColor

        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = note.content.trimmingCharacters(in: .whitespacesAndNewlines)

        if !title.isEmpty {
            label.stringValue = String(title.prefix(160))
            label.textColor = NSColor.labelColor
        } else if !body.isEmpty {
            let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
            label.stringValue = NotesPanelCell.stripMarkdown(String(firstLine.prefix(160)))
            label.textColor = NSColor.labelColor
        } else {
            label.stringValue = "(empty note)"
            label.textColor = NSColor.tertiaryLabelColor
        }
        timeLabel.stringValue = NotesPanelCell.relativeFormatter.localizedString(for: note.updatedAt, relativeTo: Date())
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
