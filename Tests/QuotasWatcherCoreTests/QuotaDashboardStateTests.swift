import XCTest
@testable import QuotasWatcherCore

final class QuotaDashboardStateTests: XCTestCase {
    func testInitialSelectionIsCodex() {
        let dashboard = QuotaDashboardState()
        XCTAssertEqual(dashboard.selectedProvider, .codex)
        XCTAssertFalse(dashboard.isRefreshing(.codex))
        XCTAssertFalse(dashboard.isRefreshing(.kimi))
        XCTAssertNil(dashboard.snapshot(for: .codex))
        XCTAssertNil(dashboard.snapshot(for: .kimi))
    }

    func testSelectionChangesImmediately() {
        var dashboard = QuotaDashboardState()
        dashboard.selectProvider(.kimi)
        XCTAssertEqual(dashboard.selectedProvider, .kimi)
        dashboard.selectProvider(.codex)
        XCTAssertEqual(dashboard.selectedProvider, .codex)
    }

    func testBeginRefreshMarksOnlySelectedProvider() {
        var dashboard = QuotaDashboardState()
        dashboard.beginRefresh(for: .kimi)
        XCTAssertTrue(dashboard.isRefreshing(.kimi))
        XCTAssertFalse(dashboard.isRefreshing(.codex))
        XCTAssertNil(dashboard.errorMessage(for: .kimi))
    }

    func testFinishSuccessReplacesSnapshotAndClearsError() {
        var dashboard = QuotaDashboardState()
        let snapshot = QuotaSnapshot(
            fiveHour: QuotaLimit(kind: .fiveHour, window: RateLimitWindow(usedPercent: 20, windowDurationMins: 300, resetsAt: nil)),
            weekly: nil,
            fetchedAt: Date(timeIntervalSince1970: 10)
        )
        dashboard.finishRefresh(for: .codex, with: .success(snapshot))
        XCTAssertEqual(dashboard.snapshot(for: .codex), snapshot)
        XCTAssertNil(dashboard.errorMessage(for: .codex))
        XCTAssertFalse(dashboard.isRefreshing(.codex))
    }

    func testFinishFailureRetainsPreviousSnapshotAndSetsError() {
        let previous = QuotaSnapshot(
            fiveHour: QuotaLimit(kind: .fiveHour, window: RateLimitWindow(usedPercent: 20, windowDurationMins: 300, resetsAt: nil)),
            weekly: nil,
            fetchedAt: Date(timeIntervalSince1970: 10)
        )
        var dashboard = QuotaDashboardState(states: [.codex: QuotaRefreshState(snapshot: previous)])
        dashboard.finishRefresh(for: .codex, with: .failure(CodexAppServerError.rpcError("network unavailable")))
        XCTAssertEqual(dashboard.snapshot(for: .codex), previous)
        XCTAssertEqual(dashboard.errorMessage(for: .codex), "network unavailable")
        XCTAssertFalse(dashboard.isRefreshing(.codex))
    }

    func testProvidersAreIndependent() {
        var dashboard = QuotaDashboardState()
        let codexSnapshot = QuotaSnapshot(
            fiveHour: QuotaLimit(kind: .fiveHour, window: RateLimitWindow(usedPercent: 10, windowDurationMins: 300, resetsAt: nil)),
            weekly: nil,
            fetchedAt: Date(timeIntervalSince1970: 1)
        )
        dashboard.finishRefresh(for: .codex, with: .success(codexSnapshot))
        dashboard.finishRefresh(for: .kimi, with: .failure(KimiCodeError.binaryNotFound))

        XCTAssertEqual(dashboard.snapshot(for: .codex), codexSnapshot)
        XCTAssertNil(dashboard.snapshot(for: .kimi))
        XCTAssertNil(dashboard.errorMessage(for: .codex))
        XCTAssertEqual(dashboard.errorMessage(for: .kimi), KimiCodeError.binaryNotFound.localizedDescription)
    }

    func testConcurrentRefreshFlagsAreIndependent() {
        var dashboard = QuotaDashboardState()
        dashboard.beginRefresh(for: .codex)
        dashboard.beginRefresh(for: .kimi)
        XCTAssertTrue(dashboard.isRefreshing(.codex))
        XCTAssertTrue(dashboard.isRefreshing(.kimi))

        let snapshot = QuotaSnapshot(fiveHour: nil, weekly: nil, fetchedAt: Date())
        dashboard.finishRefresh(for: .codex, with: .success(snapshot))
        XCTAssertFalse(dashboard.isRefreshing(.codex))
        XCTAssertTrue(dashboard.isRefreshing(.kimi))
    }

    func testSummaryPrefersFiveHour() {
        let snapshot = QuotaSnapshot(
            fiveHour: QuotaLimit(kind: .fiveHour, window: RateLimitWindow(usedPercent: 25, windowDurationMins: 300, resetsAt: nil)),
            weekly: QuotaLimit(kind: .weekly, window: RateLimitWindow(usedPercent: 40, windowDurationMins: 10080, resetsAt: nil)),
            fetchedAt: Date()
        )
        let dashboard = QuotaDashboardState(states: [.codex: QuotaRefreshState(snapshot: snapshot)])
        let summary = dashboard.summary(for: .codex)
        XCTAssertEqual(summary.remainingPercent, 75)
        XCTAssertFalse(summary.isWeeklyFallback)
    }

    func testSummaryFallsBackToWeekly() {
        let snapshot = QuotaSnapshot(
            fiveHour: nil,
            weekly: QuotaLimit(kind: .weekly, window: RateLimitWindow(usedPercent: 40, windowDurationMins: 10080, resetsAt: nil)),
            fetchedAt: Date()
        )
        let dashboard = QuotaDashboardState(states: [.codex: QuotaRefreshState(snapshot: snapshot)])
        let summary = dashboard.summary(for: .codex)
        XCTAssertEqual(summary.remainingPercent, 60)
        XCTAssertTrue(summary.isWeeklyFallback)
    }

    func testSummaryIsUnknownWithoutData() {
        let dashboard = QuotaDashboardState()
        let summary = dashboard.summary(for: .kimi)
        XCTAssertNil(summary.remainingPercent)
        XCTAssertFalse(summary.isWeeklyFallback)
    }

    func testBeginRefreshClearsOnlyThatProvidersError() {
        var dashboard = QuotaDashboardState()
        dashboard.finishRefresh(for: .codex, with: .failure(CodexAppServerError.timeout))
        dashboard.finishRefresh(for: .kimi, with: .failure(KimiCodeError.binaryNotFound))
        dashboard.beginRefresh(for: .codex)
        XCTAssertNil(dashboard.errorMessage(for: .codex))
        XCTAssertEqual(dashboard.errorMessage(for: .kimi), KimiCodeError.binaryNotFound.localizedDescription)
    }

    func testErrorMessageIsIsolatedByProvider() {
        var dashboard = QuotaDashboardState()
        dashboard.finishRefresh(for: .kimi, with: .failure(KimiCodeError.credentialNotFound))
        dashboard.selectProvider(.kimi)
        XCTAssertEqual(dashboard.errorMessage(for: .kimi), KimiCodeError.credentialNotFound.localizedDescription)
        dashboard.selectProvider(.codex)
        XCTAssertNil(dashboard.errorMessage(for: .codex))
    }

    func testBusyMarkerFollowsSelectedProviderOnly() {
        var dashboard = QuotaDashboardState()
        dashboard.beginRefresh(for: .kimi)
        XCTAssertFalse(dashboard.isRefreshing(.codex))
        XCTAssertTrue(dashboard.isRefreshing(.kimi))
    }
}
