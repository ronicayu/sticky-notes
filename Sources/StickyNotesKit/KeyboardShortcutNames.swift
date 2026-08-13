import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let newNote = Self("newNote", default: .init(.s, modifiers: [.command, .shift]))
    static let notesPanel = Self("notesPanel", default: .init(.l, modifiers: [.command, .shift]))
    static let hideAll = Self("hideAll", default: .init(.h, modifiers: [.command, .shift]))
    static let quickSwitcher = Self("quickSwitcher", default: .init(.f, modifiers: [.command, .shift]))
    static let newFromClipboard = Self("newFromClipboard", default: .init(.v, modifiers: [.command, .shift, .option]))
}
