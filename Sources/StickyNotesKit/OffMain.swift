import Foundation

/// Where a question that another process answers is asked. Whatever may reach
/// iCloud's daemons (conflict versions of a file, the "has unresolved conflicts"
/// flag, a download request) can wait there for minutes while they are busy or
/// offline, so it is asked on a queue that is not the main one, and the answer is
/// applied on the main thread when it arrives. Tests that want the answer at once
/// use `inline`; the production default is `background`.
struct OffMain {
    private let runsInline: Bool

    static let background = OffMain(runsInline: false)
    static let inline = OffMain(runsInline: true)

    /// One queue for these questions, so a daemon that is stuck costs one thread and
    /// the questions behind it wait, rather than every one blocking a thread.
    private static let queue = DispatchQueue(label: "StickyNotes.OffMain", qos: .utility)

    /// Run `work` off the main thread and then `apply` its result on the main
    /// thread. Must be called on the main thread.
    func ask<Answer>(_ work: @escaping () -> Answer, then apply: @escaping (Answer) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if runsInline {
            apply(work())
            return
        }
        let work = UncheckedSendable(work)
        let apply = UncheckedSendable(apply)
        Self.queue.async {
            let answer = UncheckedSendable(work.value())
            DispatchQueue.main.async { apply.value(answer.value) }
        }
    }
}
