import Foundation
import QuotasWatcherCore

enum DateFormatters {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static let reset: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

enum L10n {
    static func text(_ key: String) -> String {
        let mainValue = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        if mainValue != key {
            return mainValue
        }
        return Bundle.module.localizedString(forKey: key, value: key, table: nil)
    }

    static func updating(_ time: String) -> String {
        String(format: text("status.updated.format"), time)
    }

    static func reset(_ time: String) -> String {
        String(format: text("quota.reset.format"), time)
    }

    static func resetsAvailable(_ count: Int) -> String {
        let key = count == 1 ? "quota.resets_available.one.format" : "quota.resets_available.other.format"
        return String(format: text(key), count)
    }

    static func statusTitle(for summary: QuotaSummary, isRefreshing: Bool) -> String {
        let suffix = isRefreshing ? " ..." : ""
        let providerKey = summary.provider.statusItemLabelKey
        guard let remainingPercent = summary.remainingPercent else {
            let formatKey = summary.provider.statusItemUnavailableLabelKey
            return String(format: text(formatKey), suffix)
        }
        if summary.isWeeklyFallback {
            let formatKey = summary.provider.statusItemWeeklyLabelKey
            return String(format: text(formatKey), remainingPercent, suffix)
        }
        let formatKey = providerKey
        return String(format: text(formatKey), remainingPercent, suffix)
    }

    static func providerName(_ provider: QuotaProviderID) -> String {
        text(provider.localizedKey)
    }

    static func barkNotification(for event: QuotaResetEvent) -> (title: String, body: String) {
        switch event.kind {
        case .fiveHourReset:
            let remaining = Int(round(event.changes.first?.currentRemainingPercent ?? 0))
            return (
                text("bark.push.five_hour.title"),
                String(format: text("bark.push.scheduled.body.format"), remaining)
            )
        case .weeklyReset:
            let remaining = Int(round(event.changes.first?.currentRemainingPercent ?? 0))
            return (
                text("bark.push.weekly.title"),
                String(format: text("bark.push.scheduled.body.format"), remaining)
            )
        case .otherReset:
            let changes = event.changes.map { change in
                let label = change.kind == .fiveHour ? text("quota.five_hour") : text("quota.weekly")
                return String(
                    format: text("bark.push.other.change.format"),
                    label,
                    Int(round(change.previousRemainingPercent)),
                    Int(round(change.currentRemainingPercent))
                )
            }
            return (text("bark.push.other.title"), changes.joined(separator: "\n"))
        case .resetBankIncrease:
            let change = event.resetBankChange
            return (
                text("bark.push.reset_bank.title"),
                String(
                    format: text("bark.push.reset_bank.body.format"),
                    change?.previousCount ?? 0,
                    change?.currentCount ?? 0
                )
            )
        }
    }
}
