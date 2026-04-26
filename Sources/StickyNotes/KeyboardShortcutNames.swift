import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let newNote = Self("newNote", default: .init(.s, modifiers: [.command, .shift]))
    static let notesPanel = Self("notesPanel", default: .init(.l, modifiers: [.command, .shift]))
}
