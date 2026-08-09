import Cocoa

// Where the passwordless pmset rule lives, and the path used to install it.
let SUDOERS_PATH = "/etc/sudoers.d/caffeinatecat"

// What the custom duration starts at, and what it is restored to whenever it is emptied to zero.
// A zero-length custom value can't run, so it is never left in place.
let DEFAULT_CUSTOM_HOURS = 2
let DEFAULT_CUSTOM_MINUTES = 0

// The single active "keep awake" mode. Caffeinate and lid-close are mutually exclusive
// levels of the same thing: lid-close is a superset that also survives the lid closing.
enum Mode {
    case off
    case caffeinate
    case lidClose
}

class AppDelegate: NSObject, NSApplicationDelegate, PanelViewDelegate {
    var statusItem: NSStatusItem!
    let panelController = PanelController()

    var mode: Mode = .off
    var remainingSeconds = 0                 // 0 when off or indefinite
    var countdown = CountdownFormat(total: 0) // field widths fixed by the active run's total
    var tickTimer: Timer?                    // drives the countdown and the auto-off
    var caffeineActivity: NSObjectProtocol?  // idle + display assertion (held by both modes)
    var lidActive = false                    // whether pmset disablesleep is currently set

    // Each feature remembers its own duration selection, independently of which one is active.
    var caffeinateDuration: AwakeDuration = .indefinite
    var lidDuration: AwakeDuration = .indefinite
    var caffeinateCustomHours = DEFAULT_CUSTOM_HOURS
    var caffeinateCustomMinutes = DEFAULT_CUSTOM_MINUTES
    var lidCustomHours = DEFAULT_CUSTOM_HOURS
    var lidCustomMinutes = DEFAULT_CUSTOM_MINUTES

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupStatusItem()

        panelController.delegate = self
        panelController.onQuit = { [weak self] in self?.quit() }

        // Caffeinate on (Indefinite) by default, so the app "just works" on launch.
        activate(.caffeinate)

