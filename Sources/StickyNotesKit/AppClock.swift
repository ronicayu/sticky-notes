import Foundation

/// The current time, injected wherever a `Date` is compared with something:
/// the trash purge, the conflict and duplicate sweep rate limits, `updatedAt`
/// stamps and the daily-note rollover. Named `AppClock` so it cannot be mistaken
/// for Swift's own `Clock`. Timers and debounces are not abstracted here.
protocol AppClock {
    func now() -> Date
}

struct SystemClock: AppClock {
    func now() -> Date { Date() }
}
