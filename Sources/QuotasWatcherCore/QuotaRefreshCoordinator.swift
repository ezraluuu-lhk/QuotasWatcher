import Foundation

/// Foundation-only refresh coordinator. Owns the dashboard state, refreshes
/// providers concurrently, and notifies on every state change so AppKit can
/// render on the main actor.
public actor QuotaRefreshCoordinator {
    public private(set) var dashboard: QuotaDashboardState
    private let providers: [QuotaProviderID: QuotaProvider]
    private let onUpdate: @MainActor @Sendable (QuotaDashboardState) -> Void
    private let onCodexSuccess: @MainActor @Sendable (QuotaSnapshot) -> Void
    private let log: AppLog

    public init(
        providers: [QuotaProviderID: QuotaProvider],
        onUpdate: @escaping @MainActor @Sendable (QuotaDashboardState) -> Void,
        onCodexSuccess: @escaping @MainActor @Sendable (QuotaSnapshot) -> Void,
        log: AppLog = .shared
    ) {
        self.providers = providers
        self.dashboard = QuotaDashboardState()
        self.onUpdate = onUpdate
        self.onCodexSuccess = onCodexSuccess
        self.log = log
    }

    /// Selects a provider and delivers the resulting update before returning,
    /// so selection callbacks are always observed synchronously in call order.
    public func selectProvider(_ provider: QuotaProviderID) async {
        dashboard.selectProvider(provider)
        await notifyUpdate()
    }

    /// Begins a refresh for every provider. Each provider's begin notification
    /// is delivered in provider order before this returns; the fetches then
    /// run concurrently and finish independently.
    public func refreshAll() async {
        for id in QuotaProviderID.allCases {
            await refresh(id)
        }
    }

    /// Marks the provider refreshing and delivers that update before
    /// returning, then performs the fetch in the background. A refresh for an
    /// already-refreshing provider is skipped without touching the others.
    public func refresh(_ id: QuotaProviderID) async {
        guard !dashboard.isRefreshing(id), let provider = providers[id] else {
            return
        }

        dashboard.beginRefresh(for: id)
        await notifyUpdate()
        Task {
            do {
                let snapshot = try await provider.fetchQuotaSnapshot()
                await finishRefresh(for: id, with: .success(snapshot))
                log.append("[\(id.rawValue.capitalized)] Refresh succeeded.")
                if id == .codex {
                    await onCodexSuccess(snapshot)
                }
            } catch {
                await finishRefresh(for: id, with: .failure(error))
                log.append("[\(id.rawValue.capitalized)] Refresh failed: \(error.localizedDescription)")
            }
        }
    }

    private func finishRefresh(for id: QuotaProviderID, with result: Result<QuotaSnapshot, Error>) async {
        dashboard.finishRefresh(for: id, with: result)
        await notifyUpdate()
    }

    private func notifyUpdate() async {
        await onUpdate(dashboard)
    }
}
