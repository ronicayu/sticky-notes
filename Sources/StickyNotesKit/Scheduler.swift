import Foundation

/// A piece of work that has been scheduled and can still be called off.
protocol ScheduledWork: AnyObject {
    func cancel()
}

/// Runs work after a delay. The debounce of a save and the retry of a failed
/// one go through this, so a test moves time by hand instead of waiting for it.
protocol Scheduler {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> ScheduledWork
}

/// The main queue, on the wall clock: a delay that spans the Mac sleeping still
/// ends on time by the calendar, as a midnight rollover needs.
struct MainScheduler: Scheduler {
    private final class Item: ScheduledWork {
        let item: DispatchWorkItem
        init(_ work: @escaping () -> Void) { item = DispatchWorkItem(block: work) }
        func cancel() { item.cancel() }
    }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> ScheduledWork {
        let scheduled = Item(work)
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + delay, execute: scheduled.item)
        return scheduled
    }
}
