import AppKit
import XCTest
@testable import StickyNotesKit

/// Launch to the first note window with a large desk: the store opens, the
/// notes load, and the first window is presented. A benchmark, not an
/// assertion: it prints the times so they can be compared before and after a change.
@MainActor final class LaunchTimeTests: XCTestCase {
    private var root: URL!
    private var isolated: IsolatedSettings!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchTime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        isolated = IsolatedSettings()
    }

    override func tearDown() async throws {
        isolated.tearDown()
        try? FileManager.default.removeItem(at: root)
    }

    private func seed(count: Int) {
        let store = NoteStore(rootURL: root)
        for index in 0..<count {
            var note = Note.makeNew(frame: NSRect(x: 40, y: 40, width: 240, height: 200), now: Date())
            note.title = "Note \(index)"
            note.content = "body of note \(index)\n- [ ] one\n- [ ] two\nsome more text to read"
            store.save(note)
        }
    }

    func testBenchmarkLaunchToFirstWindowWith500Notes() throws {
        seed(count: 500)
        var samples: [TimeInterval] = []
        for _ in 0..<9 {
            let clock = ManualClock()
            let started = CFAbsoluteTimeGetCurrent()
            let store = NoteStore(rootURL: root)
            let afterInit = CFAbsoluteTimeGetCurrent() - started
            let first = try XCTUnwrap(store.loadActive().first)
            let afterLoad = CFAbsoluteTimeGetCurrent() - started
            let desk = DeskController(
                store: store, settings: isolated.settings, clock: clock, undo: UndoCenter(clock: clock),
                recovery: RecoveryFiles(settings: isolated.settings, store: store, clock: clock)
            )
            desk.presentWindow(for: first, activate: false)
            samples.append(CFAbsoluteTimeGetCurrent() - started)
            print("  phases ms: init", Int(afterInit * 1000), "load", Int((afterLoad - afterInit) * 1000),
                  "window", Int((samples.last! - afterLoad) * 1000))
            desk.windowControllers.values.forEach { $0.window?.close() }
        }
        let sorted = samples.sorted()
        print("LAUNCH-TO-FIRST-WINDOW 500 notes, median \(Int(sorted[sorted.count / 2] * 1000)) ms, "
              + "range \(Int(sorted[0] * 1000))-\(Int(sorted[sorted.count - 1] * 1000)) ms")
    }
}
