import AppKit
import QuotasWatcherCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let viewController = QuotaPopoverViewController()
    private let touchBarController = QuotasTouchBarController()
    private let barkClient = BarkPushClient()
    private let barkPreferences = BarkNotificationPreferences()
    private var dashboard = QuotaDashboardState()
    private var coordinator: QuotaRefreshCoordinator?
    private var refreshTimer: Timer?
    private lazy var barkSettingsController = BarkSettingsController(
        preferences: barkPreferences,
        client: barkClient
    )

    override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        coordinator = QuotaRefreshCoordinator(
            providers: [
                .codex: CodexQuotaProvider(),
                .kimi: KimiCodeQuotaClient()
            ],
            onUpdate: { [weak self] updatedDashboard in
                self?.dashboard = updatedDashboard
                self?.render()
            },
            onCodexSuccess: { [weak self] snapshot in
                self?.handleCodexSuccess(snapshot)
            }
        )

        configureApplicationMenu()
        configureStatusItem()
        configurePopover()
        NSApp.touchBar = touchBarController.makeTouchBar()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task {
                await self?.coordinator?.refreshAll()
            }
        }
        AppLog.shared.append("Application launched. Log file: \(AppLog.shared.fileURL.path)")
        Task {
            await coordinator?.refreshAll()
        }
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()

        let applicationMenuItem = NSMenuItem()
        mainMenu.addItem(applicationMenuItem)
        let applicationMenu = NSMenu(title: "QuotasWatcher")
        applicationMenu.addItem(NSMenuItem(
            title: String(format: L10n.text("menu.quit.format"), "QuotasWatcher"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        applicationMenuItem.submenu = applicationMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: L10n.text("menu.edit"))
        editMenu.addItem(NSMenuItem(title: L10n.text("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: L10n.text("menu.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: L10n.text("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: L10n.text("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: L10n.text("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: L10n.text("menu.select_all"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let controlPasteItem = NSMenuItem(title: L10n.text("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        controlPasteItem.keyEquivalentModifierMask = [.control]
        controlPasteItem.isHidden = true
        controlPasteItem.allowsKeyEquivalentWhenHidden = true
        editMenu.addItem(controlPasteItem)
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }
        button.title = L10n.statusTitle(for: dashboard.summary(for: dashboard.selectedProvider), isRefreshing: false)
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 470, height: 240)
        popover.contentViewController = viewController
        viewController.touchBar = touchBarController.makeTouchBar()
        viewController.onRefresh = { [weak self] in
            Task {
                await self?.coordinator?.refreshAll()
            }
        }
        viewController.onCopyError = { [weak self] in self?.copyCurrentError() }
        viewController.onOpenLog = { [weak self] in self?.openLog() }
        viewController.onBarkSettings = { [weak self] in self?.barkSettingsController.showWindow() }
        viewController.onQuit = { NSApp.terminate(nil) }
        viewController.onProviderSelected = { [weak self] provider in
            Task {
                await self?.coordinator?.selectProvider(provider)
            }
        }
        viewController.update(with: dashboard)
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
        menu.addItem(NSMenuItem(title: L10n.text("button.open_log"), action: #selector(openLogFromMenu), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: L10n.text("button.bark"), action: #selector(showBarkSettingsFromMenu), keyEquivalent: "b"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(format: L10n.text("menu.quit.format"), "QuotasWatcher"), action: #selector(quitFromMenu), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshFromMenu() {
        Task {
            await coordinator?.refreshAll()
        }
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    @objc private func copyErrorFromMenu() {
        copyCurrentError()
    }

    @objc private func openLogFromMenu() {
        openLog()
    }

    @objc private func showBarkSettingsFromMenu() {
        barkSettingsController.showWindow()
    }

    private func handleCodexSuccess(_ snapshot: QuotaSnapshot) {
        let previousObservation = barkPreferences.loadLastObservation()
        let resetEvents = previousObservation.map {
            QuotaResetDetector.events(previous: $0, current: snapshot)
        } ?? []
        barkPreferences.saveLastObservation(snapshot)
        sendBarkNotifications(resetEvents)
    }

    private func copyCurrentError() {
        let text = dashboard.errorMessage(for: dashboard.selectedProvider) ?? L10n.text("clipboard.no_error")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openLog() {
        NSWorkspace.shared.open(AppLog.shared.fileURL)
    }

    private func sendBarkNotifications(_ events: [QuotaResetEvent]) {
        let settings = barkPreferences.loadSettings()
        guard !settings.deviceKey.isEmpty else {
            return
        }

        for event in events where settings.isEnabled(event.kind) {
            let content = L10n.barkNotification(for: event)
            Task {
                do {
                    try await barkClient.send(
                        deviceKey: settings.deviceKey,
                        title: content.title,
                        body: content.body
                    )
                    AppLog.shared.append("Bark notification sent for \(event.kind.rawValue).")
                } catch {
                    AppLog.shared.append("Bark notification failed for \(event.kind.rawValue): \(error.localizedDescription)")
                }
            }
        }
    }

    private func render() {
        updateStatusTitle()
        viewController.update(with: dashboard)
        touchBarController.update(with: dashboard)
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else {
            return
        }
        let summary = dashboard.summary(for: dashboard.selectedProvider)
        button.title = L10n.statusTitle(for: summary, isRefreshing: dashboard.isRefreshing(dashboard.selectedProvider))
    }
}