        // First launch on a new machine: offer to set up the lid-closed permission.
        maybePromptForLidSetup()
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.font = Typography.menuBar
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        updateStatusItem()                                  // puts the icon in place to measure
        statusItem.length = widestStatusItemWidth(button)
        refresh()
    }

    /// The status item is pinned to a constant width, sized for the longest label it can ever show.
    ///
    /// Left to size itself, the item tracks its label — and it grows leftward from a fixed trailing
    /// edge (measured, once layout settles: screen maxX held at ~1102.5 while minX slid 1065 →
    /// 1005 across icon-only, "On", and a HH:MM:SS countdown). Everything positioned against it,
    /// the popover included, then slides sideways every time the text changes, which moves controls
    /// out from under the pointer mid-click. Reserving the space up front means the item's geometry
    /// never changes at all, so nothing anchored to it can move — regardless of how the popover
    /// resolves its anchor.
    ///
    /// The button centres its icon and label inside that fixed width; `alignment = .left` does not
    /// override it (measured by rendering the button and scanning for the icon's first opaque
    /// column: 32pt in with no label, 4pt in with "12:00:00"). So the icon still shifts as the text
    /// grows, by about as much as it did when the whole item resized. Pinning it would mean drawing
    /// the icon and text into one fixed-size template image instead of using image + title.
    private func widestStatusItemWidth(_ button: NSStatusBarButton) -> CGFloat {
        let title = button.title
        let position = button.imagePosition
        button.imagePosition = .imageLeading
        button.title = " 00:00:00"                          // widest label: HH:MM:SS
        let width = ceil(button.fittingSize.width)
        button.title = title
        button.imagePosition = position
        return width
    }

    @objc func statusItemClicked() {
        guard let button = statusItem.button else { return }
        panelController.toggle(from: button)
    }

    // MARK: - Duration bookkeeping

    func duration(for feature: Feature) -> AwakeDuration {
        feature == .caffeinate ? caffeinateDuration : lidDuration
    }

    func setDuration(_ duration: AwakeDuration, for feature: Feature) {
        if feature == .caffeinate { caffeinateDuration = duration } else { lidDuration = duration }
    }

    func setCustom(hours: Int, minutes: Int, for feature: Feature) {
        let hours = max(0, min(23, hours))
        let minutes = max(0, min(59, minutes))
        if feature == .caffeinate {
            caffeinateCustomHours = hours
            caffeinateCustomMinutes = minutes
        } else {
            lidCustomHours = hours
            lidCustomMinutes = minutes
        }
    }

    func resetCustomToDefault(_ feature: Feature) {
        setCustom(hours: DEFAULT_CUSTOM_HOURS, minutes: DEFAULT_CUSTOM_MINUTES, for: feature)
    }

    /// Total seconds the feature's current selection asks for. 0 means indefinite.
    func seconds(for feature: Feature) -> Int {
        switch duration(for: feature) {
        case .indefinite:
            return 0
        case .minutes(let minutes):
            return minutes * 60
        case .custom:
            return feature == .caffeinate
                ? caffeinateCustomHours * 3600 + caffeinateCustomMinutes * 60
                : lidCustomHours * 3600 + lidCustomMinutes * 60
        }
    }

    func isActive(_ feature: Feature) -> Bool {
        feature == .caffeinate ? mode == .caffeinate : mode == .lidClose
    }

    // MARK: - Mode transitions

    /// Switches to `feature` at its currently selected duration, tearing down the other mode.
    /// Also used to restart an already-active feature when its duration changes.
    func activate(_ feature: Feature) {
        let total = seconds(for: feature)

        // A custom duration of 0h 0m has nothing to count down. Switch off first, so the Mac is
        // free to sleep straight away, and only then restore a usable value — leaving 0 in place is
        // what let the feature get stuck: every later attempt to run it, whether from the switch or
        // from re-picking Custom, recomputed 0 and turned itself off again.
        if duration(for: feature) != .indefinite && total <= 0 {
            setOff()
            resetCustomToDefault(feature)
            refresh()
            return
        }

        switch feature {
        case .caffeinate:
            // Caffeinate: idle + display stay awake, but the Mac sleeps when the lid closes.
            if lidActive {
                setLidCloseSleepDisabled(false)
                lidActive = false
            }
        case .lid:
            // Lid-close: everything caffeinate does, PLUS stays awake with the lid shut (pmset).
            if !lidActive {
                if !enableLidFlag() {
                    refresh() // leaves the previous mode untouched
                    showLidUnavailableAlert()
                    return
                }
                lidActive = true
            }
        }

        if caffeineActivity == nil { beginCaffeineAssertion() }
        mode = (feature == .caffeinate) ? .caffeinate : .lidClose
        remainingSeconds = total
        countdown = CountdownFormat(total: total)
        startTicking()
        refresh()
    }

    func setOff() {
        tickTimer?.invalidate(); tickTimer = nil
        if lidActive { setLidCloseSleepDisabled(false); lidActive = false }
        endCaffeineAssertion()
        mode = .off
        remainingSeconds = 0
        refresh()
    }

    func beginCaffeineAssertion() {
        caffeineActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Keeping the Mac awake"
        )
    }

    func endCaffeineAssertion() {
        if let activity = caffeineActivity {
            ProcessInfo.processInfo.endActivity(activity)
            caffeineActivity = nil
        }
    }

    /// One 1s timer drives both the visible countdown and the auto-off. Indefinite = no timer.
    /// Scheduled in `.common` so it keeps ticking while the panel is tracking a mouse press.
    func startTicking() {
        tickTimer?.invalidate(); tickTimer = nil
        guard remainingSeconds > 0 else { return }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.remainingSeconds -= 1
            if self.remainingSeconds <= 0 {
                self.setOff()
            } else {
                self.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    // MARK: - PanelViewDelegate

    func panelDidToggle(_ feature: Feature, on: Bool) {
        guard on else {
            setOff()
            return
        }
        // Turning the switch on has to actually start something. If the custom value is still zero
        // — typed while the feature was already off, so nothing reset it — restore the default
        // first, otherwise `activate` would switch straight back off.
        if duration(for: feature) == .custom && seconds(for: feature) <= 0 {
            resetCustomToDefault(feature)
        }
        activate(feature)
    }

    func panelDidSelectDuration(_ feature: Feature, _ duration: AwakeDuration) {
        setDuration(duration, for: feature)
        if isActive(feature) { activate(feature) } else { refresh() }
    }

    func panelDidEditCustom(_ feature: Feature, hours: Int, minutes: Int) {
        setCustom(hours: hours, minutes: minutes, for: feature)
        if isActive(feature) && duration(for: feature) == .custom {
            activate(feature)
        } else {
            refresh()
        }
    }

    func panelDidRequestQuit() {
        quit()
    }

    // MARK: - Rendering

    func currentState() -> PanelState {
        PanelState(
            caffeinateOn: mode == .caffeinate,
            lidOn: mode == .lidClose,
            caffeinateDuration: caffeinateDuration,
            lidDuration: lidDuration,
            caffeinateCustomHours: caffeinateCustomHours,
            caffeinateCustomMinutes: caffeinateCustomMinutes,
            lidCustomHours: lidCustomHours,
            lidCustomMinutes: lidCustomMinutes,
            caffeinateCountdown: mode == .caffeinate ? countdown.string(remainingSeconds) : "",
            lidCountdown: mode == .lidClose ? countdown.string(remainingSeconds) : ""
        )
    }

    func refresh() {
        updateStatusItem()
        // Order matters: the anchor is derived from the button's width, so it has to be recomputed
        // after the label that determines that width has been set.
        if let button = statusItem.button {
            panelController.updateAnchor(from: button)
        }
        panelController.apply(currentState())
    }

    /// Icon reflects which mode is active; the label shows "On" or the remaining time.
    func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let symbolName: String
        switch mode {
        case .off:       symbolName = "cup.and.saucer"
        case .caffeinate: symbolName = "cup.and.saucer.fill"
        case .lidClose:  symbolName = "laptopcomputer"
        }

        if #available(macOS 11.0, *),
           let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CaffeinateCat") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.image = image.withSymbolConfiguration(config)
        } else {
            button.image = nil
            button.title = mode == .off ? "☕️" : "☕️ " + statusLabel()
            button.imagePosition = .noImage
            return
        }

        let label = statusLabel()
        if label.isEmpty {
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            // Leading space stands in for the design's 5pt gap between icon and label.
            button.title = " " + label
            button.imagePosition = .imageLeading
        }
    }

    private func statusLabel() -> String {
        switch mode {
        case .off:
            return ""
        case .caffeinate:
            return caffeinateDuration == .indefinite ? "On" : countdown.string(remainingSeconds)
        case .lidClose:
            return lidDuration == .indefinite ? "On" : countdown.string(remainingSeconds)
        }
    }

    // MARK: - pmset (lid-close flag)

    // Runs `sudo -n pmset -a disablesleep <0|1>`. Returns true on success.
    //
    // `disablesleep 1` sets the SleepDisabled flag in IOPMrootDomain, which is the only
    // thing that keeps an Apple Silicon Mac awake with the lid closed (even on battery).
    // Setting it requires root, so this relies on the scoped, passwordless sudoers rule
    // installed by installSudoersRule(). `-n` makes sudo fail fast instead of blocking on a
    // password prompt, since a menu-bar app has no terminal to answer one.
    @discardableResult
    func setLidCloseSleepDisabled(_ disabled: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // Sets disablesleep=1, self-installing the sudoers rule (one admin prompt) if needed.
    func enableLidFlag() -> Bool {
        if setLidCloseSleepDisabled(true) { return true }
        if installSudoersRule() { return setLidCloseSleepDisabled(true) }
        return false
    }

    // MARK: - Sudoers rule self-install

    // True if our passwordless pmset rule is installed. We check for our own sudoers file
    // rather than probing sudo: `sudo -l` reports whether the user *may* run pmset at all
    // (admins may, with a password) and is muddied by cached credentials, so it can't tell
    // us specifically that the passwordless rule exists. The enable path uses `sudo -n` as
    // the real test and reinstalls if needed, so this only gates the first-launch prompt.
    func lidPrivilegeAvailable() -> Bool {
        return FileManager.default.fileExists(atPath: SUDOERS_PATH)
    }

    // Installs a sudoers rule granting THIS user passwordless access to exactly the two
    // pmset disablesleep commands. Uses a one-time native admin-auth prompt (Touch ID or
    // password) via osascript, so no manual editing is needed. Returns true on success.
    @discardableResult
    func installSudoersRule() -> Bool {
        let user = NSUserName()
        let line = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0\n"

        // Write the candidate rule to a temp file as the current user (no privilege needed).
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("caffeinatecat.sudoers")
        do {
            try line.write(to: tmpURL, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        // Validate syntax with visudo, then install root:wheel 0440 — all as root, one prompt.
        let tmp = tmpURL.path
        let shell = "/usr/sbin/visudo -cf '\(tmp)' && /usr/bin/install -m 0440 -o root -g wheel '\(tmp)' \(SUDOERS_PATH)"
        let script = "do shell script \"\(shell)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // On a machine without the rule yet, offer to set it up once at launch.
    func maybePromptForLidSetup() {
        if lidPrivilegeAvailable() { return }

        let alert = NSAlert()
        alert.messageText = "Enable “Keep Awake on Lid Close”?"
        alert.informativeText = """
        CaffeinateCat can keep your Mac running with the lid closed — even on battery, \
        so a process (server, build, coding agent…) keeps going while you travel.

        This needs your administrator permission once to set it up. You can also skip this \
        and enable it later from the menu.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Set Up Now")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            installSudoersRule()
        }
    }

    func showLidUnavailableAlert() {
        let alert = NSAlert()
        alert.messageText = "Couldn’t enable lid-closed mode"
        alert.informativeText = """
        CaffeinateCat needs one-time administrator permission to keep your Mac awake with \
        the lid closed. The setup was cancelled or failed.

        Try again and approve the permission prompt.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Teardown

    @objc func quit() {
        cleanup()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }

    // Idempotent: safe to call more than once (e.g. quit() then applicationWillTerminate).
    // Ends the idle assertion and, crucially, restores normal lid-close sleep so we never
    // leave the Mac permanently unable to sleep.
    func cleanup() {
        tickTimer?.invalidate(); tickTimer = nil
        if lidActive { setLidCloseSleepDisabled(false); lidActive = false }
        endCaffeineAssertion()
    }
}
