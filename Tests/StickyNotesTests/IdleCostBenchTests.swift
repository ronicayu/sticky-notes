import AppKit
import XCTest
@testable import StickyNotesKit

/// What the app costs while nobody is looking at the notes panel: 40 notes open
/// on the desk, the panel created and then closed, and a note saved the way a
/// pause in typing saves it. A benchmark, not an assertion: it prints disk reads
/// and CPU time per save, with and without the panel, so a change can be
/// compared before and after. Skipped unless `STICKY_BENCH=1` is set:
/// `STICKY_BENCH=1 xctest .build/out/Products/Debug/StickyNotesTests.xctest -XCTest StickyNotesTests.IdleCostBenchTests`
@MainActor final class IdleCostBenchTests: XCTestCase {
    private var root: URL!
    private var isolated: IsolatedSettings!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IdleCost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        isolated = IsolatedSettings()
    }

    override func tearDown() async throws {
        isolated.tearDown()
        try? FileManager.default.removeItem(at: root)
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private func drainMainQueue() {
        for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func makeDesk(notes: Int) throws -> (DeskController, NoteStore, [Note]) {
        let store = NoteStore(rootURL: root)
        for index in 0..<notes {
            var note = Note.makeNew(frame: NSRect(x: 40, y: 40, width: 240, height: 200), now: Date())
            note.title = "Note \(index)"
            note.content = "body of note \(index)\n- [ ] one\n- [ ] two\nsome more text to read"
            store.save(note)
        }
        let clock = ManualClock()
        let desk = DeskController(
            store: store, settings: isolated.settings, clock: clock, undo: UndoCenter(clock: clock),
            recovery: RecoveryFiles(settings: isolated.settings, store: store, clock: clock)
        )
        let loaded = store.loadActive()
        for note in loaded { desk.presentWindow(for: note, activate: false) }
        XCTAssertEqual(desk.windowControllers.count, notes)
        return (desk, store, loaded)
    }

    private func measureSaves(store: NoteStore, notes: [Note], count: Int) -> (reads: Double, cpuMs: Double, wallMs: Double) {
        var note = notes[0]
        let readsBefore = store.readCount
        let cpuBefore = cpuSeconds()
        let wallBefore = CFAbsoluteTimeGetCurrent()
        for index in 0..<count {
            note.content += "x"
            note.updatedAt = Date().addingTimeInterval(Double(index))
            store.save(note)
            drainMainQueue()
        }
        let wall = (CFAbsoluteTimeGetCurrent() - wallBefore) * 1000 / Double(count)
        let cpu = (cpuSeconds() - cpuBefore) * 1000 / Double(count)
        // The drain's own 30 ms of waiting is not CPU, so only the CPU figure is a cost.
        return (Double(store.readCount - readsBefore) / Double(count), cpu, wall)
    }

    func testBenchmarkSavesWithFortyNotesOpenAndTheNotesPanelHidden() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STICKY_BENCH"] == "1", "set STICKY_BENCH=1 to run")
        let (desk, store, notes) = try makeDesk(notes: 40)
        _ = measureSaves(store: store, notes: notes, count: 60)

        let without = measureSaves(store: store, notes: notes, count: 60)

        desk.showNotesPanel()
        let panel = try XCTUnwrap(desk.notesPanel)
        panel.window?.orderOut(nil)
        XCTAssertEqual(panel.window?.isVisible, false)
        _ = measureSaves(store: store, notes: notes, count: 20)
        let reloadsBefore = panel.reloadCount
        let first = measureSaves(store: store, notes: notes, count: 60)
        let second = measureSaves(store: store, notes: notes, count: 60)

        print(String(format: "  idle cost per save, 40 notes open, no panel:        %.2f disk reads, %.2f ms CPU",
                     without.reads, without.cpuMs))
        print(String(format: "  idle cost per save, 40 notes open, panel hidden #1: %.2f disk reads, %.2f ms CPU",
                     first.reads, first.cpuMs))
        print(String(format: "  idle cost per save, 40 notes open, panel hidden #2: %.2f disk reads, %.2f ms CPU; panel reloaded %d times in 120 saves",
                     second.reads, second.cpuMs, panel.reloadCount - reloadsBefore))
        desk.windowControllers.values.forEach { $0.window?.close() }
    }
}
