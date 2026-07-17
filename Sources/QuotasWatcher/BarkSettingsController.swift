import AppKit
import QuotasWatcherCore

final class BarkSettingsController: NSObject, NSWindowDelegate {
    private let preferences: BarkNotificationPreferences
    private let client: BarkPushClient

    private var settingsWindow: NSWindow?
    private let deviceKeyField = NSSecureTextField(string: "")
    private let testButton = NSButton(title: L10n.text("bark.test.button"), target: nil, action: nil)
    private let fiveHourCheckbox = NSButton(checkboxWithTitle: L10n.text("bark.notify.five_hour"), target: nil, action: nil)
    private let weeklyCheckbox = NSButton(checkboxWithTitle: L10n.text("bark.notify.weekly"), target: nil, action: nil)
    private let otherCheckbox = NSButton(checkboxWithTitle: L10n.text("bark.notify.other"), target: nil, action: nil)
    private let resetBankCheckbox = NSButton(checkboxWithTitle: L10n.text("bark.notify.reset_bank"), target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: L10n.text("button.save"), target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.text("button.cancel"), target: nil, action: nil)

    init(preferences: BarkNotificationPreferences, client: BarkPushClient) {
        self.preferences = preferences
        self.client = client
        super.init()
    }

    func showWindow() {
        if settingsWindow == nil {
            settingsWindow = makeWindow()
        }
        loadSettings()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("bark.settings.title")
        window.isReleasedWhenClosed = false
        window.delegate = self

        let contentView = NSView()
        window.contentView = contentView

        let titleLabel = NSTextField(labelWithString: L10n.text("bark.settings.heading"))
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)

        let descriptionLabel = NSTextField(wrappingLabelWithString: L10n.text("bark.settings.description"))
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.font = .systemFont(ofSize: 12)

        let keyLabel = NSTextField(labelWithString: L10n.text("bark.key.label"))
        keyLabel.alignment = .right
        keyLabel.widthAnchor.constraint(equalToConstant: 74).isActive = true

        deviceKeyField.placeholderString = L10n.text("bark.key.placeholder")
        deviceKeyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        testButton.target = self
        testButton.action = #selector(testConnection)
        testButton.bezelStyle = .rounded

        let keyRow = NSStackView(views: [keyLabel, deviceKeyField, testButton])
        keyRow.orientation = .horizontal
        keyRow.alignment = .centerY
        keyRow.spacing = 8

        let checkboxStack = NSStackView(views: [fiveHourCheckbox, weeklyCheckbox, otherCheckbox, resetBankCheckbox])
        checkboxStack.orientation = .vertical
        checkboxStack.alignment = .leading
        checkboxStack.spacing = 8

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail

        saveButton.target = self
        saveButton.action = #selector(saveSettings)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let footer = NSStackView(views: [statusLabel, NSView(), cancelButton, saveButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let stack = NSStackView(views: [titleLabel, descriptionLabel, keyRow, checkboxStack, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        keyRow.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            descriptionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            keyRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            checkboxStack.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 82),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40)
        ])
        return window
    }

    private func loadSettings() {
        let settings = preferences.loadSettings()
        deviceKeyField.stringValue = settings.deviceKey
        fiveHourCheckbox.state = settings.notifyFiveHourReset ? .on : .off
        weeklyCheckbox.state = settings.notifyWeeklyReset ? .on : .off
        otherCheckbox.state = settings.notifyOtherReset ? .on : .off
        resetBankCheckbox.state = settings.notifyResetBankIncrease ? .on : .off
        statusLabel.stringValue = ""
        testButton.isEnabled = true
    }

    @objc private func testConnection() {
        let deviceKey = deviceKeyField.stringValue
        do {
            _ = try BarkPushClient.endpoint(for: deviceKey)
        } catch {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = L10n.text("bark.validation.invalid_key")
            return
        }

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = L10n.text("bark.test.testing")
        testButton.isEnabled = false

        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.send(
                    deviceKey: deviceKey,
                    title: L10n.text("bark.test.title"),
                    body: L10n.text("bark.test.body")
                )
                await MainActor.run {
                    self.statusLabel.textColor = .systemGreen
                    self.statusLabel.stringValue = L10n.text("bark.test.success")
                    self.testButton.isEnabled = true
                }
            } catch {
                await MainActor.run {
                    self.statusLabel.textColor = .systemRed
                    self.statusLabel.stringValue = L10n.text("bark.test.failure")
                    self.testButton.isEnabled = true
                }
                AppLog.shared.append("Bark connection test failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func saveSettings() {
        let input = deviceKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasEnabledNotification = fiveHourCheckbox.state == .on
            || weeklyCheckbox.state == .on
            || otherCheckbox.state == .on
            || resetBankCheckbox.state == .on

        if hasEnabledNotification && input.isEmpty {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = L10n.text("bark.validation.key_required")
            return
        }
        var deviceKey = ""
        if !input.isEmpty {
            do {
                deviceKey = try BarkPushClient.deviceKey(from: input)
            } catch {
                statusLabel.textColor = .systemRed
                statusLabel.stringValue = L10n.text("bark.validation.invalid_key")
                return
            }
        }

        preferences.saveSettings(BarkNotificationSettings(
            deviceKey: deviceKey,
            notifyFiveHourReset: fiveHourCheckbox.state == .on,
            notifyWeeklyReset: weeklyCheckbox.state == .on,
            notifyOtherReset: otherCheckbox.state == .on,
            notifyResetBankIncrease: resetBankCheckbox.state == .on
        ))
        settingsWindow?.close()
    }

    @objc private func cancel() {
        settingsWindow?.close()
    }
}
