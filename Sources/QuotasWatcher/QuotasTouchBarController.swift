import AppKit
import QuotasWatcherCore

final class QuotasTouchBarController: NSObject, NSTouchBarDelegate {
    private let codexView = TouchBarProviderView(title: L10n.providerName(.codex))
    private let kimiView = TouchBarProviderView(title: L10n.providerName(.kimi))

    func makeTouchBar() -> NSTouchBar {
        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [.codexQuota, .kimiQuota]
        return touchBar
    }

    func update(with dashboard: QuotaDashboardState) {
        let codexSummary = dashboard.summary(for: .codex)
        let kimiSummary = dashboard.summary(for: .kimi)
        codexView.update(with: codexSummary)
        kimiView.update(with: kimiSummary)
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        switch identifier {
        case .codexQuota:
            item.view = codexView
        case .kimiQuota:
            item.view = kimiView
        default:
            return nil
        }
        return item
    }
}

final class TouchBarProviderView: NSView {
    private let titleLabel: NSTextField
    private let batteryView = SegmentedBatteryView()
    private let percentLabel = NSTextField(labelWithString: "--%")

    init(title: String) {
        self.titleLabel = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: 30))
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        batteryView.widthAnchor.constraint(equalToConstant: 72).isActive = true
        batteryView.heightAnchor.constraint(equalToConstant: 10).isActive = true

        let stack = NSStackView(views: [titleLabel, batteryView, percentLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func update(with summary: QuotaSummary) {
        batteryView.remainingPercent = summary.remainingPercent.map { Double($0) }
        if let remainingPercent = summary.remainingPercent {
            let marker = summary.isWeeklyFallback ? L10n.text("touchbar.weekly.marker") : ""
            percentLabel.stringValue = "\(remainingPercent)%\(marker)"
        } else {
            percentLabel.stringValue = "--%"
        }
    }
}

private extension NSTouchBarItem.Identifier {
    static let codexQuota = NSTouchBarItem.Identifier("com.quotaswatcher.touchbar.codex")
    static let kimiQuota = NSTouchBarItem.Identifier("com.quotaswatcher.touchbar.kimi")
}
