import AppKit
import XCTest
@testable import StickyNotesKit

/// A test process has a low open-file limit (256 on a CI runner), and the app runs
/// for weeks, so nothing a store, a watcher or a window does may keep a file
/// descriptor. These tests never yield to the main queue: work that gives its
/// descriptors back only when the main queue runs would pass in the app and
/// still exhaust a test run, which is how the welcome-note tests failed on CI.
@MainActor final class FileDescriptorLeakTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDLeak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Descriptors this process has open now.
    private func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }

    private func note(_ i: Int) -> Note {
        Note(id: UUID(), title: "t\(i)", content: "body \(i)", width: 240, height: 200, color: .yellow,
             createdAt: Date(), updatedAt: Date())
    }

    /// Slack for descriptors in flight when the count is taken; a leak costs about 33 per store.
    private let slack = 40

    func testSavingAndLoadingKeepNoDescriptors() {
        let store = NoteStore(rootURL: root)
        var saved = [note(0)]
        store.save(saved[0])
        let start = openDescriptors()

        for i in 1...200 {
            let n = note(i)
            store.save(n)
            saved.append(n)
            _ = store.loadActive()
            _ = store.snapshot(id: n.id)
        }
        for n in saved.prefix(50) { _ = store.whereIs(id: n.id) }
        _ = store.resolveConflicts()

        XCTAssertLessThanOrEqual(openDescriptors() - start, slack)
    }

    func testMakingAndDroppingStoresKeepsNoDescriptors() {
        _ = NoteStore(rootURL: root)
        let start = openDescriptors()

        for i in 0..<100 {
            autoreleasepool { _ = NoteStore(rootURL: root.appendingPathComponent("store\(i)")) }
        }

        XCTAssertLessThanOrEqual(openDescriptors() - start, slack, "each store left its folder watcher's descriptors open")
    }

    func testStartingAndStoppingAWatcherGivesItsDescriptorsBackAtOnce() {
        let start = openDescriptors()

        for _ in 0..<100 {
            let watcher = FileWatcher {}
            watcher.watch([root])
            watcher.stop()
        }

        XCTAssertLessThanOrEqual(openDescriptors() - start, slack)
    }

    func testALaunchedDeskAndItsWindowsKeepNoDescriptorsOnceClosed() throws {
        let isolated = IsolatedSettings()
        defer { isolated.tearDown() }
        func launchAndClose(_ i: Int) {
            autoreleasepool {
                let store = NoteStore(rootURL: root.appendingPathComponent("desk\(i)"))
                var n = note(i)
                n.content = "x"
                store.save(n)
                let app = AppDelegate(store: store, settings: isolated.settings, clock: SystemClock())
                app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
                app.desk.windowControllers.values.forEach { $0.window?.close() }
                app.desk.tearDownDailyNote()
            }
            // The app's main queue is never blocked, so what a launch left queued runs.
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        launchAndClose(-1)
        let start = openDescriptors()

        for i in 0..<20 { launchAndClose(i) }

        XCTAssertLessThanOrEqual(openDescriptors() - start, slack)
    }

    func testTheLayoutStoreKeepsNoDescriptors() {
        let layout = DeviceLayoutStore(url: root.appendingPathComponent("layout.json"))
        layout.set(NoteLayout(x: 0, y: 0, width: 1, height: 1), for: UUID())
        layout.flush()
        let start = openDescriptors()

        for i in 0..<200 {
            layout.set(NoteLayout(x: Double(i), y: 0, width: 1, height: 1), for: UUID())
            layout.flush()
        }

        XCTAssertLessThanOrEqual(openDescriptors() - start, slack)
    }
}
