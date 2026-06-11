import Foundation

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

    static func statusTitle(remainingPercent: Int?, isRefreshing: Bool) -> String {
        let suffix = isRefreshing ? " ..." : ""
        guard let remainingPercent else {
            return String(format: text("status.item.unavailable.format"), suffix)
        }
        return String(format: text("status.item.percent.format"), remainingPercent, suffix)
    }
}
