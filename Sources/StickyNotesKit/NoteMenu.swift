import AppKit

/// The Note menu: what the mouse-only chrome of a note does, on the keyboard.
/// The app has no menu bar to show it in, but its key equivalents still run
/// from the main menu. Every item acts on the note whose window is key and is
/// disabled when none is, so ⌘W in Settings or the daily note does nothing here.
/// Each action calls the same method as the matching chrome button.
///
/// Items name this object as their target and ask `keyNote` which note to act
/// on, rather than going to the first responder. A note window cannot become
/// key in a test, and the daily note, Settings and the panel are key windows
/// that must see these items disabled, which a responder chain would leave to
/// whichever object up the chain answers the selector.
@MainActor final class NoteMenu: NSObject, NSMenuItemValidation {
    private let keyNote: () -> NoteWindowController?
    private let canCycle: () -> Bool
    private let cycle: (Int) -> Void
    private let currentEvent: () -> NSEvent?

    /// `canCycle` and `cycle` walk the desk's visible note windows. `currentEvent`
    /// is the event that is running an action, for telling a held key from a press.
    init(
        keyNote: @escaping () -> NoteWindowController?,
        canCycle: @escaping () -> Bool = { false },
        cycle: @escaping (Int) -> Void = { _ in },
        currentEvent: (() -> NSEvent?)? = nil
    ) {
        self.keyNote = keyNote
        self.canCycle = canCycle
        self.cycle = cycle
        self.currentEvent = currentEvent ?? { NSApp.currentEvent }
        super.init()
    }

    /// A held key repeats its key equivalent. Archiving, collapsing and floating
    /// would flip back and forth, or archive the next note, so only the press counts.
    private var isKeyRepeat: Bool {
        guard let event = currentEvent(), event.type == .keyDown else { return false }
        return event.isARepeat
    }

    /// ⌘1…⌘7 pick the colours in the order the colour menu lists them.
    static let colors = NoteColor.allCases

    /// The submenu for the main menu's "Note" item. Items name this object as
    /// their target, so the caller must keep the object alive as long as the menu.
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Note")

        add("Find in Note", #selector(find), key: "f", to: menu)
        add("Labels…", #selector(showLabels), key: "l", modifiers: [.command, .option], to: menu)
        menu.addItem(.separator())

        for (index, color) in NoteMenu.colors.enumerated() {
            let item = add(color.displayName, #selector(pickColor(_:)), key: String(index + 1), to: menu)
            item.tag = index
            item.image = NoteWindowController.colorSwatch(for: color)
        }
        menu.addItem(.separator())

        add("Float on Top", #selector(toggleFloat), key: "f", modifiers: [.command, .option], to: menu)
        add("Collapse", #selector(toggleCollapse), key: "m", to: menu)
        menu.addItem(.separator())
        add("Archive", #selector(archive), key: "w", to: menu)
        menu.addItem(.separator())
        add("Next Note", #selector(nextNote), key: "`", to: menu)
        add("Previous Note", #selector(previousNote), key: "~", modifiers: [.command, .shift], to: menu)
        return menu
    }

    @discardableResult
    private func add(
        _ title: String, _ action: Selector, key: String,
        modifiers: NSEvent.ModifierFlags = .command, to menu: NSMenu
    ) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func find() { keyNote()?.showFindBar() }
    @objc private func showLabels() { keyNote()?.showLabelMenu() }
    @objc private func toggleCollapse() {
        guard !isKeyRepeat else { return }
        keyNote()?.toggleCollapse()
    }

    @objc private func archive() {
        guard !isKeyRepeat else { return }
        keyNote()?.closeNote()
    }

    @objc private func nextNote() { cycle(1) }
    @objc private func previousNote() { cycle(-1) }

    @objc private func pickColor(_ sender: NSMenuItem) {
        guard NoteMenu.colors.indices.contains(sender.tag) else { return }
        keyNote()?.setColor(NoteMenu.colors[sender.tag])
    }

    @objc private func toggleFloat() {
        guard !isKeyRepeat, let note = keyNote() else { return }
        note.setFloatLevel(note.floatLevel == .floating ? .desktop : .floating)
    }

    // MARK: - Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(nextNote) || item.action == #selector(previousNote) {
            return canCycle()
        }
        guard let note = keyNote() else {
            item.state = .off
            return false
        }
        switch item.action {
        case #selector(pickColor(_:)):
            item.state = NoteMenu.colors.indices.contains(item.tag) && NoteMenu.colors[item.tag] == note.color ? .on : .off
            return true
        case #selector(toggleFloat):
            item.state = note.floatLevel == .floating ? .on : .off
            return true
        case #selector(toggleCollapse):
            item.state = note.isCollapsed ? .on : .off
            return true
        case #selector(find), #selector(showLabels):
            return !note.isCollapsed
        default:
            return true
        }
    }
}
