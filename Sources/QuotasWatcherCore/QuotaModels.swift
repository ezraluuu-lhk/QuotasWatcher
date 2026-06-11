import Foundation

public struct RateLimitWindow: Decodable, Equatable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: TimeInterval?
}

public struct RateLimitSnapshot: Decodable, Equatable {
    public let limitId: String?
    public let limitName: String?
    public let primary: RateLimitWindow?
    public let secondary: RateLimitWindow?
}

public struct GetAccountRateLimitsResponse: Decodable, Equatable {
    public let rateLimits: RateLimitSnapshot
    public let rateLimitsByLimitId: [String: RateLimitSnapshot]?
}

public enum QuotaKind: String, Equatable {
    case fiveHour
    case weekly
}

public struct QuotaLimit: Equatable {
    public let kind: QuotaKind
    public let usedPercent: Double
    public let remainingPercent: Double
    public let resetDate: Date?
    public let windowDurationMins: Int?

    public init(kind: QuotaKind, window: RateLimitWindow) {
        self.kind = kind
        self.usedPercent = window.usedPercent
        self.remainingPercent = max(0, min(100, 100 - window.usedPercent))
        self.resetDate = window.resetsAt.map { Date(timeIntervalSince1970: $0) }
        self.windowDurationMins = window.windowDurationMins
    }
}

public struct QuotaSnapshot: Equatable {
    public let fiveHour: QuotaLimit?
    public let weekly: QuotaLimit?
    public let fetchedAt: Date

    public init(fiveHour: QuotaLimit?, weekly: QuotaLimit?, fetchedAt: Date = Date()) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.fetchedAt = fetchedAt
    }
}

public enum QuotaParser {
    public static func snapshot(from response: GetAccountRateLimitsResponse, fetchedAt: Date = Date()) -> QuotaSnapshot {
        let selected = response.rateLimitsByLimitId?["codex"] ?? response.rateLimits
        return QuotaSnapshot(
            fiveHour: selected.primary.map { QuotaLimit(kind: .fiveHour, window: $0) },
            weekly: selected.secondary.map { QuotaLimit(kind: .weekly, window: $0) },
            fetchedAt: fetchedAt
        )
    }
}
