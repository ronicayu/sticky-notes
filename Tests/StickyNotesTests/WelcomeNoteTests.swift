import KeyboardShortcuts
import XCTest
@testable import StickyNotesKit

final class WelcomeNoteTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WelcomeNoteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // A real suite, so the "only ever once" flag is genuinely exercised
        // without touching the developer's own preferences.
        suiteName = "WelcomeNoteTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() -> NoteStore {
        NoteStore(rootURL: root, format: .json)
    }

    private func makeNote() -> Note {
        Note(
            id: UUID(), title: "existing", content: "x",
            positionX: 0, positionY: 0, width: 240, height: 200,
            collapsed: false, color: .yellow, labels: [],
            createdAt: Date(), updatedAt: Date()
        )
    }

    func testAFreshInstallGetsAWelcomeNote() throws {
        let store = makeStore()
        let note = try XCTUnwrap(WelcomeNote.makeIfNeeded(store: store, defaults: defaults))
        XCTAssertEqual(note.title, "Welcome")
        XCTAssertEqual(store.loadActive().count, 1, "the note should be saved, not just returned")
    }

    func testTheWelcomeNoteIsOnlyEverCreatedOnce() {
        let store = makeStore()
        XCTAssertNotNil(WelcomeNote.makeIfNeeded(store: store, defaults: defaults))
        XCTAssertNil(WelcomeNote.makeIfNeeded(store: store, defaults: defaults),
                     "a second launch should not create another")
        XCTAssertEqual(store.loadActive().count, 1)
    }

    /// Deleting it is a normal thing to do; it must not come back.
    func testDeletingTheWelcomeNoteDoesNotBringItBack() throws {
        let store = makeStore()
        let note = try XCTUnwrap(WelcomeNote.makeIfNeeded(store: store, defaults: defaults))
        store.discardActive(note)

        XCTAssertNil(WelcomeNote.makeIfNeeded(store: store, defaults: defaults))
        XCTAssertTrue(store.loadActive().isEmpty)
    }

    /// Someone upgrading from an older build already has notes — dropping a
    /// welcome note on their desk would just be noise.
    func testAnExistingLibraryGetsNoWelcomeNote() {
        let store = makeStore()
        store.save(makeNote())
        XCTAssertNil(WelcomeNote.makeIfNeeded(store: store, defaults: defaults))
        XCTAssertEqual(store.loadActive().count, 1)
    }

    func testAnArchiveOnlyLibraryAlsoCountsAsExisting() {
        let store = makeStore()
        let note = makeNote()
        store.save(note)
        store.archive(note)

        XCTAssertNil(WelcomeNote.makeIfNeeded(store: store, defaults: defaults))
        XCTAssertTrue(store.loadActive().isEmpty, "no welcome note should have been created")
    }

    func testTheWelcomeNoteIsAnOrdinaryEditableNote() throws {
        let store = makeStore()
        let note = try XCTUnwrap(WelcomeNote.makeIfNeeded(store: store, defaults: defaults))

        var edited = try XCTUnwrap(store.loadActive().first)
        edited.content = "I made this mine"
        store.save(edited)

        XCTAssertEqual(store.loadActive().first?.content, "I made this mine")
        XCTAssertEqual(store.loadActive().first?.id, note.id)
    }

    func testTheWelcomeNoteHasTasksToTickOff() throws {
        let progress = try XCTUnwrap(MarkdownEditing.checkboxProgress(in: WelcomeNote.body))
        XCTAssertGreaterThan(progress.total, 0)
        XCTAssertEqual(progress.done, 0, "nothing should start already ticked")
    }

    /// The note teaches shortcuts, so it must not teach the wrong ones. It
    /// now renders the live bindings, so this compares against exactly what
    /// the app registers rather than against a chord spelled out by hand.
    @MainActor
    func testTheAdvertisedShortcutsAreTheOnesTheAppRegisters() throws {
        let body = WelcomeNote.body
        let newNote = try XCTUnwrap(HotkeyAdvice.describe(.newNote))
        let find = try XCTUnwrap(HotkeyAdvice.describe(.quickSwitcher))
        XCTAssertTrue(body.contains(newNote), "new-note shortcut missing, got: \(body)")
        XCTAssertTrue(body.contains(find), "find-note shortcut missing, got: \(body)")
        XCTAssertTrue(newNote.contains("S"), "new-note default is \(newNote)")
        XCTAssertTrue(find.contains("F"), "find-note default is \(find)")
    }

    func testTheWelcomeNoteOpensOnScreen() throws {
        let store = makeStore()
        let note = try XCTUnwrap(WelcomeNote.makeIfNeeded(store: store, defaults: defaults))
        XCTAssertFalse(note.collapsed, "it explains things; it should not start collapsed")
        XCTAssertGreaterThan(note.width, 0)
        XCTAssertGreaterThan(note.height, 0)
    }
}
