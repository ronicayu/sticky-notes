import XCTest
@testable import StickyNotesKit

/// Storage failures used to be swallowed by `try?`, so a full disk or a
/// revoked vault permission looked exactly like a successful save. These
/// tests drive real write failures by making the notes directory read-only.
final class NoteStoreHealthTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StickyNotesHealthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Restore write permission so cleanup can remove the tree.
        if let root = root {
            try? setWritable(true, at: root.appendingPathComponent("notes", isDirectory: true))
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func setWritable(_ writable: Bool, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o755 : 0o500],
            ofItemAtPath: url.path
        )
    }

    private func makeNote(content: String = "n") -> Note {
        Note(
            id: UUID(), title: "", content: content,
            positionX: 0, positionY: 0, width: 240, height: 200,
            collapsed: false, color: .yellow, labels: [],
            createdAt: Date(), updatedAt: Date()
        )
    }

    /// Running as root defeats POSIX permissions, so skip rather than fail.
    private func skipIfPermissionsAreNotEnforced(_ store: NoteStore) throws {
        try XCTSkipIf(getuid() == 0, "running as root — directory permissions aren't enforced")
    }

    func testAHealthyStoreReportsNoFailure() {
        let store = NoteStore(rootURL: root, format: .json)
        store.save(makeNote())
        XCTAssertNil(store.lastFailure)
    }

    func testAFailedWriteIsRecordedRatherThanSwallowed() throws {
        let store = NoteStore(rootURL: root, format: .json)
        try skipIfPermissionsAreNotEnforced(store)
        try setWritable(false, at: store.activeURL)

        store.save(makeNote(content: "cannot land"))

        let failure = try XCTUnwrap(store.lastFailure, "a failed write reported success")
        XCTAssertEqual(failure.url.deletingLastPathComponent().path, store.activeURL.path)
        XCTAssertFalse(failure.fileName.isEmpty)
    }

    func testAFailedWritePostsAHealthNotification() throws {
        let store = NoteStore(rootURL: root, format: .json)
        try skipIfPermissionsAreNotEnforced(store)
        try setWritable(false, at: store.activeURL)

        expectation(forNotification: NoteStore.healthDidChange, object: store, handler: nil)
        store.save(makeNote())
        waitForExpectations(timeout: 2)
    }

    func testASubsequentSuccessfulWriteClearsTheFailure() throws {
        let store = NoteStore(rootURL: root, format: .json)
        try skipIfPermissionsAreNotEnforced(store)
        try setWritable(false, at: store.activeURL)
        store.save(makeNote())
        XCTAssertNotNil(store.lastFailure, "precondition: the write failed")

        try setWritable(true, at: store.activeURL)
        expectation(forNotification: NoteStore.healthDidChange, object: store, handler: nil)
        store.save(makeNote(content: "now it works"))
        waitForExpectations(timeout: 2)

        XCTAssertNil(store.lastFailure, "recovery should clear the warning")
        XCTAssertEqual(store.loadActive().first?.content, "now it works")
    }

    func testAFailedSaveDoesNotAppearInTheCache() throws {
        let store = NoteStore(rootURL: root, format: .json)
        try skipIfPermissionsAreNotEnforced(store)
        _ = store.loadActive()  // warm the cache

        try setWritable(false, at: store.activeURL)
        store.save(makeNote(content: "never landed"))

        XCTAssertTrue(store.loadActive().isEmpty,
                      "a note that failed to write must not be cached as if it saved")
    }

    func testAFailedSaveCanBeRetriedOnceTheProblemClears() throws {
        let store = NoteStore(rootURL: root, format: .json)
        try skipIfPermissionsAreNotEnforced(store)
        let note = makeNote(content: "eventually")

        try setWritable(false, at: store.activeURL)
        store.save(note)
        XCTAssertTrue(store.loadActive().isEmpty)

        try setWritable(true, at: store.activeURL)
        store.save(note)

        XCTAssertEqual(store.loadActive().map(\.content), ["eventually"],
                       "the note should save normally once the directory is writable again")
        XCTAssertNil(store.lastFailure)
    }

    /// The no-resurrect guard keys off ids the store has seen. A note whose
    /// first write failed was never really seen, so it must not be locked out.
    func testAFailedFirstWriteDoesNotTripTheNoResurrectGuard() throws {
        let store = NoteStore(rootURL: root, format: .markdown)
        try skipIfPermissionsAreNotEnforced(store)
        let note = makeNote(content: "first attempt failed")

        try setWritable(false, at: store.activeURL)
        store.save(note)
        try setWritable(true, at: store.activeURL)
        store.save(note)

        XCTAssertEqual(store.loadActive().map(\.content), ["first attempt failed"])
    }

    func testFailuresAreReportedInMarkdownModeToo() throws {
        let store = NoteStore(rootURL: root, format: .markdown)
        try skipIfPermissionsAreNotEnforced(store)
        try setWritable(false, at: store.activeURL)

        store.save(makeNote())
        let failure = try XCTUnwrap(store.lastFailure)
        XCTAssertTrue(failure.fileName.hasSuffix(".md"), "got \(failure.fileName)")
    }

    func testTheRetryRecreatesAMissingStorageDirectory() throws {
        let store = NoteStore(rootURL: root, format: .json)
        // Simulate the folder being moved or deleted out from under us.
        try FileManager.default.removeItem(at: store.activeURL)

        store.save(makeNote(content: "recreated"))

        XCTAssertNil(store.lastFailure, "the retry should have recreated the directory")
        XCTAssertEqual(store.loadActive().map(\.content), ["recreated"])
    }
}
