import Cocoa

// The single active "keep awake" mode. Caffeinate and lid-close are mutually exclusive
// levels of the same thing: lid-close is a superset that also survives the lid closing.
enum Mode {
    case off
    case caffeinate
    case lidClose
}

let APP_VERSION = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.0"

/// Nanoseconds on a clock that keeps counting while the Mac sleeps (Darwin's CLOCK_MONOTONIC is
/// `mach_continuous_time`). Timed runs are measured against it, so a Mac that sleeps with the lid
/// shut half-way through a 30-minute run doesn't wake up with the same 15 minutes still to go.
private func continuousNow() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_MONOTONIC)
}

class AppDelegate: NSObject, NSApplicationDelegate, PanelViewDelegate {
    var statusItem: NSStatusItem!
    let panelController = PanelController()
    let prefs = Preferences()
    let watchdog = LidWatchdog()
    let battery = BatteryMonitor()
    let updater = UpdateController()

    var mode: Mode = .off
    var deadline: UInt64 = 0                 // continuousNow() at which the run ends; 0 = indefinite/off
    var runTotal = 0                         // the run's length in seconds, for the progress bar
    var endDate: Date?                       // wall-clock end, for "until 14:32"
    var countdown = CountdownFormat(total: 0) // field widths fixed by the active run's total
    var tickTimer: Timer?                    // drives the countdown and the auto-off
    var healthTimer: Timer?                  // re-verifies the lid flag while lid mode runs
    var caffeineActivity: NSObjectProtocol?  // idle (+ display) assertion, held by both modes
    var lidActive = false                    // whether we currently hold pmset disablesleep
    var authorizing = false                  // an admin prompt is on screen
    var pendingLid = false                   // lid mode should start once that prompt is approved
    var lastBatteryLevel: Int?
    private var signalSources: [DispatchSourceSignal] = []
    private var statusImages: [String: NSImage] = [:]

    private lazy var endTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        installSignalHandlers()
        recoverStaleLidFlag()
        setupStatusItem()

        panelController.delegate = self
        panelController.onQuit = { [weak self] in self?.quit() }
        panelController.stateProvider = { [weak self] in self?.currentState() ?? PanelState() }
        updater.onChange = { [weak self] in self?.refresh() }

