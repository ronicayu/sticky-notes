import Foundation

/// A piece of work that has been scheduled and can still be called off.
protocol ScheduledWork: AnyObject {
    func cancel()
}

/// Runs work after a delay. The debounce of a save and the retry of a failed
/// one go through this, so a test moves time by hand instead of waiting for it.
protocol Scheduler {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> ScheduledWork
    /// Like `schedule`, but the delay is counted on the calendar clock: it keeps
    /// running while the Mac sleeps, as a rollover at midnight needs.
    func scheduleOnWallClock(after delay: TimeInterval, _ work: @escaping () -> Void) -> ScheduledWork
}

extension Scheduler {
    func scheduleOnWallClock(after delay: TimeInterval, _ work: @escaping () -> Void) -> ScheduledWork {
        schedule(after: delay, work)
    }
}

/// The main queue. Delays are monotonic, so a step of the system clock does not
/// stretch a debounce; only `scheduleOnWallClock` follows the calendar.
struct MainScheduler: Scheduler {
    private final class Item: ScheduledWork {
        let item: DispatchWorkItem
        init(_ work: @escaping () -> Void) { item = DispatchWorkItem(block: work) }
        func cancel() { item.cancel() }
    }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> ScheduledWork {
        let scheduled = Item(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: scheduled.item)
        return scheduled
    }

    func scheduleOnWallClock(after delay: TimeInterval, _ work: @escaping () -> Void) -> ScheduledWork {
        let scheduled = Item(work)
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + delay, execute: scheduled.item)
        return scheduled
    }
}
