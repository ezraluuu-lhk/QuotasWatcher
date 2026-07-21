import XCTest
@testable import QuotasWatcherCore

final class QuotaRefreshCoordinatorTests: XCTestCase {
    private let codexSnapshot = QuotaSnapshot(
        fiveHour: QuotaLimit(kind: .fiveHour, window: RateLimitWindow(usedPercent: 20, windowDurationMins: 300, resetsAt: nil)),
        weekly: nil,
        fetchedAt: Date(timeIntervalSince1970: 1)
    )

    private let kimiSnapshot = QuotaSnapshot(
        fiveHour: QuotaLimit(kind: .fiveHour, window: RateLimitWindow(usedPercent: 30, windowDurationMins: 300, resetsAt: nil)),
        weekly: nil,
        fetchedAt: Date(timeIntervalSince1970: 2)
    )

    func testInitialSelectionIsCodex() async {
        let coordinator = makeCoordinator()
        let dashboard = await coordinator.dashboard
        XCTAssertEqual(dashboard.selectedProvider, .codex)
    }

    func testCodexSucceedsWhileKimiFails() async {
        let coordinator = makeCoordinator(
            providers: [
                .codex: FakeProvider(id: .codex, result: .success(codexSnapshot)),
                .kimi: FakeProvider(id: .kimi, result: .failure(KimiCodeError.binaryNotFound))
            ]
        )

        await coordinator.refreshAll()
        let dashboard = await waitUntil(in: coordinator) {
            $0.snapshot(for: .codex) != nil && $0.errorMessage(for: .kimi) != nil
        }

        XCTAssertEqual(dashboard.snapshot(for: .codex), codexSnapshot)
        XCTAssertNil(dashboard.snapshot(for: .kimi))
        XCTAssertNil(dashboard.errorMessage(for: .codex))
        XCTAssertEqual(dashboard.errorMessage(for: .kimi), KimiCodeError.binaryNotFound.localizedDescription)
    }

    func testKimiSucceedsWhileCodexFails() async {
        let coordinator = makeCoordinator(
            providers: [
                .codex: FakeProvider(id: .codex, result: .failure(CodexAppServerError.timeout)),
                .kimi: FakeProvider(id: .kimi, result: .success(kimiSnapshot))
            ]
        )

        await coordinator.refreshAll()
        let dashboard = await waitUntil(in: coordinator) {
            $0.snapshot(for: .kimi) != nil && $0.errorMessage(for: .codex) != nil
        }

        XCTAssertEqual(dashboard.snapshot(for: .kimi), kimiSnapshot)
        XCTAssertNil(dashboard.snapshot(for: .codex))
        XCTAssertNil(dashboard.errorMessage(for: .kimi))
        XCTAssertEqual(dashboard.errorMessage(for: .codex), CodexAppServerError.timeout.localizedDescription)
    }

    func testSkipAlreadyRefreshingProviderButStartIdleProvider() async {
        let slowCodex = SlowProvider(id: .codex, snapshot: codexSnapshot, delay: 0.5)
        let coordinator = makeCoordinator(
            providers: [
                .codex: slowCodex,
                .kimi: FakeProvider(id: .kimi, result: .success(kimiSnapshot))
            ]
        )

        // The begin update is delivered before refresh returns, so the
        // refreshing flag is observable synchronously.
        await coordinator.refresh(.codex)
        let dashboardAfterFirst = await coordinator.dashboard
        XCTAssertTrue(dashboardAfterFirst.isRefreshing(.codex))

        await coordinator.refresh(.codex)
        await coordinator.refresh(.kimi)
        let dashboard = await waitUntil(in: coordinator) {
            $0.snapshot(for: .kimi) != nil
        }

        XCTAssertTrue(dashboard.isRefreshing(.codex))
        XCTAssertEqual(dashboard.snapshot(for: .kimi), kimiSnapshot)

        // Let the slow Codex refresh finish so the test leaves no work behind.
        _ = await waitUntil(in: coordinator) { !$0.isRefreshing(.codex) }
    }

    func testBarkHookReceivesCodexSuccessesOnly() async {
        let receivedSnapshots = LockedRecorder<QuotaSnapshot>()
        let coordinator = makeCoordinator(
            providers: [
                .codex: FakeProvider(id: .codex, result: .success(codexSnapshot)),
                .kimi: FakeProvider(id: .kimi, result: .success(kimiSnapshot))
            ],
            onCodexSuccess: { snapshot in
                receivedSnapshots.append(snapshot)
            }
        )

        await coordinator.refreshAll()
        _ = await waitUntil(in: coordinator) {
            $0.snapshot(for: .codex) != nil && $0.snapshot(for: .kimi) != nil
        }
        // The Bark hook runs after the Codex finish update; give it one runloop
        // turn, then assert.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(receivedSnapshots.values.count, 1)
        XCTAssertEqual(receivedSnapshots.values.first, codexSnapshot)
    }

