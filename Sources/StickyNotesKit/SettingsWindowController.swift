import AppKit
import KeyboardShortcuts

/// Single Preferences window with three toolbar-selectable panes:
/// General, Storage, Daily Note. Replaces the menu-bar configuration
/// soup that used to expose every setting as its own menu item.
///
/// Side effects (re-pointing the NoteStore at a new root, restarting
/// the iCloud prefetcher, etc.) belong to the `SettingsCoordinator`
/// — this controller only mutates `Settings.shared` and tells the
/// coordinator what changed.
protocol SettingsCoordinator: AnyObject {
    func applyStorageMode(_ mode: SettingsWindowController.StorageMode)
    func applyDailyPattern(_ pattern: String?)
    func applyDailyTemplate(_ path: String?)
    func revealStorageFolder()
    func openTodaysDailyNote()
}

final class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {

    enum StorageMode: Equatable {
        case local
        case iCloud
        case vault(path: String)
    }

    private enum Pane: String, CaseIterable {
        case general = "general"
        case storage = "storage"
        case daily   = "daily"

        var title: String {
            switch self {
            case .general: return "General"
            case .storage: return "Storage"
            case .daily:   return "Daily Note"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .storage: return "externaldrive"
            case .daily:   return "calendar"
            }
        }

        var itemID: NSToolbarItem.Identifier {
            NSToolbarItem.Identifier("settings.\(rawValue)")
        }
    }

    private weak var coordinator: SettingsCoordinator?

    private let container = NSView()
    private var paneViews: [Pane: NSView] = [:]
    private var current: Pane = .general

    init(coordinator: SettingsCoordinator) {
        self.coordinator = coordinator

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.toolbarStyle = .preference

        super.init(window: window)
        window.delegate = self

        setupToolbar()
        setupContainer()
        buildPanes()
        select(.general, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Toolbar

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.selectedItemIdentifier = Pane.general.itemID
        window?.toolbar = toolbar
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = Pane.allCases.first(where: { $0.itemID == itemIdentifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.paletteLabel = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map { $0.itemID }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map { $0.itemID }
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map { $0.itemID }
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        guard let pane = Pane.allCases.first(where: { $0.itemID == sender.itemIdentifier }) else { return }
        select(pane, animated: true)
    }

    // MARK: - Pane swap

    private func setupContainer() {
        container.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView = container
    }

    private func buildPanes() {
        paneViews[.general] = GeneralPaneView()
        paneViews[.storage] = StoragePaneView(coordinator: coordinator) { [weak self] in
            self?.refreshDailyPaneState()
        }
        paneViews[.daily]   = DailyNotePaneView(coordinator: coordinator)
    }

    private func refreshDailyPaneState() {
        (paneViews[.daily] as? DailyNotePaneView)?.refresh()
    }

    private func select(_ pane: Pane, animated: Bool) {
        current = pane
        guard let view = paneViews[pane], let window = window else { return }

        for sub in container.subviews { sub.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        // Refresh dynamic state on each open so the radio reflects current settings.
        if let storage = view as? StoragePaneView { storage.refresh() }
        if let daily   = view as? DailyNotePaneView { daily.refresh() }

        let target = view.fittingSize
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: target))
        var newFrame = window.frame
        newFrame.origin.y += newFrame.size.height - frame.size.height
        newFrame.size = frame.size
        window.setFrame(newFrame, display: true, animate: animated)
        window.title = pane.title

        window.toolbar?.selectedItemIdentifier = pane.itemID
    }

    // MARK: - Public

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        (paneViews[.storage] as? StoragePaneView)?.refresh()
        (paneViews[.daily]   as? DailyNotePaneView)?.refresh()
        (paneViews[.general] as? GeneralPaneView)?.refresh()
    }
}

// MARK: - General

private final class GeneralPaneView: NSView {

