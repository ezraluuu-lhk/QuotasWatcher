import AppKit
import QuotasWatcherCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let viewController = QuotaPopoverViewController()
    private let client = CodexAppServerClient()
    private let touchBarController = QuotasTouchBarController()
    private var state = QuotaRefreshState()
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePopover()
        NSApp.touchBar = touchBarController.makeTouchBar()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        AppLog.shared.append("Application launched. Log file: \(AppLog.shared.fileURL.path)")
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }
        button.title = L10n.statusTitle(remainingPercent: nil, isRefreshing: false)
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 440, height: 190)
        popover.contentViewController = viewController
        viewController.touchBar = touchBarController.makeTouchBar()
        viewController.onRefresh = { [weak self] in self?.refresh() }
        viewController.onCopyError = { [weak self] in self?.copyCurrentError() }
        viewController.onCopyLog = { self.copyLog() }
        viewController.onQuit = { NSApp.terminate(nil) }
        viewController.update(with: state)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            viewController.view.window?.makeFirstResponder(viewController)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L10n.text("button.refresh"), action: #selector(refreshFromMenu), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: L10n.text("button.copy_error"), action: #selector(copyErrorFromMenu), keyEquivalent: "e"))
        menu.addItem(NSMenuItem(title: L10n.text("button.copy_log"), action: #selector(copyLogFromMenu), keyEquivalent: "l"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(format: L10n.text("menu.quit.format"), "QuotasWatcher"), action: #selector(quitFromMenu), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshFromMenu() {
        refresh()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    @objc private func copyErrorFromMenu() {
        copyCurrentError()
    }

    @objc private func copyLogFromMenu() {
        copyLog()
    }

    private func refresh() {
        guard !state.isRefreshing else {
            return
        }

        state.beginRefresh()
        render()

        Task {
            do {
                let snapshot = try await client.fetchRateLimits()
                await MainActor.run {
                    state.finishRefresh(with: .success(snapshot))
                    AppLog.shared.append("Refresh succeeded.")
                    render()
                }
            } catch {
                await MainActor.run {
                    state.finishRefresh(with: .failure(error))
                    AppLog.shared.append("Refresh failed: \(error.localizedDescription)")
                    render()
                }
            }
        }
    }

    private func copyCurrentError() {
        let text = state.errorMessage ?? L10n.text("clipboard.no_error")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyLog() {
        let text = AppLog.shared.readText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.isEmpty ? L10n.text("clipboard.no_log") : text, forType: .string)
    }

    private func render() {
        updateStatusTitle()
        viewController.update(with: state)
        touchBarController.update(with: state.snapshot)
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else {
            return
        }

        if let remaining = state.snapshot?.fiveHour?.remainingPercent {
            button.title = L10n.statusTitle(remainingPercent: Int(round(remaining)), isRefreshing: state.isRefreshing)
        } else {
            button.title = L10n.statusTitle(remainingPercent: nil, isRefreshing: state.isRefreshing)
        }
    }
}

final class QuotaPopoverViewController: NSViewController {
    var onRefresh: (() -> Void)?
    var onCopyError: (() -> Void)?
    var onCopyLog: (() -> Void)?
    var onQuit: (() -> Void)?

    private let fiveHourRow = QuotaRowView(title: L10n.text("quota.five_hour"))
    private let weeklyRow = QuotaRowView(title: L10n.text("quota.weekly"))
    private let statusLabel = NSTextField(labelWithString: L10n.text("status.waiting"))
    private let refreshButton = NSButton(title: L10n.text("button.refresh"), target: nil, action: nil)
    private let copyErrorButton = NSButton(title: L10n.text("button.copy_error"), target: nil, action: nil)
    private let copyLogButton = NSButton(title: L10n.text("button.copy_log"), target: nil, action: nil)
    private let quitButton = NSButton(title: L10n.text("button.quit"), target: nil, action: nil)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 190))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let title = NSTextField(labelWithString: L10n.text("app.title"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let header = NSStackView(views: [title, NSView(), statusLabel])
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
        footer.addArrangedSubview(copyLogButton)
        footer.addArrangedSubview(quitButton)

        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        copyErrorButton.bezelStyle = .rounded
        copyErrorButton.target = self
        copyErrorButton.action = #selector(copyErrorClicked)
        copyLogButton.bezelStyle = .rounded
        copyLogButton.target = self
        copyLogButton.action = #selector(copyLogClicked)
        quitButton.bezelStyle = .rounded
        quitButton.target = self
        quitButton.action = #selector(quitClicked)

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(fiveHourRow)
        stack.addArrangedSubview(weeklyRow)
        stack.addArrangedSubview(footer)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            fiveHourRow.heightAnchor.constraint(equalToConstant: 44),
            weeklyRow.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    func update(with state: QuotaRefreshState) {
        fiveHourRow.update(with: state.snapshot?.fiveHour)
        weeklyRow.update(with: state.snapshot?.weekly)
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
    }

    @objc private func refreshClicked() {
        onRefresh?()
    }

    @objc private func copyErrorClicked() {
        onCopyError?()
    }

    @objc private func copyLogClicked() {
        onCopyLog?()
    }

    @objc private func quitClicked() {
        onQuit?()
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

final class QuotasTouchBarController: NSObject, NSTouchBarDelegate {
    private let fiveHourView = TouchBarQuotaView(title: L10n.text("quota.five_hour"))
    private let weeklyView = TouchBarQuotaView(title: L10n.text("quota.weekly"))

    func makeTouchBar() -> NSTouchBar {
        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [.fiveHourQuota, .weeklyQuota]
        return touchBar
    }

    func update(with snapshot: QuotaSnapshot?) {
        fiveHourView.update(with: snapshot?.fiveHour)
        weeklyView.update(with: snapshot?.weekly)
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        switch identifier {
        case .fiveHourQuota:
            item.view = fiveHourView
        case .weeklyQuota:
            item.view = weeklyView
        default:
            return nil
        }
        return item
    }
}

final class TouchBarQuotaView: NSView {
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

    func update(with limit: QuotaLimit?) {
        batteryView.remainingPercent = limit?.remainingPercent
        if let limit {
            percentLabel.stringValue = "\(Int(round(limit.remainingPercent)))%"
        } else {
            percentLabel.stringValue = "--%"
        }
    }
}

private extension NSTouchBarItem.Identifier {
    static let fiveHourQuota = NSTouchBarItem.Identifier("com.quotaswatcher.touchbar.fiveHour")
    static let weeklyQuota = NSTouchBarItem.Identifier("com.quotaswatcher.touchbar.weekly")
}

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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
