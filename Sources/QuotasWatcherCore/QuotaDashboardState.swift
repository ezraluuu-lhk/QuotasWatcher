import Foundation

public struct QuotaDashboardState: Equatable, Sendable {
    public private(set) var selectedProvider: QuotaProviderID
    private var states: [QuotaProviderID: QuotaRefreshState]

    public init(selectedProvider: QuotaProviderID = .codex, states: [QuotaProviderID: QuotaRefreshState] = [:]) {
        self.selectedProvider = selectedProvider
        self.states = states
        for id in QuotaProviderID.allCases where self.states[id] == nil {
            self.states[id] = QuotaRefreshState()
        }
    }

    public func state(for provider: QuotaProviderID) -> QuotaRefreshState {
        states[provider] ?? QuotaRefreshState()
    }

    public var selectedState: QuotaRefreshState {
        state(for: selectedProvider)
    }

    public mutating func selectProvider(_ provider: QuotaProviderID) {
        selectedProvider = provider
    }

    public mutating func beginRefresh(for provider: QuotaProviderID) {
        var current = state(for: provider)
        current.beginRefresh()
        states[provider] = current
    }

    public mutating func finishRefresh(for provider: QuotaProviderID, with result: Result<QuotaSnapshot, Error>) {
        var current = state(for: provider)
        current.finishRefresh(with: result)
        states[provider] = current
    }

    public func isRefreshing(_ provider: QuotaProviderID) -> Bool {
        state(for: provider).isRefreshing
    }

    public func snapshot(for provider: QuotaProviderID) -> QuotaSnapshot? {
        state(for: provider).snapshot
    }

    public func errorMessage(for provider: QuotaProviderID) -> String? {
        state(for: provider).errorMessage
    }

    public func summary(for provider: QuotaProviderID) -> QuotaSummary {
        QuotaSummary.primary(for: snapshot(for: provider), provider: provider)
    }
}
