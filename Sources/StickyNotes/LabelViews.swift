import AppKit

// MARK: - Label chip

/// Small rounded pill that renders a `#label`. Clicks bubble up so the
/// owning note window can present a remove menu.
final class LabelChipView: NSView {
    let labelName: String
    var onRemove: (() -> Void)?

    private static let font = NSFont.systemFont(ofSize: 10, weight: .medium)
    private static let horizontalPadding: CGFloat = 6
    private static let verticalPadding: CGFloat = 1

    init(labelName: String) {
        self.labelName = labelName
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        toolTip = "Click to remove"
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let text = "#\(labelName)" as NSString
        let textSize = text.size(withAttributes: [.font: LabelChipView.font])
        return NSSize(
            width: ceil(textSize.width) + LabelChipView.horizontalPadding * 2,
            height: ceil(textSize.height) + LabelChipView.verticalPadding * 2
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = "#\(labelName)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: LabelChipView.font,
            .foregroundColor: NSColor.black.withAlphaComponent(0.65)
        ]
        let textSize = text.size(withAttributes: attrs)
        let x = (bounds.width - textSize.width) / 2
        let y = (bounds.height - textSize.height) / 2
        text.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        // Single-click → remove this label from the note.
        onRemove?()
    }
}

// MARK: - Label autocomplete panel

/// Borderless, non-activating floating panel that lists matching label
/// suggestions while the user is typing `#xxx` inside a note body.
final class LabelCompletionPanel: NSPanel {
    enum Item {
        case existing(String)
        case create(String)

        var displayLabel: String {
            switch self {
            case .existing(let name): return "#\(name)"
            case .create(let name):   return "Create #\(name)"
            }
        }

        var labelName: String {
            switch self {
            case .existing(let name), .create(let name): return name
            }
        }
    }

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private(set) var items: [Item] = []

    var onAccept: ((Item) -> Void)?

    private static let rowHeight: CGFloat = 22
    private static let maxVisibleRows: Int = 6
    private static let panelWidth: CGFloat = 180

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: LabelCompletionPanel.panelWidth, height: 0),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        hasShadow = true
        isMovable = false
        backgroundColor = .clear

        let visualEffect = NSVisualEffectView()
        visualEffect.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.material = .menu
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 6
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
        visualEffect.layer?.borderWidth = 0.5

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("label"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = LabelCompletionPanel.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.gridStyleMask = []
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        contentView = visualEffect
        visualEffect.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: 2),
            scrollView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor, constant: -2),
            scrollView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 2),
            scrollView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -2)
        ])
    }

    func setItems(_ items: [Item]) {
        self.items = items
        tableView.reloadData()
        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
        resizeToFit()
    }

    func selectNext() {
        guard !items.isEmpty else { return }
        let next = min(tableView.selectedRow + 1, items.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    func selectPrevious() {
        guard !items.isEmpty else { return }
        let prev = max(tableView.selectedRow - 1, 0)
        tableView.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
        tableView.scrollRowToVisible(prev)
    }

    /// Returns true if the current selection was accepted (closes the panel).
    @discardableResult
    func acceptSelection() -> Bool {
        let row = tableView.selectedRow
        guard row >= 0 && row < items.count else { return false }
        onAccept?(items[row])
        return true
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0 && row < items.count else { return }
        onAccept?(items[row])
    }

    private func resizeToFit() {
        let visibleRows = min(items.count, LabelCompletionPanel.maxVisibleRows)
        let height = max(1, CGFloat(visibleRows)) * LabelCompletionPanel.rowHeight + 4
        var frame = self.frame
        let oldHeight = frame.size.height
        frame.size.height = height
        frame.origin.y += oldHeight - height
        setFrame(frame, display: true)
    }
}

extension LabelCompletionPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("labelRow")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.font = NSFont.systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingTail
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let item = items[row]
        cell.textField?.stringValue = item.displayLabel
        switch item {
        case .existing: cell.textField?.textColor = NSColor.labelColor
        case .create:   cell.textField?.textColor = NSColor.secondaryLabelColor
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
}
