import AppKit
import XCTest
@testable import StickyNotesKit

/// The sweep for sync conflict versions runs after the windows are up, asks the
/// file system on another queue and changes notes only on the main one.
@MainActor final class ConflictSweepAtLaunchTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var isolated: IsolatedSettings!
    private var clock: ManualClock!
    private var delegate: AppDelegate?

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConflictSweepAtLaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(rootURL: root.appendingPathComponent("notes-root"))
        isolated = IsolatedSettings()
        clock = ManualClock()
    }

    override func tearDown() async throws {
        store?.stopWatching()
        delegate?.desk.windowControllers.values.forEach { $0.window?.close() }
        delegate = nil
        isolated.tearDown()
        try? FileManager.default.removeItem(at: root)
    }

    private func seed(_ content: String) -> Note {
        var note = Note.makeNew(frame: NSRect(x: 40, y: 40, width: 240, height: 200), now: clock.now())
        note.content = content
        store.save(note)
        return note
    }

    /// A conflict version of `note`: a real file holding `content`, read as a
    /// downloaded `NSFileVersion` would be.
    private func conflictVersion(of note: Note, content: String) throws -> NoteStore.ConflictVersionHandle {
        let url = root.appendingPathComponent("version-\(UUID().uuidString).md")
        let text = "---\nid: \(note.id.uuidString)\nupdated: 1970-01-01T00:00:01Z\n---\n\(content)\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return .init(url: url, markResolved: {})
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var mainThreadCount = 0
        func increment() {
            lock.lock(); defer { lock.unlock() }
            count += 1
            if Thread.isMainThread { mainThreadCount += 1 }
        }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        var calledOnMain: Int { lock.lock(); defer { lock.unlock() }; return mainThreadCount }
    }

    private func fileText(of note: Note) throws -> String {
        let files = try FileManager.default.contentsOfDirectory(at: store.activeURL, includingPropertiesForKeys: nil)
        let match = try XCTUnwrap(files.first { (try? String(contentsOf: $0, encoding: .utf8))?.contains(note.id.uuidString) == true })
        return try String(contentsOf: match, encoding: .utf8)
    }

    private func nextExternalChange() -> XCTestExpectation {
        expectation(forNotification: NoteStore.didChange, object: store) { notification in
            if case .external = NoteStore.change(in: notification) { return true }
            return false
        }
    }

    func testTheSweepRunsAfterTheFirstWindowAndTheMergedTextReachesTheOpenWindow() async throws {
        let note = seed("shared line")
        _ = seed("another note")
        _ = seed("a third note")
        let version = try conflictVersion(of: note, content: "shared line\nonly in the conflict version")
        let asked = Counter()
        let conflicted = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: store.activeURL, includingPropertiesForKeys: nil)
                .first { (try? String(contentsOf: $0, encoding: .utf8))?.contains("shared line") == true })
        store.conflictVersionsProvider = { url in
            asked.increment()
            return url.lastPathComponent == conflicted.lastPathComponent ? [version] : []
        }
        store.otherVersionsRemover = { _ in }
        let merged = nextExternalChange()

        let app = AppDelegate(store: store, settings: isolated.settings, clock: clock)
        delegate = app
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let controller = try XCTUnwrap(app.desk.windowControllers[note.id], "the window must open first")
        XCTAssertFalse(try fileText(of: note).contains("only in the conflict version"))
        XCTAssertFalse(controller.textView.string.contains("only in the conflict version"))

        await fulfillment(of: [merged], timeout: 10)

        XCTAssertGreaterThanOrEqual(asked.value, 3, "every note is asked about")
        XCTAssertEqual(asked.calledOnMain, 1, "only the note that has a conflict is asked about again on the main thread")
        XCTAssertTrue(try fileText(of: note).contains("only in the conflict version"))
        XCTAssertTrue(controller.textView.string.contains("only in the conflict version"), controller.textView.string)
    }

    func testTheFlushBeforeAMergeStillRunsOnTheMainThread() async throws {
        let note = seed("shared line")
        let version = try conflictVersion(of: note, content: "shared line\nfrom the other Mac")
        store.conflictVersionsProvider = { _ in [version] }
        store.otherVersionsRemover = { _ in }
        var hookRanOnMain: [Bool] = []
        store.beforeResolvingConflicts = { _ in hookRanOnMain.append(Thread.isMainThread); return true }
        let finished = expectation(description: "sweep finished")
        var merged = 0

        store.resolveConflictsInBackground { merged = $0; finished.fulfill() }
        await fulfillment(of: [finished], timeout: 10)

        XCTAssertEqual(merged, 1)
        XCTAssertEqual(hookRanOnMain, [true])
    }

    func testASweepThatWasStartedBeforeTheStorageMovedChangesNothing() async throws {
        let note = seed("shared line")
        let version = try conflictVersion(of: note, content: "shared line\nfrom the other Mac")
        store.conflictVersionsProvider = { _ in [version] }
        store.otherVersionsRemover = { _ in }
        let originalFile = try fileText(of: note)
        let finished = expectation(description: "sweep finished")
        var merged = -1

        store.resolveConflictsInBackground { merged = $0; finished.fulfill() }
        store.reconfigure(rootURL: root.appendingPathComponent("elsewhere"))
        await fulfillment(of: [finished], timeout: 10)

        XCTAssertEqual(merged, 0)
        let oldFiles = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("notes-root/notes"), includingPropertiesForKeys: nil)
        let oldText = try String(contentsOf: XCTUnwrap(oldFiles.first { $0.pathExtension == "md" }), encoding: .utf8)
        XCTAssertEqual(oldText, originalFile, "the root that was left must not be rewritten")
    }
}
