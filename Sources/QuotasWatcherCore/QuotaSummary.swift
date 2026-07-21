import Foundation

public struct QuotaSummary: Equatable, Sendable {
    public let provider: QuotaProviderID
    public let remainingPercent: Int?
    public let isWeeklyFallback: Bool

    public init(provider: QuotaProviderID, remainingPercent: Int?, isWeeklyFallback: Bool) {
        self.provider = provider
        self.remainingPercent = remainingPercent
        self.isWeeklyFallback = isWeeklyFallback
    }

    public static func primary(for snapshot: QuotaSnapshot?, provider: QuotaProviderID) -> QuotaSummary {
        if let fiveHour = snapshot?.fiveHour {
            return QuotaSummary(
                provider: provider,
                remainingPercent: Int(round(fiveHour.remainingPercent)),
                isWeeklyFallback: false
            )
        }
        if let weekly = snapshot?.weekly {
            return QuotaSummary(
                provider: provider,
                remainingPercent: Int(round(weekly.remainingPercent)),
                isWeeklyFallback: true
            )
        }
        return QuotaSummary(provider: provider, remainingPercent: nil, isWeeklyFallback: false)
    }
}
