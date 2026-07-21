import Foundation

/// Lifecycle and burst-coalescing policy for popover position maintenance.
///
/// Menu-bar hide/reveal transitions in a fullscreen Space emit bursts of
/// geometry notifications. This component collapses each burst into a single
/// deferred `apply` on a caller-supplied scheduler (the main run loop in
/// production), ignores every request while the popover is hidden, and drops
/// a pending flush if the popover closes before it runs. It owns no timers,
/// holds no observers, and is free of AppKit so it can be tested
/// deterministically without a WindowServer.
public final class PopoverRepositionCoalescer {
    public typealias Schedule = (@escaping () -> Void) -> Void

    private let schedule: Schedule
    private let apply: () -> Void
    private var isShown = false
    private var isPending = false

    /// Monotonic session counter. Every shown/hidden transition starts a new
    /// session, so a closure scheduled before a hide carries a stale
    /// generation and can never apply or disturb pending state again — even
    /// if the popover is shown again before the closure runs.
    private var generation = 0

    public init(schedule: @escaping Schedule, apply: @escaping () -> Void) {
        self.schedule = schedule
        self.apply = apply
    }

    /// Marks whether the popover is currently shown. Hiding the popover
    /// cancels any pending flush and makes later requests no-ops.
    public func setShown(_ shown: Bool) {
        guard shown != isShown else {
            return
        }
        isShown = shown
        generation &+= 1
        if !shown {
            isPending = false
        }
    }

    /// Records a geometry event. While shown, multiple requests before the
    /// deferred flush runs collapse into a single `apply`.
    public func request() {
        guard isShown, !isPending else {
            return
        }
        isPending = true
        let scheduledGeneration = generation
        schedule { [weak self] in
            self?.flush(scheduledGeneration: scheduledGeneration)
        }
    }

    private func flush(scheduledGeneration: Int) {
        // A stale closure must be a complete no-op: it must not apply old
        // work and must not clear a newer session's pending flag.
        guard isShown, scheduledGeneration == generation else {
            return
        }
        isPending = false
        apply()
    }
}
