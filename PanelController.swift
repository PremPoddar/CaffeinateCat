import Cocoa

// Hosts `PanelView` in an NSPopover anchored to the status item.
//
// The popover handles what a borderless window would not: click-outside dismissal, Esc, key
// handling for the duration fields, and the system shadow. Only ⌘Q is wired up by hand, since the
// quit row advertises it.

final class PanelController: NSObject, NSPopoverDelegate {
    let view = PanelView()

    /// Called for ⌘Q while the panel is open, so the shortcut drawn in the quit row is real.
    var onQuit: (() -> Void)?

    /// Width of the rect the popover centres itself on. Pinned to the status item's trailing edge,
    /// so it stays put no matter how wide the item's label grows.
    private static let anchorWidth: CGFloat = 22

    private let popover = NSPopover()
    private var localMonitor: Any?
    private weak var statusButton: NSStatusBarButton?
    private var lastHide = Date.distantPast

    private(set) var isVisible = false

    var delegate: PanelViewDelegate? {
        get { view.delegate }
        set { view.delegate = newValue }
    }

    override init() {
        super.init()

        let controller = NSViewController()
        controller.view = view
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        hideArrow()
        resizeToFit()
    }

    /// NSPopover exposes no public way to drop its arrow. `shouldHideAnchor` is the long-standing
    /// private setter for it; `responds(to:)` keeps an unknown key from raising, so on a macOS that
    /// ever removes it the popover simply keeps its arrow rather than crashing.
    private func hideArrow() {
        let selector = NSSelectorFromString("setShouldHideAnchor:")
        guard popover.responds(to: selector) else { return }
        popover.setValue(true, forKey: "shouldHideAnchor")
    }

    // MARK: - State

    func apply(_ state: PanelState) {
        view.apply(state)
        resizeToFit()
    }

    /// Anchored under the icon, at the item's leading edge.
    ///
    /// This is only safe because `AppDelegate` pins the status item to a constant width. Left to
    /// size itself the item grows leftward as its label widens, and any anchor expressed in the
    /// button's coordinates then drifts across the screen. Note that reading the item's geometry
    /// synchronously after setting its title reports a stale window position that makes the
    /// leading edge look fixed when it is the edge that moves — measure after a layout pass.
    private func anchorRect(in button: NSStatusBarButton) -> NSRect {
        NSRect(x: button.bounds.minX,
               y: button.bounds.minY,
               width: Self.anchorWidth,
               height: button.bounds.height)
    }

    /// Called after the status item's label changes: the anchor is expressed in the button's own
    /// coordinates, so a width change moves it unless it is recomputed.
    func updateAnchor(from button: NSStatusBarButton) {
        guard isVisible else { return }
        popover.positioningRect = anchorRect(in: button)
    }

    private func resizeToFit() {
        view.layoutSubtreeIfNeeded()
        let size = NSSize(width: Metrics.panelWidth, height: view.fittingHeight)
        guard size != popover.contentSize else { return }
        view.frame = NSRect(origin: .zero, size: size)
        popover.contentSize = size
    }

    // MARK: - Show / hide

    func toggle(from button: NSStatusBarButton) {
        if isVisible {
            hide()
            return
        }
        // A click on the status item closes a transient popover on its own, so by the time the
        // button's action arrives the popover has already gone. Without this the same click would
        // immediately reopen it.
        guard Date().timeIntervalSince(lastHide) > 0.25 else { return }
        show(from: button)
    }

    func show(from button: NSStatusBarButton) {
        guard !isVisible else { return }

        statusButton = button
        view.refreshPalette()
        resizeToFit()

        popover.show(relativeTo: anchorRect(in: button), of: button, preferredEdge: .minY)
        isVisible = true

        // Without this the popover can come up behind the frontmost app, leaving the duration
        // fields unable to take key input.
        NSApp.activate(ignoringOtherApps: true)
        button.highlight(true)

        startMonitoring()
    }

    func hide() {
        guard isVisible else { return }
        markClosed()
        popover.performClose(nil)
    }

    private func markClosed() {
        isVisible = false
        lastHide = Date()
        stopMonitoring()
        statusButton?.highlight(false)
    }

    // MARK: - Key handling

    private func startMonitoring() {
        stopMonitoring()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "q" {
                self.onQuit?()
                return nil
            }
            return event
        }
    }

    private func stopMonitoring() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
    }

    // MARK: - NSPopoverDelegate

    /// Also covers the popover closing itself — clicking away, or Esc.
    func popoverDidClose(_ notification: Notification) {
        guard isVisible else { return }
        markClosed()
    }
}