    private let launchToggle = NSButton(checkboxWithTitle: "Launch at login",
                                        target: nil, action: nil)
    private let colorRow = NSStackView()
    private var colorButtons: [NoteColor: NSButton] = [:]

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        launchToggle.target = self
        launchToggle.action = #selector(toggleLaunch)
        launchToggle.translatesAutoresizingMaskIntoConstraints = false

        let colorLabel = SectionLabel(text: "Default note color")
        colorRow.translatesAutoresizingMaskIntoConstraints = false
        colorRow.orientation = .horizontal
        colorRow.spacing = 8
        for color in NoteColor.allCases {
            let swatch = NSButton(image: Self.swatchImage(for: color, size: 22),
                                  target: self, action: #selector(pickColor(_:)))
            swatch.bezelStyle = .smallSquare
            swatch.isBordered = false
            swatch.imagePosition = .imageOnly
            swatch.toolTip = color.displayName
            swatch.identifier = NSUserInterfaceItemIdentifier(color.rawValue)
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.widthAnchor.constraint(equalToConstant: 28).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 28).isActive = true
            colorButtons[color] = swatch
            colorRow.addArrangedSubview(swatch)
        }

        let shortcutsLabel = SectionLabel(text: "Keyboard shortcuts")
        let newNoteRow = recorderRow(title: "New note",
                                     name: .newNote,
                                     recorder: KeyboardShortcuts.RecorderCocoa(for: .newNote))
        let findRow    = recorderRow(title: "Find note",
                                     name: .quickSwitcher,
                                     recorder: KeyboardShortcuts.RecorderCocoa(for: .quickSwitcher))
        let clipRow    = recorderRow(title: "New note from clipboard",
                                     name: .newFromClipboard,
                                     recorder: KeyboardShortcuts.RecorderCocoa(for: .newFromClipboard))
        let panelRow   = recorderRow(title: "Show notes panel",
                                     name: .notesPanel,
                                     recorder: KeyboardShortcuts.RecorderCocoa(for: .notesPanel))
        let hideRow    = recorderRow(title: "Hide all notes",
                                     name: .hideAll,
                                     recorder: KeyboardShortcuts.RecorderCocoa(for: .hideAll))

        let stack = NSStackView(views: [
            launchToggle,
            colorLabel, colorRow,
            shortcutsLabel, newNoteRow, clipRow, findRow, panelRow, hideRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(20, after: launchToggle)
        stack.setCustomSpacing(6, after: colorLabel)
        stack.setCustomSpacing(20, after: colorRow)
        stack.setCustomSpacing(6, after: shortcutsLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -20),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 480)
        ])
    }

    /// A recorder row, plus a line naming what else commonly uses the chord.
    /// The hint updates as the shortcut is re-recorded.
    private func recorderRow(title: String,
                             name: KeyboardShortcuts.Name,
                             recorder: KeyboardShortcuts.RecorderCocoa) -> NSView {
        let row = recorderRow(title: title, recorder: recorder)

        let hint = NSTextField(labelWithString: "")
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor

        func refreshHint() {
            let note = HotkeyAdvice.conflictNote(for: HotkeyAdvice.describe(name))
            hint.stringValue = note ?? ""
            hint.isHidden = note == nil
        }
        refreshHint()
        // The recorder doesn't expose a change hook, so refresh when the
        // window comes back to the front — which is when a rebind is done.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in refreshHint() }

        let stack = NSStackView(views: [row, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Line the hint up under the recorder rather than the right-aligned
        // label, so it reads as belonging to the shortcut.
        hint.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 148).isActive = true
        return stack
    }

    private func recorderRow(title: String, recorder: KeyboardShortcuts.RecorderCocoa) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 140).isActive = true

        recorder.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [label, recorder])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .firstBaseline
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    func refresh() {
        launchToggle.state = LaunchAgent.isEnabled ? .on : .off
        launchToggle.isEnabled = LaunchAgent.isAvailable
        launchToggle.toolTip = LaunchAgent.isAvailable
            ? nil
            : "Available only when launched from the bundled .app"

        let current = Settings.shared.defaultNoteColor
        for (color, button) in colorButtons {
            button.image = Self.swatchImage(for: color, size: 22, selected: color == current)
        }
    }

    @objc private func toggleLaunch() {
        let target = launchToggle.state == .on
        if let error = LaunchAgent.setEnabled(target) {
            let alert = NSAlert()
            alert.messageText = "Couldn't update Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            launchToggle.state = LaunchAgent.isEnabled ? .on : .off
            return
        }

        // Registering can succeed and still leave the app switched off, if the
        // user disabled it in System Settings before. The checkbox would then
        // claim it's on when it isn't, and only System Settings can fix it.
        if target && LaunchAgent.needsApproval {
            launchToggle.state = .off
            let alert = NSAlert()
            alert.messageText = "Sticky Notes is turned off in Login Items"
            alert.informativeText = "Switch Sticky Notes on under Login Items in System Settings to launch it at login."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = LaunchAgent.loginItemsSettingsURL {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func pickColor(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let color = NoteColor(rawValue: raw) else { return }
        Settings.shared.defaultNoteColor = color
        refresh()
    }

    private static func swatchImage(for color: NoteColor, size: CGFloat, selected: Bool = false) -> NSImage {
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = rect.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: inset, xRadius: 5, yRadius: 5)
            NSColor(hex: color.bodyHex)?.setFill()
            path.fill()

            if selected {
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75),
                                        xRadius: 6, yRadius: 6)
                NSColor.controlAccentColor.setStroke()
                ring.lineWidth = 2
                ring.stroke()
            } else {
                NSColor.black.withAlphaComponent(0.18).setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }
            return true
        }
    }
}