        lastBatteryLevel = BatteryMonitor.dischargingLevel()
        battery.onChange = { [weak self] in self?.batteryChanged() }
        battery.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)

        LoginItem.refreshIfEnabled()

        if prefs.activateOnLaunch {
            activate(.caffeinate)
        } else {
            refresh()
        }

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

    /// Left-click opens the panel; right-click (or control-click) flips keep-awake on or off using
    /// whichever mode was used last.
    @objc func statusItemClicked() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            quickToggle()
            return
        }
        panelController.toggle(from: button)
    }

    func quickToggle() {
        if mode == .off {
            activate(prefs.lastFeature)
        } else {
            setOff()
        }
    }

    // MARK: - Duration bookkeeping

    func duration(for feature: Feature) -> AwakeDuration {
        prefs.duration(for: feature)
    }

    func resetCustomToDefault(_ feature: Feature) {
        prefs.setCustom(hours: DEFAULT_CUSTOM_HOURS, minutes: DEFAULT_CUSTOM_MINUTES, for: feature)
    }

    /// Total seconds the feature's current selection asks for. 0 means indefinite.
    func seconds(for feature: Feature) -> Int {
        switch duration(for: feature) {
        case .indefinite:
            return 0
        case .minutes(let minutes):
            return minutes * 60
        case .custom:
            return prefs.customHours(for: feature) * 3600 + prefs.customMinutes(for: feature) * 60
        }
    }

    func isActive(_ feature: Feature) -> Bool {
        feature == .caffeinate ? mode == .caffeinate : mode == .lidClose
    }

    /// Seconds left in a timed run, rounded up so the display never reads 00:00 while still on.
    var remainingSeconds: Int {
        guard deadline > 0 else { return 0 }
        let now = continuousNow()
        guard deadline > now else { return 0 }
        return Int((deadline - now + 999_999_999) / 1_000_000_000)
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

        // Any explicit choice supersedes a lid activation still waiting on its admin prompt.
        pendingLid = false

        switch feature {
        case .caffeinate:
            // Caffeinate: idle + display stay awake, but the Mac sleeps when the lid closes.
            disableLid(interactive: true)
        case .lid:
            // Lid-close: everything caffeinate does, PLUS stays awake with the lid shut (pmset).
            if !lidActive && !enableLid() {
                requestLidPermission() // leaves the current mode untouched until it's approved
                return
            }
        }

        if caffeineActivity == nil { beginCaffeineAssertion() }
        mode = (feature == .caffeinate) ? .caffeinate : .lidClose
        prefs.lastFeature = feature
        runTotal = total
        deadline = total > 0 ? continuousNow() + UInt64(total) * 1_000_000_000 : 0
        endDate = total > 0 ? Date().addingTimeInterval(TimeInterval(total)) : nil
        countdown = CountdownFormat(total: total)
        lastBatteryLevel = BatteryMonitor.dischargingLevel()
        startTicking()
        refresh()
    }

    func setOff() {
        pendingLid = false
        tickTimer?.invalidate(); tickTimer = nil
        disableLid(interactive: true)
        endCaffeineAssertion()
        mode = .off
        deadline = 0
        runTotal = 0
        endDate = nil
        refresh()
    }

    func beginCaffeineAssertion() {
        var options: ProcessInfo.ActivityOptions = [.idleSystemSleepDisabled]
        if !prefs.allowDisplaySleep { options.insert(.idleDisplaySleepDisabled) }
        caffeineActivity = ProcessInfo.processInfo.beginActivity(options: options,
                                                                 reason: "CaffeinateCat is keeping the Mac awake")
    }

    func endCaffeineAssertion() {
        if let activity = caffeineActivity {
            ProcessInfo.processInfo.endActivity(activity)
            caffeineActivity = nil
        }
    }

    /// Swaps the assertion for one with the current display option, without a gap in between.
    func restartCaffeineAssertion() {
        guard let old = caffeineActivity else { return }
        beginCaffeineAssertion()
        ProcessInfo.processInfo.endActivity(old)
    }

    /// One 1s timer drives both the visible countdown and the auto-off. Indefinite = no timer.
    /// Scheduled in `.common` so it keeps ticking while the panel is tracking a mouse press. The
    /// time left is always recomputed from the deadline, so late or skipped ticks can't drift it.
    func startTicking() {
        tickTimer?.invalidate(); tickTimer = nil
        guard deadline > 0 else { return }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func tick() {
        guard deadline > 0 else { return }
        if remainingSeconds <= 0 {
            setOff()
        } else {
            refresh()
        }
    }

    // MARK: - Lid flag

    /// Sets disablesleep=1 with the existing rule, and double-checks the kernel took it.
    private func enableLid() -> Bool {
        prefs.lidFlagOwned = true // before, so a crash mid-way still gets cleaned up at next launch
        guard LidControl.setSleepDisabled(true) else {
            prefs.lidFlagOwned = false
            return false
        }
        if LidControl.isSleepDisabled() == false {
            _ = LidControl.setSleepDisabled(false)
            prefs.lidFlagOwned = false
            return false
        }
        watchdog.start()
        lidActive = true
        startHealthChecks()
        return true
    }

    /// Restores normal sleep and verifies it. If that fails the flag is left marked as ours, so the
    /// next launch retries, and — when there's someone to tell — the user gets the manual fix.
    @discardableResult
    private func disableLid(interactive: Bool) -> Bool {
        guard lidActive else { return true }
        lidActive = false
        healthTimer?.invalidate(); healthTimer = nil
        watchdog.stop()

        if LidControl.setSleepDisabled(false) && LidControl.isSleepDisabled() != true {
            prefs.lidFlagOwned = false
            return true
        }
        NSLog("CaffeinateCat: failed to restore disablesleep 0")
        if interactive { showRestoreFailedAlert() }
        return false
    }

    /// While lid mode runs, periodically confirm the flag is still set (another tool, or a user in
    /// Terminal, can clear it) and that the watchdog is still alive. The pmset read happens off the
    /// main thread.
    private func startHealthChecks() {
        healthTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.checkLidHealth() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func checkLidHealth() {
        guard lidActive else { return }
        watchdog.ensureRunning()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let disabled = LidControl.isSleepDisabled()
            guard disabled == false else { return }
            DispatchQueue.main.async {
                guard let self, self.lidActive else { return }
                NSLog("CaffeinateCat: SleepDisabled was cleared externally; re-applying")
                if !LidControl.setSleepDisabled(true) {
                    // Can't hold the lid any more; fall back to plain keep-awake rather than lie.
                    self.lidActive = false
                    self.watchdog.stop()
                    self.healthTimer?.invalidate(); self.healthTimer = nil
                    self.prefs.lidFlagOwned = false
                    self.mode = .caffeinate
                    self.refresh()
                }
            }
        }
    }

    /// A previous run that died holding disablesleep (power loss, kernel panic — cases even the
    /// watchdog can't cover) leaves it set, and the setting persists across reboots.
    private func recoverStaleLidFlag() {
        guard prefs.lidFlagOwned else { return }
        if LidControl.setSleepDisabled(false) && LidControl.isSleepDisabled() != true {
            prefs.lidFlagOwned = false
        } else {
            showRestoreFailedAlert()
        }
    }

    /// Installs the sudoers rule off the main thread (the admin prompt can sit there for as long as
    /// the user likes), then finishes switching to lid mode if nothing else was chosen meanwhile.
    private func requestLidPermission(thenActivate: Bool = true) {
        if thenActivate { pendingLid = true }
        guard !authorizing else { refresh(); return }
        authorizing = true
        panelController.hide() // the auth dialog takes focus and would dismiss it anyway
        refresh()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let installed = LidControl.installRule()
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizing = false
                let wanted = self.pendingLid
                self.pendingLid = false
                if wanted {
                    if installed && self.enableLid() {
                        self.activate(.lid)
                        return
                    }
                    self.showLidUnavailableAlert()
                }
                self.refresh()
            }
        }
    }

    // MARK: - System events

    @objc func systemDidWake(_ notification: Notification) {
        tick()
        checkLidHealth()
    }

    /// Switches off as the battery falls through one of the thresholds. Only a downward crossing
    /// counts, so starting a run while already low is honoured until the next threshold.
    func batteryChanged() {
        updateStatusItem() // the cup's liquid level
        let level = BatteryMonitor.dischargingLevel()
        defer { lastBatteryLevel = level }
        guard prefs.stopOnLowBattery, mode != .off, let level, let previous = lastBatteryLevel else { return }
        if LOW_BATTERY_THRESHOLDS.contains(where: { previous > $0 && level <= $0 }) {
            NSLog("CaffeinateCat: battery at \(level)%, turning off")
            setOff()
        }
    }

    /// SIGTERM (`kill`, logout scripts), SIGINT (Ctrl-C from a terminal) and SIGHUP would otherwise
    /// end the process without `applicationWillTerminate`, skipping cleanup.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.cleanup()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
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
        prefs.setDuration(duration, for: feature)
        if isActive(feature) { activate(feature) } else { refresh() }
    }

    func panelDidEditCustom(_ feature: Feature, hours: Int, minutes: Int) {
        prefs.setCustom(hours: hours, minutes: minutes, for: feature)
        if isActive(feature) && duration(for: feature) == .custom {
            activate(feature)
        } else {
            refresh()
        }
    }

    func panelDidSetOption(_ option: PanelOption, on: Bool) {
        switch option {
        case .allowDisplaySleep:
            prefs.allowDisplaySleep = on
            restartCaffeineAssertion()
        case .stopOnLowBattery:
            prefs.stopOnLowBattery = on
        case .activateOnLaunch:
            prefs.activateOnLaunch = on
        case .launchAtLogin:
            if !LoginItem.setEnabled(on) { NSSound.beep() }
        }
        refresh()
    }

    func panelDidToggleOptionsExpanded() {
        prefs.optionsExpanded.toggle()
        refresh()
    }

    func panelDidRequestRemoveLidRule() {
        panelController.hide()
        let alert = NSAlert()
        alert.messageText = "Remove the lid-close permission?"
        alert.informativeText = """
        This deletes \(SUDOERS_PATH). “Keep Awake on Lid Close” will ask for your administrator \
        password again the next time you turn it on.
        """
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // The rule is what lets us turn the flag back off, so let go of it first.
        if mode == .lidClose { setOff() }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = LidControl.removeRule()
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func panelDidRequestUpdateCheck() {
        panelController.hide()
        updater.checkForUpdates()
    }

    func panelDidRequestAbout() {
        panelController.hide()
        let credits = NSMutableAttributedString(
            string: "Keeps your Mac awake — even with the lid closed.\n\nMade by Prem Poddar\nNoxdrop Systems",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centred, range: NSRange(location: 0, length: credits.length))

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "CaffeinateCat",
            .applicationVersion: APP_VERSION,
            .version: "",
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Prem Poddar · Noxdrop Systems",
        ])
    }

    func panelDidRequestQuit() {
        quit()
    }

    // MARK: - Rendering

    func currentState() -> PanelState {
        let remaining = remainingSeconds
        let displaySleeps = prefs.allowDisplaySleep
        let ruleInstalled = LidControl.ruleInstalled

        func feature(_ feature: Feature, on: Bool, title: String, subtitle: String) -> FeatureState {
            let timed = on && deadline > 0
            return FeatureState(
                title: title,
                subtitle: subtitle,
                on: on,
                duration: duration(for: feature),
                customHours: prefs.customHours(for: feature),
                customMinutes: prefs.customMinutes(for: feature),
                countdown: timed ? countdown.string(remaining) : "",
                endsAt: timed ? endDate.map(endTimeFormatter.string(from:)) ?? "" : "",
                progress: timed && runTotal > 0 ? Double(remaining) / Double(runTotal) : 0
            )
        }

        let lidSubtitle: String
        if authorizing {
            lidSubtitle = "Waiting for administrator approval…"
        } else if ruleInstalled {
            lidSubtitle = "Continues running with the lid closed"
        } else {
            lidSubtitle = "Runs lid-closed · asks for admin once"
        }

        let status: String
        switch mode {
        case .off:        status = "Sleeping normally"
        case .caffeinate: status = "Awake"
        case .lidClose:   status = "Awake · lid can close"
        }

        return PanelState(
            caffeinate: feature(.caffeinate,
                                on: mode == .caffeinate,
                                title: displaySleeps ? "Keep Mac Awake" : "Keep Screen Awake",
                                subtitle: displaySleeps
                                    ? "Prevents idle sleep; the display may turn off"
                                    : "Prevents display sleep for active processes"),
            lid: feature(.lid,
                         on: mode == .lidClose || pendingLid,
                         title: "Keep Awake on Lid Close",
                         subtitle: lidSubtitle),
            statusText: status,
            isAwake: mode != .off,
            options: [
                .allowDisplaySleep: displaySleeps,
                .stopOnLowBattery: prefs.stopOnLowBattery,
                .activateOnLaunch: prefs.activateOnLaunch,
                .launchAtLogin: LoginItem.isEnabled,
            ],
            optionsExpanded: prefs.optionsExpanded,
            lidRuleInstalled: ruleInstalled,
            availableUpdate: updater.availableVersion,
            updatesSupported: updater.isAvailable
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

    /// The cup's liquid tracks the battery and is orange while keeping awake (steam in lid mode);
    /// the label shows "On" or the remaining time. Only touches the button when something actually
    /// changed, since this runs every second during a timer.
    func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let battery = BatteryMonitor.chargeLevel()
        guard let image = statusImage(level: MenuBarIcon.step(forBattery: battery)) else {
            // No SF Symbols (pre-Big Sur): plain text.
            let title = mode == .off ? "☕️" : "☕️ " + statusLabel()
            if button.title != title { button.title = title }
            button.image = nil
            button.imagePosition = .noImage
            return
        }
        if button.image !== image { button.image = image }

        let label = statusLabel()
        let title = label.isEmpty ? "" : " " + label   // leading space: the design's 5pt icon gap
        let position: NSControl.ImagePosition = label.isEmpty ? .imageOnly : .imageLeading
        if button.title != title { button.title = title }
        if button.imagePosition != position { button.imagePosition = position }

        let state: String
        switch mode {
        case .off:        state = "off"
        case .caffeinate: state = "keeping the Mac awake"
        case .lidClose:   state = "keeping the Mac awake, lid can close"
        }
        let charge = battery.map { ", battery \($0)%" } ?? ""
        let description = "CaffeinateCat — \(state)\(charge)"
        if image.accessibilityDescription != description { image.accessibilityDescription = description }
        let tip = "\(description)\nClick for options, right-click to turn on or off"
        if button.toolTip != tip { button.toolTip = tip }
    }

    /// One image per (mode, level) — at most 18, and drawn lazily by the image itself.
    private func statusImage(level: Int) -> NSImage? {
        let key = "\(mode)-\(level)"
        if let cached = statusImages[key] { return cached }
        guard let image = MenuBarIcon.image(level: level, awake: mode != .off, steam: mode == .lidClose) else { return nil }
        statusImages[key] = image
        return image
    }

    private func statusLabel() -> String {
        switch mode {
        case .off:
            return ""
        case .caffeinate, .lidClose:
            return deadline == 0 ? "On" : countdown.string(remainingSeconds)
        }
    }

    // MARK: - Alerts

    // On a machine without the rule yet, offer to set it up once. "Not Now" is remembered.
    func maybePromptForLidSetup() {
        if LidControl.ruleInstalled || prefs.lidSetupDeclined { return }

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
            requestLidPermission(thenActivate: false)
        } else {
            prefs.lidSetupDeclined = true
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

    func showRestoreFailedAlert() {
        let alert = NSAlert()
        alert.messageText = "Couldn’t restore normal sleep"
        alert.informativeText = """
        CaffeinateCat was unable to turn the lid-close setting back off, so your Mac may not \
        sleep on its own. To fix it, run this in Terminal:

        sudo pmset -a disablesleep 0
        """
        alert.alertStyle = .critical
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
        disableLid(interactive: false)
        endCaffeineAssertion()
    }
}
