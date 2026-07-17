import Foundation
import QuotasWatcherCore

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

    static func statusTitle(remainingPercent: Int?, isRefreshing: Bool) -> String {
        let suffix = isRefreshing ? " ..." : ""
        guard let remainingPercent else {
            return String(format: text("status.item.unavailable.format"), suffix)
        }
        return String(format: text("status.item.percent.format"), remainingPercent, suffix)
    }

    static func weeklyStatusTitle(remainingPercent: Int, isRefreshing: Bool) -> String {
        let suffix = isRefreshing ? " ..." : ""
        return String(format: text("status.item.weekly.percent.format"), remainingPercent, suffix)
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