    func testSelectedProviderBusyMarkerOnly() async {
        let slowKimi = SlowProvider(id: .kimi, snapshot: kimiSnapshot, delay: 0.4)
        let coordinator = makeCoordinator(
            providers: [
                .codex: FakeProvider(id: .codex, result: .success(codexSnapshot)),
                .kimi: slowKimi
            ]
        )

        await coordinator.refresh(.kimi)

        // While Kimi is still in flight, the selected provider (Codex) is not
        // busy and the unselected Kimi refresh does not mark Codex refreshing.
        var dashboard = await coordinator.dashboard
        XCTAssertEqual(dashboard.selectedProvider, .codex)
        XCTAssertFalse(dashboard.isRefreshing(dashboard.selectedProvider))
        XCTAssertFalse(dashboard.isRefreshing(.codex))
        XCTAssertTrue(dashboard.isRefreshing(.kimi))

        // Switching the selection makes the busy marker follow Kimi only.
        await coordinator.selectProvider(.kimi)
        dashboard = await coordinator.dashboard
        XCTAssertTrue(dashboard.isRefreshing(dashboard.selectedProvider))

        // Let the in-flight refresh finish so the test leaves no work behind.
        dashboard = await waitUntil(in: coordinator) { !$0.isRefreshing(.kimi) }
        XCTAssertEqual(dashboard.snapshot(for: .kimi), kimiSnapshot)
    }

    func testOneProviderFinishingDoesNotClearOtherRefreshingFlag() async {
        let coordinator = makeCoordinator(
            providers: [
                .codex: SlowProvider(id: .codex, snapshot: codexSnapshot, delay: 0.5),
                .kimi: SlowProvider(id: .kimi, snapshot: kimiSnapshot, delay: 0.1)
            ]
        )

        await coordinator.refreshAll()
        var dashboard = await waitUntil(in: coordinator) {
            $0.snapshot(for: .kimi) != nil
        }
        XCTAssertEqual(dashboard.snapshot(for: .kimi), kimiSnapshot)
        XCTAssertFalse(dashboard.isRefreshing(.kimi))
        XCTAssertTrue(dashboard.isRefreshing(.codex))

        dashboard = await waitUntil(in: coordinator) { !$0.isRefreshing(.codex) }
        XCTAssertEqual(dashboard.snapshot(for: .codex), codexSnapshot)
    }

    func testCopyErrorLookupFollowsSelectedProvider() async {
        let coordinator = makeCoordinator(
            providers: [
                .codex: FakeProvider(id: .codex, result: .failure(CodexAppServerError.timeout)),
                .kimi: FakeProvider(id: .kimi, result: .failure(KimiCodeError.credentialNotFound))
            ]
        )

        await coordinator.refreshAll()
        var dashboard = await waitUntil(in: coordinator) {
            $0.errorMessage(for: .codex) != nil && $0.errorMessage(for: .kimi) != nil
        }
        XCTAssertEqual(
            dashboard.errorMessage(for: dashboard.selectedProvider),
            CodexAppServerError.timeout.localizedDescription
        )

        await coordinator.selectProvider(.kimi)
        dashboard = await coordinator.dashboard
        XCTAssertEqual(
            dashboard.errorMessage(for: dashboard.selectedProvider),
            KimiCodeError.credentialNotFound.localizedDescription
        )
    }

    func testSelectionChangesImmediately() async {
        let coordinator = makeCoordinator()
        await coordinator.selectProvider(.kimi)
        let dashboard = await coordinator.dashboard
        XCTAssertEqual(dashboard.selectedProvider, .kimi)
    }

    // MARK: - Deterministic update ordering

    func testSelectionUpdatesAreDeliveredInCallOrderBeforeReturning() async {
        let selections = LockedRecorder<QuotaProviderID>()
        let coordinator = makeCoordinator(onUpdate: { dashboard in
            selections.append(dashboard.selectedProvider)
        })

        // Each call must deliver its update before returning, so rapid
        // selection can neither coalesce nor reorder callbacks.
        await coordinator.selectProvider(.kimi)
        XCTAssertEqual(selections.values, [.kimi])

        await coordinator.selectProvider(.codex)
        XCTAssertEqual(selections.values, [.kimi, .codex])

        await coordinator.selectProvider(.kimi)
        XCTAssertEqual(selections.values, [.kimi, .codex, .kimi])
    }

