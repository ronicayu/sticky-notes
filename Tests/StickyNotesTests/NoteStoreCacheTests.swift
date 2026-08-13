import XCTest
@testable import StickyNotesKit

/// The cache exists so the notes panel, window reconcile, and label menu stop
/// re-reading the whole tree. These tests pin both halves of that: reads are
/// served from memory, and every mutation drops the cache.
final class NoteStoreCacheTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StickyNotesCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(_ format: StorageFormat = .json) -> NoteStore {
        NoteStore(rootURL: root, format: format)
    }

    private func makeNote(content: String = "n", labels: [String] = []) -> Note {
        Note(
            id: UUID(), title: "", content: content,
            positionX: 0, positionY: 0, width: 240, height: 200,
            collapsed: false, color: .yellow, labels: labels,
            createdAt: Date(), updatedAt: Date()
        )
    }

    /// Deleting the files behind the store's back and then reading again is a
    /// timing-free way to prove the read came from memory: FSEvents needs
    /// ~0.35s to notice, so a synchronous read still sees the cache.
    func testReadsAreServedFromMemoryWithoutTouchingDisk() throws {
        let store = makeStore()
        store.save(makeNote(content: "cached"))
        XCTAssertEqual(store.loadActive().count, 1, "precondition: note is on disk and loaded")

        for file in try FileManager.default.contentsOfDirectory(at: store.activeURL, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }

        XCTAssertEqual(store.loadActive().first?.content, "cached",
                       "read went to disk instead of the cache")
    }

    func testSavingANoteInvalidatesTheCache() {
        let store = makeStore()
        store.save(makeNote(content: "first"))
        XCTAssertEqual(store.loadActive().count, 1)

        store.save(makeNote(content: "second"))
        XCTAssertEqual(store.loadActive().count, 2, "cache served a stale list after a save")
    }

    func testArchivingInvalidatesBothActiveAndArchivedCaches() {
        let store = makeStore()
        let note = makeNote()
        store.save(note)
        _ = store.loadActive()
        _ = store.loadArchived()

        store.archive(note)
        XCTAssertTrue(store.loadActive().isEmpty, "stale active cache after archive")
        XCTAssertEqual(store.loadArchived().count, 1, "stale archive cache after archive")
    }

    func testRestoringInvalidatesBothCaches() {
        let store = makeStore()
        let note = makeNote()
        store.save(note)
        store.archive(note)
        _ = store.loadActive()
        _ = store.loadArchived()

        store.restore(note)
        XCTAssertEqual(store.loadActive().count, 1, "stale active cache after restore")
        XCTAssertTrue(store.loadArchived().isEmpty, "stale archive cache after restore")
    }

    func testDiscardAndDeleteInvalidateTheCache() {
        let store = makeStore()
        let a = makeNote(content: "a")
        let b = makeNote(content: "b")
        store.save(a)
        store.save(b)
        _ = store.loadActive()

        store.discardActive(a)
        XCTAssertEqual(store.loadActive().map(\.content), ["b"], "stale cache after discard")

        store.archive(b)
        _ = store.loadArchived()
        store.deleteForever(b)
        XCTAssertTrue(store.loadArchived().isEmpty, "stale cache after delete")
    }

    func testReconfigureInvalidatesTheCache() {
        let store = makeStore(.json)
        store.save(makeNote(content: "moved"))
        _ = store.loadActive()

        store.reconfigure(rootURL: root.appendingPathComponent("vault", isDirectory: true), format: .markdown)
        XCTAssertEqual(store.loadActive().map(\.content), ["moved"],
                       "cache from the old root leaked into the new one")
    }

    func testAllLabelsReflectsChangesImmediately() {
        let store = makeStore()
        let note = makeNote(labels: ["work"])
        store.save(note)
        XCTAssertEqual(store.allLabels(), ["work"])

        store.save(makeNote(labels: ["home"]))
        XCTAssertEqual(store.allLabels(), ["home", "work"], "stale label cache")
    }

    func testRepeatedReadsReturnEqualResults() {
        let store = makeStore()
        for i in 0..<10 { store.save(makeNote(content: "n\(i)", labels: ["l\(i % 3)"])) }

        let first = store.loadActive().map(\.id).sorted { $0.uuidString < $1.uuidString }
        let second = store.loadActive().map(\.id).sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(first, second)
        XCTAssertEqual(store.allLabels(), store.allLabels())
    }

    // MARK: - Acceptance: a large library stays responsive

    func testPanelSizedLibraryReadsAreFastOnceWarm() {
        let store = makeStore(.markdown)
        for i in 0..<500 {
            store.save(makeNote(content: "note \(i)\n\nsome body text", labels: ["label\(i % 20)"]))
        }

        let coldStart = CFAbsoluteTimeGetCurrent()
        let cold = store.loadActive()
        let coldElapsed = CFAbsoluteTimeGetCurrent() - coldStart
        XCTAssertEqual(cold.count, 500)

        let warmStart = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 { _ = store.loadActive() }
        let warmElapsed = (CFAbsoluteTimeGetCurrent() - warmStart) / 20

        XCTAssertLessThan(warmElapsed, coldElapsed / 5,
                          "warm read (\(warmElapsed)s) should be far cheaper than a full rescan (\(coldElapsed)s)")
        XCTAssertLessThan(warmElapsed, 0.005, "a warm read of 500 notes should be effectively free")
    }

    /// Markdown filenames aren't derivable from the note id, so a lookup miss
    /// used to fall back to reading every file in the directory — making the
    /// Nth save in a vault cost N-1 file reads. Saving 500 notes took ~30s.
    func testSavingIntoALargeVaultStaysLinear() {
        let store = makeStore(.markdown)

        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<500 { store.save(makeNote(content: "note \(i)")) }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertEqual(store.loadActive().count, 500)
        XCTAssertLessThan(elapsed, 3.0,
                          "500 saves took \(elapsed)s — the per-save directory scan is back")
    }

    func testAllLabelsOverALargeLibraryDoesNotRescanPerCall() {
        let store = makeStore(.markdown)
        for i in 0..<500 { store.save(makeNote(labels: ["label\(i % 20)"])) }

        _ = store.allLabels()  // warm both directories

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 { _ = store.allLabels() }
        let perCall = (CFAbsoluteTimeGetCurrent() - start) / 20

        XCTAssertEqual(store.allLabels().count, 20)
        XCTAssertLessThan(perCall, 0.01,
                          "allLabels reads both trees; uncached that is two full rescans per call")
    }
}
