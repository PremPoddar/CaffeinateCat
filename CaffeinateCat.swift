import Cocoa

let CODE_OFF = 0
let CODE_INDEFINITE = -1
let CODE_CUSTOM = -2

// Where the passwordless pmset rule lives, and the path used to install it.
let SUDOERS_PATH = "/etc/sudoers.d/caffeinatecat"

// The single active "keep awake" mode. Caffeinate and lid-close are mutually exclusive
// levels of the same thing: lid-close is a superset that also survives the lid closing.
enum Mode {
    case off
    case caffeinate
    case lidClose
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!

    var mode: Mode = .off
    var activeTag = CODE_INDEFINITE          // duration of the active mode
    var timer: Timer?                        // single auto-off timer for the active mode
    var caffeineActivity: NSObjectProtocol?  // idle + display assertion (held by both modes)
    var lidActive = false                    // whether pmset disablesleep is currently set

    var caffeineMenuItem: NSMenuItem!
    var lidMenuItem: NSMenuItem!
    var caffeineDurationItems: [NSMenuItem] = []
    var lidDurationItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Steal focus immediately so the user can just hit a key to end it
        NSApp.activate(ignoringOtherApps: true)

        setupMenuBarIcon()

        // Caffeinate on (Indefinite) by default, so the app "just works" on launch.
        setCaffeinate(tag: CODE_INDEFINITE, minutes: 0)

        // First launch on a new machine: offer to set up the lid-closed permission.
        maybePromptForLidSetup()
    }

    func setupMenuBarIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {

            // Use Apple's built-in system vector icons (perfect transparency and scaling)
            if #available(macOS 11.0, *),
               let image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Coffee") {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                button.image = image.withSymbolConfiguration(config)
            } else {
                // Fallback emoji just in case
                let font = NSFont.systemFont(ofSize: 18)
                let attributes: [NSAttributedString.Key: Any] = [.font: font]
                button.attributedTitle = NSAttributedString(string: "☕️", attributes: attributes)
            }
        }

        let menu = NSMenu()

        // Each feature is a single row whose submenu (the ▸ arrow) holds the durations.
        caffeineMenuItem = NSMenuItem(title: "Caffeinate", action: nil, keyEquivalent: "")
        let (caffMenu, caffItems) = makeDurationSubmenu(action: #selector(selectCaffeineTimer(_:)))
        caffeineMenuItem.submenu = caffMenu
        caffeineDurationItems = caffItems
        menu.addItem(caffeineMenuItem)

        lidMenuItem = NSMenuItem(title: "Keep Awake When Lid Closed", action: nil, keyEquivalent: "")
        let (lidMenu, lidItems) = makeDurationSubmenu(action: #selector(selectLidTimer(_:)))
        lidMenuItem.submenu = lidMenu
        lidDurationItems = lidItems
        menu.addItem(lidMenuItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        refresh()
    }

    // Builds a duration submenu: Off / Indefinite / presets / Custom….
    func makeDurationSubmenu(action: Selector) -> (NSMenu, [NSMenuItem]) {
        let submenu = NSMenu()
        var items: [NSMenuItem] = []
        func add(_ title: String, _ tag: Int) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.tag = tag
            item.target = self
            submenu.addItem(item)
            items.append(item)
        }
        add("Off", CODE_OFF)
        submenu.addItem(.separator())
        add("Indefinite", CODE_INDEFINITE)
        add("15 minutes", 15)
        add("30 minutes", 30)
        add("1 hour", 60)
        add("2 hours", 120)
        submenu.addItem(.separator())
        add("Custom…", CODE_CUSTOM)
        return (submenu, items)
    }

    // MARK: - Mode transitions

    // Caffeinate: idle + display stay awake, but the Mac sleeps when the lid closes.
    func setCaffeinate(tag: Int, minutes: Int) {
        if lidActive { setLidCloseSleepDisabled(false); lidActive = false }
        if caffeineActivity == nil { beginCaffeineAssertion() }
        mode = .caffeinate
        activeTag = tag
        armTimer(tag: tag, minutes: minutes)
        refresh()
    }

    // Lid-close: everything caffeinate does, PLUS stays awake with the lid shut (pmset).
    func setLidClose(tag: Int, minutes: Int) {
        if !lidActive {
            if !enableLidFlag() {
                showLidUnavailableAlert()
                refresh() // leaves the previous mode untouched
                return
            }
            lidActive = true
        }
        if caffeineActivity == nil { beginCaffeineAssertion() } // act as caffeinate too
        mode = .lidClose
        activeTag = tag
        armTimer(tag: tag, minutes: minutes)
        refresh()
    }

    func setOff() {
        timer?.invalidate(); timer = nil
        if lidActive { setLidCloseSleepDisabled(false); lidActive = false }
        endCaffeineAssertion()
        mode = .off
        activeTag = CODE_INDEFINITE
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

    // Arms (or clears) the auto-off timer for the current mode. Indefinite = no timer.
    func armTimer(tag: Int, minutes: Int) {
        timer?.invalidate(); timer = nil
        guard tag != CODE_INDEFINITE else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: false) { [weak self] _ in
            self?.setOff()
        }
    }

    // MARK: - Menu actions

    @objc func selectCaffeineTimer(_ sender: NSMenuItem) {
        switch sender.tag {
        case CODE_OFF:
            if mode == .caffeinate { setOff() } else { refresh() } // already off
        case CODE_CUSTOM:
            guard let minutes = promptForMinutes() else { return }
            setCaffeinate(tag: CODE_CUSTOM, minutes: minutes)
        default:
            setCaffeinate(tag: sender.tag, minutes: max(sender.tag, 0))
        }
    }

    @objc func selectLidTimer(_ sender: NSMenuItem) {
        switch sender.tag {
        case CODE_OFF:
            if mode == .lidClose { setOff() } else { refresh() } // already off
        case CODE_CUSTOM:
            guard let minutes = promptForMinutes() else { return }
            setLidClose(tag: CODE_CUSTOM, minutes: minutes)
        default:
            setLidClose(tag: sender.tag, minutes: max(sender.tag, 0))
        }
    }

    // Updates checkmarks: the active feature's row, and the selected item in each submenu.
    func refresh() {
        caffeineMenuItem.state = (mode == .caffeinate) ? .on : .off
        lidMenuItem.state = (mode == .lidClose) ? .on : .off

        let caffeineSelection = (mode == .caffeinate) ? activeTag : CODE_OFF
        for item in caffeineDurationItems {
            item.state = (item.tag == caffeineSelection) ? .on : .off
        }
        let lidSelection = (mode == .lidClose) ? activeTag : CODE_OFF
        for item in lidDurationItems {
            item.state = (item.tag == lidSelection) ? .on : .off
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
        alert.messageText = "Enable “Keep Awake When Lid Closed”?"
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
        alert.runModal()
    }

    // MARK: - Shared helpers

    // Prompts for a whole number of minutes. Returns nil if cancelled or invalid.
    func promptForMinutes() -> Int? {
        let alert = NSAlert()
        alert.messageText = "Custom timer"
        alert.informativeText = "Keep awake for how many minutes?"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = "60"
        alert.accessoryView = field
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let minutes = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), minutes > 0 {
            return minutes
        }
        return nil
    }

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
        timer?.invalidate(); timer = nil
        if lidActive { setLidCloseSleepDisabled(false); lidActive = false }
        endCaffeineAssertion()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // Hides it from the Dock
let delegate = AppDelegate()
app.delegate = delegate
app.run()