// MARK: - Storage

private final class StoragePaneView: NSView {

    private weak var coordinator: SettingsCoordinator?
    private let onChange: () -> Void

    private let localRadio  = NSButton(radioButtonWithTitle: "On this Mac",
                                       target: nil, action: nil)
    private let iCloudRadio = NSButton(radioButtonWithTitle: "iCloud Drive",
                                       target: nil, action: nil)
    private let vaultRadio  = NSButton(radioButtonWithTitle: "Obsidian vault",
                                       target: nil, action: nil)

    private let localHelp  = HelpLabel(text: "~/Library/Application Support/StickyNotes")
    private let iCloudHelp = HelpLabel(text: "iCloud Drive/StickyNotes")
    private let vaultHelp  = HelpLabel(text: "Notes saved as Markdown under <vault>/StickyNotes/")

    private let vaultPathField = NSTextField(string: "")
    private let chooseVaultButton = NSButton(title: "Choose…", target: nil, action: nil)

    private let footerLabel = NSTextField(labelWithString: "")
    private let revealButton = NSButton(title: "Reveal in Finder",
                                        target: nil, action: nil)

    init(coordinator: SettingsCoordinator?, onChange: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        [localRadio, iCloudRadio, vaultRadio].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.target = self
            $0.action = #selector(radioChanged(_:))
        }
        localRadio.identifier  = NSUserInterfaceItemIdentifier("local")
        iCloudRadio.identifier = NSUserInterfaceItemIdentifier("icloud")
        vaultRadio.identifier  = NSUserInterfaceItemIdentifier("vault")

        vaultPathField.translatesAutoresizingMaskIntoConstraints = false
        vaultPathField.placeholderString = "/path/to/vault"
        vaultPathField.isEditable = false
        vaultPathField.isSelectable = true
        vaultPathField.isBezeled = true
        vaultPathField.bezelStyle = .roundedBezel
        vaultPathField.lineBreakMode = .byTruncatingMiddle

        chooseVaultButton.translatesAutoresizingMaskIntoConstraints = false
        chooseVaultButton.target = self
        chooseVaultButton.action = #selector(chooseVault)
        chooseVaultButton.bezelStyle = .rounded

