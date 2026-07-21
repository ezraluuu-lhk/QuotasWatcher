import Foundation

enum KimiQuotaParser {
    static func snapshot(from response: KimiUsageResponse, fetchedAt: Date = Date()) throws -> QuotaSnapshot {
        let fiveHour = try? fiveHourLimit(from: response.limits)
        let weekly = try? weeklyLimit(from: response.usage, limits: response.limits)

        guard fiveHour != nil || weekly != nil else {
            throw KimiCodeError.usageInvalidPayload("No usable five-hour or weekly quota found")
        }

        return QuotaSnapshot(
            fiveHour: fiveHour,
            weekly: weekly,
            fetchedAt: fetchedAt,
            availableResetCount: nil
        )
    }

    private static func fiveHourLimit(from limits: [KimiUsageLimit]?) throws -> QuotaLimit? {
        findLimit(in: limits, matchingMinutes: 300)
    }

    private static func weeklyLimit(from usage: KimiUsageSummary?, limits: [KimiUsageLimit]?) throws -> QuotaLimit? {
        if let usage = usage, let limit = quotaLimit(kind: .weekly, summary: usage) {
            return limit
        }

        return findLimit(in: limits, matchingMinutes: 10_080)
    }

    private static func findLimit(in limits: [KimiUsageLimit]?, matchingMinutes targetMinutes: Double) -> QuotaLimit? {
        guard let limits = limits else { return nil }

        for limit in limits {
            guard let windowMinutes = windowMinutes(from: limit.effectiveWindow),
                  windowMinutes == targetMinutes
            else {
                continue
            }

            if let limit = quotaLimit(kind: targetMinutes == 300 ? .fiveHour : .weekly, detail: limit.effectiveDetail) {
                return limit
            }
        }

        return nil
    }

    private static func windowMinutes(from window: KimiUsageWindow?) -> Double? {
        guard let window = window,
              let duration = window.duration?.doubleValue,
              duration.isFinite,
              duration > 0 else {
            return nil
        }

        if let normalizedUnit = normalizeTimeUnit(window.timeUnit) {
            return minutes(duration: duration, unit: normalizedUnit)
        }

        if duration == 300 || duration == 10_080 {
            return duration
        }

        return nil
    }

    private static func quotaLimit(kind: QuotaKind, summary: KimiUsageSummary) -> QuotaLimit? {
        guard let limitValue = summary.limit?.doubleValue,
              limitValue.isFinite,
              limitValue > 0 else {
            return nil
        }

        let used: Double
        if let explicitUsed = summary.used?.doubleValue {
            used = explicitUsed
        } else if let remaining = summary.remaining?.doubleValue {
            used = limitValue - remaining
        } else {
            return nil
        }

        return makeLimit(kind: kind, limit: limitValue, used: used, resetTime: summary.resetTime)
    }

    private static func quotaLimit(kind: QuotaKind, detail: KimiUsageDetail?) -> QuotaLimit? {
        guard let detail = detail,
              let limitValue = detail.limit?.doubleValue,
              limitValue.isFinite,
              limitValue > 0 else {
            return nil
        }

        let used: Double
        if let explicitUsed = detail.used?.doubleValue {
            used = explicitUsed
        } else if let remaining = detail.remaining?.doubleValue {
            used = limitValue - remaining
        } else {
            return nil
        }

        return makeLimit(kind: kind, limit: limitValue, used: used, resetTime: detail.resetTime)
    }

    private static func makeLimit(kind: QuotaKind, limit: Double, used: Double, resetTime: String?) -> QuotaLimit? {
        guard limit.isFinite, limit > 0 else { return nil }

        // Non-finite counts are rejected rather than coerced: fabricating a
        // zero here would invent quota data. Negative or over-limit counts are
        // preserved through the calculation; only the final percentage is
        // clamped to 0...100 by QuotaLimit.
        guard used.isFinite else { return nil }
        let usedPercent = (used / limit) * 100
        let windowDurationMins = kind == .fiveHour ? 300 : 10_080
        let resetDate = resetTime.flatMap { parseISO8601($0) }

        let window = RateLimitWindow(
            usedPercent: usedPercent,
            windowDurationMins: windowDurationMins,
            resetsAt: resetDate?.timeIntervalSince1970
        )

        return QuotaLimit(kind: kind, window: window)
    }

    private static func normalizeTimeUnit(_ unit: String?) -> String? {
        guard let unit = unit?.lowercased() else { return nil }
        let minuteForms = Set([
            "minute", "minutes", "min", "mins",
            "time_unit_minute", "timeunitminute"
        ])
        let hourForms = Set([
            "hour", "hours", "hr", "hrs",
            "time_unit_hour", "timeunithour"
        ])
        let dayForms = Set([
            "day", "days",
            "time_unit_day", "timeunitday"
        ])
        let secondForms = Set([
            "second", "seconds", "sec", "secs",
            "time_unit_second", "timeunitsecond"
        ])
        if minuteForms.contains(unit) { return "minute" }
        if hourForms.contains(unit) { return "hour" }
        if dayForms.contains(unit) { return "day" }
        if secondForms.contains(unit) { return "second" }
        return nil
    }

    private static func minutes(duration: Double, unit: String?) -> Double? {
        guard let unit = unit else { return nil }
        switch unit {
        case "second":
            return duration / 60
        case "minute":
            return duration
        case "hour":
            return duration * 60
        case "day":
            return duration * 24 * 60
        default:
            return nil
        }
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
