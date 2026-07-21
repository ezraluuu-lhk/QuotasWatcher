import AppKit
import QuotasWatcherCore

/// Keeps an already-open status-item popover fully visible and associated
/// with its status item while a fullscreen auto-hidden menu bar hides or
/// reappears.
///
/// The maintainer observes only public positioning-view/window/display
/// geometry notifications and only while the popover is shown — including
/// the shown popover window's own resize notification, so dynamic
/// 240/288-point content changes schedule a correction. Notification
/// bursts are coalesced on the main run loop into a single reposition pass
/// that refreshes the popover's supported `positioningRect` relationship
/// and, when AppKit still leaves the popover window off-screen, constrains
/// the window to the active screen's visible frame with a small edge
/// margin. It never closes the popover, never touches dashboard state or
/// refresh coordination, and uses no private APIs or polling.
final class PopoverPositionMaintainer: NSObject, NSPopoverDelegate {
    private weak var popover: NSPopover?
    private weak var statusItem: NSStatusItem?
    private var observers: [NSObjectProtocol] = []
    private var coalescer: PopoverRepositionCoalescer!

    init(popover: NSPopover, statusItem: NSStatusItem) {
        self.popover = popover
        self.statusItem = statusItem
        super.init()
        coalescer = PopoverRepositionCoalescer(
            schedule: { work in DispatchQueue.main.async(execute: work) },
            apply: { [weak self] in
                self?.repositionPopoverIfNeeded()
            }
        )
    }

    deinit {
        removeObservers()
    }

    /// Stops all observation and pending work. Safe to call when already
    /// stopped; used on popover close and application termination.
    func stop() {
        removeObservers()
        coalescer.setShown(false)
    }

    // MARK: NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        coalescer.setShown(true)
        startObserving()
        // Correct once after show in case the popover opened against a
        // transiently revealed menu bar that is already sliding away.
        coalescer.request()
    }

    func popoverDidClose(_ notification: Notification) {
        stop()
    }

    // MARK: Observation

    private func startObserving() {
        guard observers.isEmpty else {
            return
        }
        let center = NotificationCenter.default
        let request: (Notification) -> Void = { [weak self] _ in
            self?.coalescer.request()
        }

        // The status bar window hosting the status-item button moves when the
        // auto-hidden menu bar hides or reappears in a fullscreen Space.
        if let buttonWindow = statusItem?.button?.window {
            observers.append(center.addObserver(
                forName: NSWindow.didMoveNotification,
                object: buttonWindow,
                queue: .main,
                using: request
            ))
            observers.append(center.addObserver(
                forName: NSWindow.didResizeNotification,
                object: buttonWindow,
                queue: .main,
                using: request
            ))
            observers.append(center.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: buttonWindow,
                queue: .main,
                using: request
            ))
        }

        // Dynamic 240/288-point content changes resize the shown popover
        // window and can reintroduce clipping after the last menu-bar
        // geometry event. Corrections never change the window's size, so
        // observing resize cannot create a feedback loop. The popover
        // window's move notification is deliberately not observed.
        if let popoverWindow = popover?.contentViewController?.view.window {
            observers.append(center.addObserver(
                forName: NSWindow.didResizeNotification,
                object: popoverWindow,
                queue: .main,
                using: request
            ))
        }

        // Display/Space transitions can move the status item between windows.
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main,
            using: request
        ))
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main,
            using: request
        ))
    }

    private func removeObservers() {
        guard !observers.isEmpty else {
            return
        }
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    // MARK: Repositioning

    private func repositionPopoverIfNeeded() {
        guard let popover, popover.isShown,
              let button = statusItem?.button,
              let buttonWindow = button.window else {
            // Geometry is not currently knowable; wait for the next valid
            // geometry event instead of inventing an unrelated screen.
            return
        }

        // Supported position refresh: re-assert the positioning relationship
        // so AppKit re-anchors the popover against the status item button.
        popover.positioningRect = button.bounds

        guard let popoverWindow = popover.contentViewController?.view.window else {
            return
        }
        // Prefer the screen hosting the status-item button's window: the
        // popover must stay associated with the status item. Fall back only
        // to the shown popover window's own associated screen (related
        // geometry, needed if the status-bar window is fully hidden). If
        // neither associated screen exists, bail and wait for the next valid
        // geometry event rather than inventing an unrelated screen.
        guard let screen = buttonWindow.screen ?? popoverWindow.screen else {
            return
        }

        let corrected = PopoverWindowGeometry.correctedFrame(
            popoverWindow.frame,
            visibleFrame: screen.visibleFrame
        )
        guard corrected != popoverWindow.frame else {
            return
        }
        popoverWindow.setFrame(corrected, display: false, animate: false)
        AppLog.shared.append("Popover repositioned to stay within the visible screen frame.")
    }
}