        let vaultIndent = NSView()
        vaultIndent.translatesAutoresizingMaskIntoConstraints = false
        vaultIndent.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let vaultRow = NSStackView(views: [vaultIndent, vaultPathField, chooseVaultButton])
        vaultRow.orientation = .horizontal
        vaultRow.spacing = 8
        vaultRow.translatesAutoresizingMaskIntoConstraints = false
        vaultRow.distribution = .fill
        vaultPathField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let local = optionGroup(radio: localRadio, help: localHelp, extra: nil)
        let cloud = optionGroup(radio: iCloudRadio, help: iCloudHelp, extra: nil)
        let vault = optionGroup(radio: vaultRadio, help: vaultHelp, extra: vaultRow)

        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.font = NSFont.systemFont(ofSize: 11)
        footerLabel.textColor = NSColor.secondaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingMiddle
        footerLabel.maximumNumberOfLines = 1

        revealButton.translatesAutoresizingMaskIntoConstraints = false
        revealButton.target = self
        revealButton.action = #selector(reveal)
        revealButton.bezelStyle = .rounded
        revealButton.controlSize = .small

        let footerRow = NSStackView(views: [footerLabel, revealButton])
        footerRow.orientation = .horizontal
        footerRow.spacing = 10
        footerRow.alignment = .firstBaseline
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        revealButton.setContentHuggingPriority(.required, for: .horizontal)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            SectionLabel(text: "Where notes are stored"),
            local, cloud, vault,
            separator,
            footerRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(8, after: stack.arrangedSubviews[0])
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -20),
            separator.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            vaultRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            footerRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 480)
        ])
    }

    private func optionGroup(radio: NSButton, help: HelpLabel, extra: NSView?) -> NSView {
        // Indent the help text under the radio's title using a fixed-width
        // spacer so the inner stack's intrinsic width stays predictable —
        // explicit leading constraints would fight NSStackView's own
        // alignment-derived constraints.
        let helpIndent = NSView()
        helpIndent.translatesAutoresizingMaskIntoConstraints = false
        helpIndent.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let helpRow = NSStackView(views: [helpIndent, help])
        helpRow.orientation = .horizontal
        helpRow.alignment = .firstBaseline
        helpRow.spacing = 0
        helpRow.translatesAutoresizingMaskIntoConstraints = false

        var views: [NSView] = [radio, helpRow]
        if let extra = extra { views.append(extra) }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    func refresh() {
        let vaultPath = Settings.shared.obsidianVaultPath
        let useICloud = Settings.shared.useICloud
        let icloudOK  = Settings.iCloudAvailable

        if vaultPath != nil {
            vaultRadio.state = .on
            localRadio.state = .off
            iCloudRadio.state = .off
        } else if useICloud && icloudOK {
            iCloudRadio.state = .on
            localRadio.state = .off
            vaultRadio.state = .off
        } else {
            localRadio.state = .on
            iCloudRadio.state = .off
            vaultRadio.state = .off
        }

        iCloudRadio.isEnabled = icloudOK
        iCloudHelp.stringValue = icloudOK
            ? "iCloud Drive/StickyNotes"
            : "iCloud Drive not available on this machine"

        vaultPathField.stringValue = vaultPath ?? ""
        chooseVaultButton.title = vaultPath == nil ? "Choose…" : "Change…"

        footerLabel.stringValue = "Current: \(Settings.preferredStorageRoot.path)"
    }

    @objc private func radioChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        switch id {
        case "local":
            coordinator?.applyStorageMode(.local)
        case "icloud":
            coordinator?.applyStorageMode(.iCloud)
        case "vault":
            if let existing = Settings.shared.obsidianVaultPath {
                coordinator?.applyStorageMode(.vault(path: existing))
            } else {
                presentVaultPicker()
            }
        default:
            break
        }
        refresh()
        onChange()
    }

    @objc private func chooseVault() {
        presentVaultPicker()
    }

    private func presentVaultPicker() {
        let panel = NSOpenPanel()
        panel.title = "Choose Obsidian Vault"
        panel.message = "Pick the root folder of your Obsidian vault. Notes will be stored as Markdown files under \"<vault>/StickyNotes/\"."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Vault"
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        if response == .OK, let url = panel.urls.first {
            coordinator?.applyStorageMode(.vault(path: url.path))
        }
        refresh()
        onChange()
    }

    @objc private func reveal() {
        coordinator?.revealStorageFolder()
    }
}

