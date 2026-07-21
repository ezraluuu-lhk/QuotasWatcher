import AppKit
import QuotasWatcherCore

final class QuotaPopoverViewController: NSViewController {
    var onRefresh: (() -> Void)?
    var onCopyError: (() -> Void)?
    var onOpenLog: (() -> Void)?
    var onBarkSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onProviderSelected: ((QuotaProviderID) -> Void)?

    private let providerSegmentedControl = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: nil, action: nil)
    private let fiveHourRow = QuotaRowView(title: L10n.text("quota.five_hour"))
    private let weeklyRow = QuotaRowView(title: L10n.text("quota.weekly"))
    private let fiveHourUnavailableBanner = QuotaBannerView(text: L10n.text("quota.five_hour.unavailable"))
    private let resetCreditsLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: L10n.text("status.waiting"))
    private let refreshButton = NSButton(title: L10n.text("button.refresh"), target: nil, action: nil)
    private let copyErrorButton = NSButton(title: L10n.text("button.copy_error"), target: nil, action: nil)
    private let openLogButton = NSButton(title: L10n.text("button.open_log"), target: nil, action: nil)
    private let barkButton = NSButton(title: L10n.text("button.bark"), target: nil, action: nil)
    private let quitButton = NSButton(title: L10n.text("button.quit"), target: nil, action: nil)
    private var currentDashboard: QuotaDashboardState?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 240))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        providerSegmentedControl.segmentCount = QuotaProviderID.allCases.count
        for (index, provider) in QuotaProviderID.allCases.enumerated() {
            providerSegmentedControl.setLabel(L10n.providerName(provider), forSegment: index)
            providerSegmentedControl.setWidth(80, forSegment: index)
        }
        providerSegmentedControl.target = self
        providerSegmentedControl.action = #selector(providerSegmentChanged)

        let title = NSTextField(labelWithString: L10n.text("app.title"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        resetCreditsLabel.font = .systemFont(ofSize: 11, weight: .medium)
        resetCreditsLabel.textColor = .systemBlue
        resetCreditsLabel.isHidden = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let header = NSStackView(views: [title, resetCreditsLabel, NSView(), statusLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.addArrangedSubview(NSView())
        footer.addArrangedSubview(refreshButton)
        footer.addArrangedSubview(copyErrorButton)
        footer.addArrangedSubview(openLogButton)
        footer.addArrangedSubview(barkButton)
        footer.addArrangedSubview(quitButton)

        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        copyErrorButton.bezelStyle = .rounded
        copyErrorButton.target = self
        copyErrorButton.action = #selector(copyErrorClicked)
        openLogButton.bezelStyle = .rounded
        openLogButton.target = self
        openLogButton.action = #selector(openLogClicked)
        barkButton.bezelStyle = .rounded
        barkButton.target = self
        barkButton.action = #selector(barkClicked)
        quitButton.bezelStyle = .rounded
        quitButton.target = self
        quitButton.action = #selector(quitClicked)

        stack.addArrangedSubview(providerSegmentedControl)
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(fiveHourUnavailableBanner)
        stack.addArrangedSubview(fiveHourRow)
        stack.addArrangedSubview(weeklyRow)
        stack.addArrangedSubview(footer)
        fiveHourUnavailableBanner.isHidden = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            providerSegmentedControl.heightAnchor.constraint(equalToConstant: 24),
            fiveHourUnavailableBanner.heightAnchor.constraint(equalToConstant: 34),
            fiveHourRow.heightAnchor.constraint(equalToConstant: 44),
            weeklyRow.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    func update(with dashboard: QuotaDashboardState) {
        _ = view
        currentDashboard = dashboard
        let provider = dashboard.selectedProvider
        let state = dashboard.selectedState

        if let index = QuotaProviderID.allCases.firstIndex(of: provider),
           providerSegmentedControl.selectedSegment != index {
            providerSegmentedControl.selectedSegment = index
        }

        fiveHourRow.update(with: state.snapshot?.fiveHour)
        weeklyRow.update(with: state.snapshot?.weekly)
        let isShowingWeeklyFallback = state.snapshot?.fiveHour == nil && state.snapshot?.weekly != nil
        fiveHourUnavailableBanner.isHidden = !isShowingWeeklyFallback

        let isCodex = provider == .codex
        if isCodex, let availableResetCount = state.snapshot?.availableResetCount {
            resetCreditsLabel.stringValue = L10n.resetsAvailable(availableResetCount)
            resetCreditsLabel.isHidden = false
        } else {
            resetCreditsLabel.isHidden = true
        }

        barkButton.isHidden = !isCodex

        refreshButton.isEnabled = !state.isRefreshing
        copyErrorButton.isEnabled = state.errorMessage != nil

        if state.isRefreshing {
            statusLabel.stringValue = L10n.text("status.refreshing")
        } else if let error = state.errorMessage {
            statusLabel.stringValue = error
        } else if let fetchedAt = state.snapshot?.fetchedAt {
            statusLabel.stringValue = L10n.updating(DateFormatters.time.string(from: fetchedAt))
        } else {
            statusLabel.stringValue = L10n.text("status.not_loaded")
        }

        let baseHeight: CGFloat = 240
        let extraHeight: CGFloat = isShowingWeeklyFallback ? 48 : 0
        preferredContentSize = NSSize(width: 470, height: baseHeight + extraHeight)
    }

    @objc private func providerSegmentChanged() {
        let index = providerSegmentedControl.selectedSegment
        guard index >= 0, index < QuotaProviderID.allCases.count else {
            return
        }
        let provider = QuotaProviderID.allCases[index]
        onProviderSelected?(provider)
    }

    @objc private func refreshClicked() {
        onRefresh?()
    }

    @objc private func copyErrorClicked() {
        onCopyError?()
    }

    @objc private func openLogClicked() {
        onOpenLog?()
    }

    @objc private func barkClicked() {
        onBarkSettings?()
    }

    @objc private func quitClicked() {
        onQuit?()
    }
}

final class QuotaBannerView: NSView {
    init(text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
        layer?.cornerRadius = 6

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class QuotaRowView: NSView {
    private let titleLabel: NSTextField
    private let batteryView = SegmentedBatteryView()
    private let percentLabel = NSTextField(labelWithString: "--%")
    private let resetLabel = NSTextField(labelWithString: L10n.text("quota.reset.placeholder"))

    init(title: String) {
        self.titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        percentLabel.alignment = .right
        percentLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true

        resetLabel.font = .systemFont(ofSize: 11)
        resetLabel.textColor = .secondaryLabelColor

        let top = NSStackView(views: [titleLabel, batteryView, percentLabel])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 10

        let stack = NSStackView(views: [top, resetLabel])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            batteryView.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    func update(with limit: QuotaLimit?) {
        guard let limit else {
            batteryView.remainingPercent = nil
            percentLabel.stringValue = "--%"
            resetLabel.stringValue = L10n.text("quota.reset.placeholder")
            return
        }

        batteryView.remainingPercent = limit.remainingPercent
        percentLabel.stringValue = "\(Int(round(limit.remainingPercent)))%"
        if let resetDate = limit.resetDate {
            resetLabel.stringValue = L10n.reset(DateFormatters.reset.string(from: resetDate))
        } else {
            resetLabel.stringValue = L10n.text("quota.reset.placeholder")
        }
    }
}

final class SegmentedBatteryView: NSView {
    var remainingPercent: Double? {
        didSet { needsDisplay = true }
    }

    private let segments = 12

    override var intrinsicContentSize: NSSize {
        NSSize(width: 180, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = bounds.insetBy(dx: 0, dy: 1)
        let gap: CGFloat = 3
        let width = (bounds.width - CGFloat(segments - 1) * gap) / CGFloat(segments)
        let filledSegments = Int(ceil(((remainingPercent ?? 0) / 100) * Double(segments)))
        let color = fillColor(for: remainingPercent)

        for index in 0..<segments {
            let rect = NSRect(
                x: bounds.minX + CGFloat(index) * (width + gap),
                y: bounds.minY,
                width: width,
                height: bounds.height
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            if remainingPercent == nil {
                NSColor.quaternaryLabelColor.setFill()
            } else if index < filledSegments {
                color.setFill()
            } else {
                NSColor.separatorColor.withAlphaComponent(0.45).setFill()
            }
            path.fill()
        }
    }

    private func fillColor(for percent: Double?) -> NSColor {
        guard let percent else {
            return .quaternaryLabelColor
        }
        if percent <= 15 {
            return .systemRed
        }
        if percent <= 35 {
            return .systemOrange
        }
        return .systemGreen
    }
}
