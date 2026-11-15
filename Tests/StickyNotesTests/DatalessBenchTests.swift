import AppKit
import XCTest
@testable import StickyNotesKit

/// What a pause in typing costs the main thread when part of the vault is held in
/// iCloud and not on disk ("dataless"): 200 notes, 40 of them open on the desk, 20
/// of the files dataless. A benchmark, not an assertion; skipped unless
/// `STICKY_BENCH=1` is set:
/// `STICKY_BENCH=1 xctest .build/out/Products/Debug/StickyNotesTests.xctest -XCTest StickyNotesTests.DatalessBenchTests`
///
/// A real dataless file cannot be made on a test machine. The store's `isDataless`
/// seam names the files that count as dataless, and every read of one that gets
/// past it costs `stall` seconds on the main thread, a stand-in for the wait on a
/// download. The save writes through the real file system, so the file watcher
/// reports (or, once it drops our own events, does not report) the write back, and
/// the desk and the windows react as in the app.
@MainActor final class DatalessBenchTests: XCTestCase {
    private var root: URL!
    private var isolated: IsolatedSettings!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatalessBench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        isolated = IsolatedSettings()
    }

    override func tearDown() async throws {
        isolated.tearDown()
        try? FileManager.default.removeItem(at: root)
    }

    private func mainThreadCPUSeconds() -> Double {
        var spec = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spec)
        return Double(spec.tv_sec) + Double(spec.tv_nsec) / 1_000_000_000
    }

    /// Time the main run loop spends running work rather than waiting for it.
    private final class BusyMeter {
        private(set) var busy: CFAbsoluteTime = 0
        private var started: CFAbsoluteTime?
        private var observer: CFRunLoopObserver?

        func start() {
            let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
            observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
                guard let self else { return }
                if activity == .afterWaiting {
                    self.started = CFAbsoluteTimeGetCurrent()
                } else if let began = self.started {
                    self.busy += CFAbsoluteTimeGetCurrent() - began
                    self.started = nil
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        func stop() {
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observer = nil
        }
    }

    func testBenchmarkSaveEchoObserverWithTwentyOfTwoHundredNotesDataless() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STICKY_BENCH"] == "1", "set STICKY_BENCH=1 to run")
        let stall: TimeInterval = 0.005
        let notes = 200, windows = 40, saves = 10

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
        let loaded = store.loadActive().sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        for note in loaded.prefix(windows) { desk.presentWindow(for: note, activate: false) }
        desk.startObserving()
        XCTAssertEqual(desk.windowControllers.count, windows)

        // Ten notes with a window and ten without are dataless.
        var datalessPaths = Set<String>()
        let marked = Array(loaded[30..<40]) + Array(loaded[100..<110])
        let files = try FileManager.default.contentsOfDirectory(at: store.activeURL, includingPropertiesForKeys: nil)
        for note in marked {
            let url = try XCTUnwrap(files.first {
                (try? String(contentsOf: $0, encoding: .utf8))?.contains(note.id.uuidString) == true
            })
            datalessPaths.insert(url.resolvingSymlinksInPath().path)
        }
        var datalessReads = 0
        store.isDataless = { datalessPaths.contains($0.resolvingSymlinksInPath().path) }
        store.willReadFile = { url in
            if datalessPaths.contains(url.resolvingSymlinksInPath().path) {
                datalessReads += 1
                Thread.sleep(forTimeInterval: stall)
            }
        }
        store.startDownload = { _ in }

        var note = try XCTUnwrap(store.loadNote(id: loaded[0].id))
        var fingerprint = try XCTUnwrap(store.snapshot(id: note.id)).fingerprint
        let meter = BusyMeter()
        meter.start()
        let readsBefore = store.readCount
        let datalessBefore = datalessReads
        let cpuBefore = mainThreadCPUSeconds()
        var saveBusy: CFAbsoluteTime = 0
        for index in 0..<saves {
            note.content += "x"
            note.updatedAt = Date().addingTimeInterval(Double(index))
            let began = CFAbsoluteTimeGetCurrent()
            if case let .saved(next) = store.save(note, expecting: fingerprint) { fingerprint = next }
            saveBusy += CFAbsoluteTimeGetCurrent() - began
            // Long enough for the watcher's latency and debounce, and for what follows.
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        }
        meter.stop()
        let totalBusy = meter.busy + saveBusy
        let cpu = mainThreadCPUSeconds() - cpuBefore
        print(String(
            format: "  per save, 200 notes, 40 open, 20 dataless, %.0f ms stall per dataless read: main thread busy %.1f ms (CPU %.1f ms), %.1f reads, %.1f of them of dataless files",
            stall * 1000, totalBusy * 1000 / Double(saves), cpu * 1000 / Double(saves),
            Double(store.readCount - readsBefore) / Double(saves), Double(datalessReads - datalessBefore) / Double(saves)))
        desk.windowControllers.values.forEach { $0.window?.close() }
    }
}