// MARK: - Daily Note

private final class DailyNotePaneView: NSView {

    private weak var coordinator: SettingsCoordinator?

    private let unavailableLabel = NSTextField(labelWithString: "")
    private let formStack = NSStackView()

    private let patternField = NSTextField(string: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let tokenLabel = NSTextField(labelWithString: "")

    private let templateField = NSTextField(string: "")
    private let chooseTemplateButton = NSButton(title: "Choose…",
                                                target: nil, action: nil)
    private let clearTemplateButton  = NSButton(title: "Clear",
                                                target: nil, action: nil)

    private let openTodayButton = NSButton(title: "Open Today's Note",
                                           target: nil, action: nil)

    init(coordinator: SettingsCoordinator?) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        unavailableLabel.translatesAutoresizingMaskIntoConstraints = false
        unavailableLabel.stringValue = "Daily notes need an Obsidian vault. Set one in Storage."
        unavailableLabel.textColor = NSColor.secondaryLabelColor
        unavailableLabel.font = NSFont.systemFont(ofSize: 12)
        unavailableLabel.maximumNumberOfLines = 0
        unavailableLabel.preferredMaxLayoutWidth = 440

        patternField.translatesAutoresizingMaskIntoConstraints = false
        patternField.placeholderString = "Daily/{YYYY}-{MM}-{DD}.md"
        patternField.target = self
        patternField.action = #selector(patternCommitted)
        if let cell = patternField.cell as? NSTextFieldCell {
            cell.sendsActionOnEndEditing = true
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(patternChanged),
            name: NSControl.textDidChangeNotification,
            object: patternField
        )

        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.font = NSFont.systemFont(ofSize: 11)
        previewLabel.textColor = NSColor.secondaryLabelColor
        previewLabel.maximumNumberOfLines = 1

        tokenLabel.translatesAutoresizingMaskIntoConstraints = false
        tokenLabel.stringValue = "Tokens: {YYYY} {YY} {MM} {M} {DD} {D} {dddd} {ddd}"
        tokenLabel.font = NSFont.systemFont(ofSize: 11)
        tokenLabel.textColor = NSColor.tertiaryLabelColor
        tokenLabel.maximumNumberOfLines = 1

        templateField.translatesAutoresizingMaskIntoConstraints = false
        templateField.isEditable = false
        templateField.isSelectable = true
        templateField.isBezeled = true
        templateField.bezelStyle = .roundedBezel
        templateField.placeholderString = "(no template — write directly)"
        templateField.lineBreakMode = .byTruncatingMiddle

        chooseTemplateButton.translatesAutoresizingMaskIntoConstraints = false
        chooseTemplateButton.target = self
        chooseTemplateButton.action = #selector(chooseTemplate)
        chooseTemplateButton.bezelStyle = .rounded

        clearTemplateButton.translatesAutoresizingMaskIntoConstraints = false
        clearTemplateButton.target = self
        clearTemplateButton.action = #selector(clearTemplate)
        clearTemplateButton.bezelStyle = .rounded

        let templateRow = NSStackView(views: [templateField, chooseTemplateButton, clearTemplateButton])
        templateRow.orientation = .horizontal
        templateRow.spacing = 8
        templateRow.translatesAutoresizingMaskIntoConstraints = false
        templateField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        openTodayButton.translatesAutoresizingMaskIntoConstraints = false
        openTodayButton.target = self
        openTodayButton.action = #selector(openToday)
        openTodayButton.bezelStyle = .rounded

        formStack.translatesAutoresizingMaskIntoConstraints = false
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 6

        formStack.addArrangedSubview(SectionLabel(text: "Path pattern (relative to vault)"))
        formStack.addArrangedSubview(patternField)
        formStack.addArrangedSubview(previewLabel)
        formStack.addArrangedSubview(tokenLabel)
        formStack.setCustomSpacing(18, after: tokenLabel)
        formStack.addArrangedSubview(SectionLabel(text: "Template file"))
        formStack.addArrangedSubview(templateRow)
        formStack.setCustomSpacing(18, after: templateRow)
        formStack.addArrangedSubview(openTodayButton)

        addSubview(formStack)
        addSubview(unavailableLabel)

        NSLayoutConstraint.activate([
            formStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            formStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            formStack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            formStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -20),

            patternField.trailingAnchor.constraint(equalTo: formStack.trailingAnchor),
            templateRow.trailingAnchor.constraint(equalTo: formStack.trailingAnchor),

            unavailableLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            unavailableLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            unavailableLabel.topAnchor.constraint(equalTo: topAnchor, constant: 20),

            widthAnchor.constraint(greaterThanOrEqualToConstant: 480)
        ])
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func refresh() {
        let vaultActive = Settings.shared.obsidianVaultPath != nil

        unavailableLabel.isHidden = vaultActive
        formStack.isHidden = !vaultActive

        guard vaultActive else { return }

        let pattern = Settings.shared.dailyNotesPattern ?? ""
        if patternField.stringValue != pattern {
            patternField.stringValue = pattern
        }
        updatePreview()

        if let path = Settings.shared.dailyTemplatePath {
            templateField.stringValue = path
            clearTemplateButton.isEnabled = true
        } else {
            templateField.stringValue = ""
            clearTemplateButton.isEnabled = false
        }

        openTodayButton.isEnabled = !pattern.isEmpty
    }

