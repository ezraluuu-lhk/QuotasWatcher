import Foundation

public enum QuotaProviderID: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case codex
    case kimi

    public var id: String { rawValue }

    public var localizedKey: String {
        switch self {
        case .codex:
            return "provider.codex"
        case .kimi:
            return "provider.kimi"
        }
    }

    public var statusItemLabelKey: String {
        switch self {
        case .codex:
            return "status.item.label.codex"
        case .kimi:
            return "status.item.label.kimi"
        }
    }

    public var statusItemWeeklyLabelKey: String {
        switch self {
        case .codex:
            return "status.item.weekly.label.codex"
        case .kimi:
            return "status.item.weekly.label.kimi"
        }
    }

    public var statusItemUnavailableLabelKey: String {
        switch self {
        case .codex:
            return "status.item.unavailable.label.codex"
        case .kimi:
            return "status.item.unavailable.label.kimi"
        }
    }
}

public protocol QuotaProvider: Sendable {
    var id: QuotaProviderID { get }
    func fetchQuotaSnapshot() async throws -> QuotaSnapshot
}
