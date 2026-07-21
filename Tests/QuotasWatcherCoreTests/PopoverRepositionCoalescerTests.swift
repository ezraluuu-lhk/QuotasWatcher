import XCTest
@testable import QuotasWatcherCore

final class PopoverRepositionCoalescerTests: XCTestCase {
    /// A deterministic scheduler that captures deferred work instead of
    /// touching a run loop, so tests decide exactly when flushes run.
    private final class ManualScheduler {
        private(set) var pending: [() -> Void] = []

        func schedule(_ work: @escaping () -> Void) {
            pending.append(work)
        }

        func runAll() {
            let work = pending
            pending.removeAll()
            work.forEach { $0() }
        }
    }

    private var scheduler: ManualScheduler!
    private var applyCount = 0
    private var coalescer: PopoverRepositionCoalescer!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        applyCount = 0
        let scheduler = self.scheduler!
        coalescer = PopoverRepositionCoalescer(
            schedule: scheduler.schedule,
            apply: { [unowned self] in self.applyCount += 1 }
        )
    }

    override func tearDown() {
        coalescer = nil
        scheduler = nil
        super.tearDown()
    }

    func testRequestsWhileHiddenAreIgnored() {
        coalescer.request()
        coalescer.request()
        XCTAssertTrue(scheduler.pending.isEmpty)
        scheduler.runAll()
        XCTAssertEqual(applyCount, 0)
    }

    func testRequestsWhileShownAreCoalescedIntoSingleApply() {
        coalescer.setShown(true)
        coalescer.request()
        coalescer.request()
        coalescer.request()
        XCTAssertEqual(scheduler.pending.count, 1)
        XCTAssertEqual(applyCount, 0)

        scheduler.runAll()
        XCTAssertEqual(applyCount, 1)
    }

    func testNewBurstAfterFlushSchedulesAgain() {
        coalescer.setShown(true)
        coalescer.request()
        scheduler.runAll()
        XCTAssertEqual(applyCount, 1)

        coalescer.request()
        coalescer.request()
        XCTAssertEqual(scheduler.pending.count, 1)
        scheduler.runAll()
        XCTAssertEqual(applyCount, 2)
    }

    func testHidingBeforeFlushCancelsPendingApply() {
        coalescer.setShown(true)
        coalescer.request()
        XCTAssertEqual(scheduler.pending.count, 1)

        coalescer.setShown(false)
        scheduler.runAll()
        XCTAssertEqual(applyCount, 0)
    }

    func testRequestsAfterHideRemainIgnoredUntilShownAgain() {
        coalescer.setShown(true)
        coalescer.request()
        scheduler.runAll()
        XCTAssertEqual(applyCount, 1)

        coalescer.setShown(false)
        coalescer.request()
        XCTAssertTrue(scheduler.pending.isEmpty)

        coalescer.setShown(true)
        coalescer.request()
        XCTAssertEqual(scheduler.pending.count, 1)
        scheduler.runAll()
        XCTAssertEqual(applyCount, 2)
    }

    func testStaleFlushFromClosedSessionAppliesZeroTimes() {
        // Deferred work scheduled in a previous show session must never
        // apply, even when the popover has been shown again before the
        // scheduler runs the captured block late.
        coalescer.setShown(true)
        coalescer.request()
        coalescer.setShown(false)
        coalescer.setShown(true)
        scheduler.runAll()
        XCTAssertEqual(applyCount, 0)
        XCTAssertTrue(scheduler.pending.isEmpty)
    }

    func testStaleFlushCannotDisturbNewSessionCoalescing() {
        // The stale block from the closed session runs before the new
        // session's valid block: it must be a complete no-op that neither
        // applies nor clears the new session's pending flag.
        coalescer.setShown(true)
        coalescer.request()
        coalescer.setShown(false)
        coalescer.setShown(true)
        coalescer.request()
        XCTAssertEqual(scheduler.pending.count, 2)

        scheduler.runAll()
        XCTAssertEqual(applyCount, 1)

        // The new session's coalescing is intact: the next burst schedules
        // exactly one block and applies exactly once.
        coalescer.request()
        coalescer.request()
        XCTAssertEqual(scheduler.pending.count, 1)
        scheduler.runAll()
        XCTAssertEqual(applyCount, 2)
    }
}