    private func updatePreview() {
        let value = patternField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            previewLabel.stringValue = "Daily note disabled."
        } else {
            previewLabel.stringValue = "Today: \(DailyNote.render(value, date: Date()))"
        }
    }

    @objc private func patternChanged() {
        updatePreview()
    }

    @objc private func patternCommitted() {
        let value = patternField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        coordinator?.applyDailyPattern(value.isEmpty ? nil : value)
        refresh()
    }

    @objc private func chooseTemplate() {
        guard let vault = Settings.shared.obsidianVaultPath else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Daily Note Template"
        panel.message = "Pick the markdown template applied when today's daily note doesn't exist yet."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        panel.directoryURL = URL(fileURLWithPath: vault, isDirectory: true)
        panel.prompt = "Use This Template"

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }

        let vaultPrefix = (vault as NSString).appendingPathComponent("") + "/"
        let chosen = url.path
        let stored = chosen.hasPrefix(vaultPrefix) ? String(chosen.dropFirst(vaultPrefix.count)) : chosen
        coordinator?.applyDailyTemplate(stored)
        refresh()
    }

    @objc private func clearTemplate() {
        coordinator?.applyDailyTemplate(nil)
        refresh()
    }

    @objc private func openToday() {
        // Commit any unsaved pattern edits before opening.
        patternCommitted()
        coordinator?.openTodaysDailyNote()
    }
}

// MARK: - Small UI bits

private final class SectionLabel: NSTextField {
    init(text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stringValue = text
        font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        textColor = NSColor.secondaryLabelColor
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class HelpLabel: NSTextField {
    init(text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stringValue = text
        font = NSFont.systemFont(ofSize: 11)
        textColor = NSColor.secondaryLabelColor
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
        maximumNumberOfLines = 0
        preferredMaxLayoutWidth = 420
    }
    required init?(coder: NSCoder) { fatalError() }
}
