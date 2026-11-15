import Foundation
@testable import StickyNotesKit

/// A clock the test moves by hand.
final class ManualClock: AppClock {
    var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    func now() -> Date { current }

    func advance(by seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }
}

/// `Settings` over a throwaway `UserDefaults` suite and two temp folders, so a
/// test never reads or writes the developer's real preferences or storage.
/// Call `tearDown()` when done: suites persist as plist files otherwise.
final class IsolatedSettings {
    let settings: Settings
    /// Stands in for `~/Library/Application Support`.
    let localRoot: URL
    /// Stands in for iCloud Drive; the folder does not exist, so iCloud reads as unavailable.
    let iCloudRoot: URL
    private let suiteName: String
    private let directory: URL

    init() {
        suiteName = "StickyNotesTests-\(UUID().uuidString)"
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IsolatedSettings-\(UUID().uuidString)", isDirectory: true)
        localRoot = directory.appendingPathComponent("local", isDirectory: true)
        iCloudRoot = directory.appendingPathComponent("icloud", isDirectory: true)
        try? FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        settings = Settings(
            defaults: UserDefaults(suiteName: suiteName)!,
            localRootURL: localRoot,
            iCloudRootURL: iCloudRoot
        )
    }

    func tearDown() {
        settings.defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A scheduler the test moves by hand. `advance(by:)` runs every task that falls
/// due, in order, including ones a running task schedules inside the window, and
/// moves the clock it was given by the same amount.
final class TestScheduler: Scheduler {
    private final class Task: ScheduledWork {
        let due: TimeInterval
        let work: () -> Void
        var cancelled = false

        init(due: TimeInterval, work: @escaping () -> Void) {
            self.due = due
            self.work = work
        }

        func cancel() { cancelled = true }
    }

    private var tasks: [Task] = []
    private(set) var elapsed: TimeInterval = 0
    private let clock: ManualClock?

    init(clock: ManualClock? = nil) {
        self.clock = clock
    }

    /// Tasks that are waiting and have not been cancelled.
    var pendingCount: Int { tasks.filter { !$0.cancelled }.count }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> ScheduledWork {
        let task = Task(due: elapsed + delay, work: work)
        tasks.append(task)
        return task
    }

    func advance(by seconds: TimeInterval) {
        let target = elapsed + seconds
        while let next = tasks.filter({ !$0.cancelled && $0.due <= target }).min(by: { $0.due < $1.due }) {
            tasks.removeAll { $0 === next }
            move(to: next.due)
            next.work()
        }
        tasks.removeAll { $0.cancelled }
        move(to: target)
    }

    private func move(to time: TimeInterval) {
        clock?.advance(by: time - elapsed)
        elapsed = time
    }
}

/// The fastest of `runs` timings of `work`, in seconds. A timing bound on a
/// shared CI machine is only meaningful for the best run: one run can be slowed
/// by whatever else the machine was doing, none can be faster than the code is.
func bestTime(runs: Int = 5, _ work: () -> Void) -> TimeInterval {
    var best = TimeInterval.infinity
    for _ in 0..<runs {
        let start = CFAbsoluteTimeGetCurrent()
        work()
        best = min(best, CFAbsoluteTimeGetCurrent() - start)
    }
    return best
}
