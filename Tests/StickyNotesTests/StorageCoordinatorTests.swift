import AppKit
import XCTest
@testable import StickyNotesKit

/// Storage switching and the daily-note settings, against a temp store and a
/// throwaway settings suite. Nothing here touches the real Application Support
/// folder, iCloud Drive or the user's preferences.
@MainActor final class StorageCoordinatorTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var isolated: IsolatedSettings!
    private var clock: ManualClock!
    private var desk: DeskController!
    private var storage: StorageCoordinator!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(rootURL: root.appendingPathComponent("start"))
        isolated = IsolatedSettings()
        clock = ManualClock()
        desk = DeskController(
            store: store,
            settings: isolated.settings,
            clock: clock,
            undo: UndoCenter(clock: clock),
            recovery: RecoveryFiles(settings: isolated.settings, store: store, clock: clock)
        )
        storage = StorageCoordinator(store: store, settings: isolated.settings, desk: desk)
    }

    override func tearDown() async throws {
        desk.dailyNote?.window?.close()
        isolated.tearDown()
        try? FileManager.default.removeItem(at: root)
    }

    private var vaultPath: String { root.appendingPathComponent("vault").path }

    private func seed(_ title: String) -> Note {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200), now: clock.now())
        note.title = title
        store.save(note)
        return note
    }

    func testChoosingAVaultMovesTheNotesIntoItAsMarkdownAndRemembersIt() throws {
        let note = seed("Moves")

        storage.applyStorageMode(.vault(path: vaultPath))

        XCTAssertEqual(isolated.settings.obsidianVaultPath, vaultPath)
        XCTAssertEqual(store.rootURL.path, vaultPath + "/StickyNotes")
        XCTAssertEqual(store.loadActive().map(\.id), [note.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.activeURL.path))
    }

    func testChoosingLocalStorageLeavesTheVaultAndICloud() {
        isolated.settings.obsidianVaultPath = vaultPath
        isolated.settings.useICloud = true
        let note = seed("Comes home")

        storage.applyStorageMode(.local)

        XCTAssertNil(isolated.settings.obsidianVaultPath)
        XCTAssertFalse(isolated.settings.useICloud)
        XCTAssertEqual(store.rootURL, isolated.settings.localStorageRoot)
        XCTAssertEqual(store.loadActive().map(\.id), [note.id])
    }

    func testChoosingICloudWhenItIsNotAvailableFallsBackToLocalStorage() {
        isolated.settings.useICloud = true

        storage.applyStorageMode(.iCloud)

        XCTAssertFalse(isolated.settings.useICloud)
        XCTAssertEqual(store.rootURL, isolated.settings.localStorageRoot)
    }

    func testEnteringVaultModeBringsBackADailyNoteThatWasOnScreen() throws {
        isolated.settings.obsidianVaultPath = vaultPath
        isolated.settings.dailyNotesPattern = "Daily/{YYYY}-{MM}-{DD}.md"
        try FileManager.default.createDirectory(atPath: vaultPath, withIntermediateDirectories: true)
        desk.openTodaysDailyNote()
        storage.applyStorageMode(.local)
        XCTAssertNil(desk.dailyNote)

        isolated.settings.dailyNotesPattern = "Daily/{YYYY}-{MM}-{DD}.md"
        storage.applyStorageMode(.vault(path: vaultPath))

        XCTAssertTrue(desk.isDailyNoteVisible)
    }

    func testChangingTheDailyPatternIsSavedAndClearingItTearsTheDailyNoteDown() throws {
        isolated.settings.obsidianVaultPath = vaultPath
        try FileManager.default.createDirectory(atPath: vaultPath, withIntermediateDirectories: true)
        storage.applyDailyPattern("Journal/{YYYY}-{MM}-{DD}.md")
        XCTAssertEqual(isolated.settings.dailyNotesPattern, "Journal/{YYYY}-{MM}-{DD}.md")
        desk.openTodaysDailyNote()
        XCTAssertNotNil(desk.dailyNote)

        storage.applyDailyPattern(nil)

        XCTAssertNil(isolated.settings.dailyNotesPattern)
        XCTAssertNil(desk.dailyNote)
    }

    func testChangingTheDailyTemplateIsSaved() {
        storage.applyDailyTemplate("/tmp/template.md")
        XCTAssertEqual(isolated.settings.dailyTemplatePath, "/tmp/template.md")
        storage.applyDailyTemplate(nil)
        XCTAssertNil(isolated.settings.dailyTemplatePath)
    }
}
