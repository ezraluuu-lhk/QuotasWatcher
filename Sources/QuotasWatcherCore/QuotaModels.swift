import Foundation

public struct RateLimitWindow: Codable, Equatable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: TimeInterval?
}

public struct RateLimitSnapshot: Codable, Equatable {
    public let limitId: String?
    public let limitName: String?
    public let primary: RateLimitWindow?
    public let secondary: RateLimitWindow?
}

public struct GetAccountRateLimitsResponse: Codable, Equatable {
    public let rateLimits: RateLimitSnapshot
    public let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    public let rateLimitResetCredits: RateLimitResetCreditsSummary?
}

public struct RateLimitResetCreditsSummary: Codable, Equatable {
    public let availableCount: Int
}

public enum QuotaKind: String, Codable, Equatable {
    case fiveHour
    case weekly
}

public struct QuotaLimit: Codable, Equatable {
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

public struct QuotaSnapshot: Codable, Equatable {
    public let fiveHour: QuotaLimit?
    public let weekly: QuotaLimit?
    public let fetchedAt: Date
    public let availableResetCount: Int?

    public init(
        fiveHour: QuotaLimit?,
        weekly: QuotaLimit?,
        fetchedAt: Date = Date(),
        availableResetCount: Int? = nil
    ) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.fetchedAt = fetchedAt
        self.availableResetCount = availableResetCount
    }
}

public enum QuotaParser {
    public static func snapshot(from response: GetAccountRateLimitsResponse, fetchedAt: Date = Date()) -> QuotaSnapshot {
        let selected = response.rateLimitsByLimitId?["codex"] ?? response.rateLimits
        let windows = [selected.primary, selected.secondary].compactMap { $0 }
        let fiveHourWindow = windows.first { $0.windowDurationMins == 5 * 60 }
            ?? selected.primary.flatMap { $0.windowDurationMins == nil ? $0 : nil }
        let weeklyWindow = windows.first { $0.windowDurationMins == 7 * 24 * 60 }
            ?? selected.secondary.flatMap { $0.windowDurationMins == nil ? $0 : nil }

        return QuotaSnapshot(
            fiveHour: fiveHourWindow.map { QuotaLimit(kind: .fiveHour, window: $0) },
            weekly: weeklyWindow.map { QuotaLimit(kind: .weekly, window: $0) },
            fetchedAt: fetchedAt,
            availableResetCount: response.rateLimitResetCredits?.availableCount
        )
    }
}