    func testRefreshBeginUpdateIsDeliveredBeforeReturning() async {
        let updates = LockedRecorder<QuotaDashboardState>()
        let coordinator = makeCoordinator(
            providers: [
                .codex: FakeProvider(id: .codex, result: .success(codexSnapshot)),
                .kimi: SlowProvider(id: .kimi, snapshot: kimiSnapshot, delay: 0.5)
            ],
            onUpdate: { dashboard in
                updates.append(dashboard)
            }
        )

        await coordinator.refresh(.kimi)

        // The begin update has already been delivered at this point: no sleep
        // or polling is needed to observe the refreshing state.
        let recorded = updates.values
        XCTAssertEqual(recorded.count, 1)
        XCTAssertTrue(recorded.first?.isRefreshing(.kimi) ?? false)
        XCTAssertFalse(recorded.first?.isRefreshing(.codex) ?? true)

        let final = await waitUntil(in: coordinator) { !$0.isRefreshing(.kimi) }
        XCTAssertEqual(final.snapshot(for: .kimi), kimiSnapshot)
        XCTAssertEqual(updates.values.count, 2)
        XCTAssertFalse(updates.values.last?.isRefreshing(.kimi) ?? true)
    }

    func testRefreshAllDeliversBeginUpdatesInProviderOrder() async {
        let updates = LockedRecorder<QuotaDashboardState>()
        let coordinator = makeCoordinator(
            providers: [
                .codex: SlowProvider(id: .codex, snapshot: codexSnapshot, delay: 0.5),
                .kimi: SlowProvider(id: .kimi, snapshot: kimiSnapshot, delay: 0.5)
            ],
            onUpdate: { dashboard in
                updates.append(dashboard)
            }
        )

        await coordinator.refreshAll()

        // Both begin updates are delivered, in provider order, before
        // refreshAll returns; the slow fetches have not completed yet.
        let recorded = updates.values
        XCTAssertEqual(recorded.count, 2)
        XCTAssertTrue(recorded[0].isRefreshing(.codex))
        XCTAssertFalse(recorded[0].isRefreshing(.kimi))
        XCTAssertTrue(recorded[1].isRefreshing(.codex))
        XCTAssertTrue(recorded[1].isRefreshing(.kimi))

        let final = await waitUntil(in: coordinator) {
            $0.snapshot(for: .codex) != nil && $0.snapshot(for: .kimi) != nil
        }
        XCTAssertEqual(final.snapshot(for: .codex), codexSnapshot)
        XCTAssertEqual(final.snapshot(for: .kimi), kimiSnapshot)
    }

    // MARK: - Helpers

    private func makeCoordinator(
        providers: [QuotaProviderID: QuotaProvider]? = nil,
        onUpdate: @escaping @Sendable (QuotaDashboardState) -> Void = { _ in },
        onCodexSuccess: @escaping @Sendable (QuotaSnapshot) -> Void = { _ in }
    ) -> QuotaRefreshCoordinator {
        let actualProviders = providers ?? [
            .codex: FakeProvider(id: .codex, result: .success(codexSnapshot)),
            .kimi: FakeProvider(id: .kimi, result: .success(kimiSnapshot))
        ]
        return QuotaRefreshCoordinator(
            providers: actualProviders,
            onUpdate: onUpdate,
            onCodexSuccess: onCodexSuccess
        )
    }

    /// Polls the coordinator until the predicate holds, replacing fixed sleeps
    /// for asynchronous refresh completions.
    private func waitUntil(
        in coordinator: QuotaRefreshCoordinator,
        timeout: TimeInterval = 5,
        predicate: @Sendable (QuotaDashboardState) -> Bool
    ) async -> QuotaDashboardState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let dashboard = await coordinator.dashboard
            if predicate(dashboard) {
                return dashboard
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await coordinator.dashboard
    }
}

struct FakeProvider: QuotaProvider {
    let id: QuotaProviderID
    let result: Result<QuotaSnapshot, Error>

    func fetchQuotaSnapshot() async throws -> QuotaSnapshot {
        switch result {
        case .success(let snapshot):
            return snapshot
        case .failure(let error):
            throw error
        }
    }
}

struct SlowProvider: QuotaProvider {
    let id: QuotaProviderID
    let snapshot: QuotaSnapshot
    let delay: TimeInterval

    func fetchQuotaSnapshot() async throws -> QuotaSnapshot {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return snapshot
    }
}
