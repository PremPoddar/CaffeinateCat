import Cocoa
import IOKit.ps

// Everything that touches the system outside this process: pmset, the sudoers rule, the crash
// watchdog, and the battery. Nothing in here knows about modes or the panel.

// Where the passwordless pmset rule lives.
let SUDOERS_PATH = "/etc/sudoers.d/caffeinatecat"

// MARK: - Process runner

enum Shell {
    /// Runs a process to completion, returning its exit status and stdout.
    ///
    /// Blocks on a semaphore rather than `waitUntilExit`, which spins the current run loop while it
    /// waits — letting timers and clicks re-enter the caller half-way through a mode transition.
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        // Drain before waiting, so a chatty child can't fill the pipe and deadlock against us.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - pmset disablesleep

enum LidControl {
    /// Runs `sudo -n pmset -a disablesleep <0|1>`. Returns true on success.
    ///
    /// `disablesleep 1` sets the SleepDisabled flag in IOPMrootDomain, which is the only thing that
    /// keeps an Apple Silicon Mac awake with the lid closed (even on battery). Setting it requires
    /// root, so this relies on the scoped, passwordless sudoers rule installed by `installRule()`.
    /// `-n` makes sudo fail fast instead of blocking on a password prompt, since a menu-bar app has
    /// no terminal to answer one.
    static func setSleepDisabled(_ disabled: Bool) -> Bool {
        Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]).status == 0
    }

    /// Reads SleepDisabled back from `pmset -g`, so a "success" exit status can be double-checked
    /// against what the kernel actually has. nil when the value can't be read.
    static func isSleepDisabled() -> Bool? {
        let result = Shell.run("/usr/bin/pmset", ["-g"])
        guard result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count == 2, fields[0] == "SleepDisabled" {
                return fields[1] == "1"
            }
        }
        return nil
    }

    /// True if our passwordless pmset rule is installed. We check for our own sudoers file rather
    /// than probing sudo: `sudo -l` reports whether the user *may* run pmset at all (admins may,
    /// with a password) and is muddied by cached credentials. The enable path uses `sudo -n` as the
    /// real test and reinstalls if needed, so this only gates prompts and the options list.
    static var ruleInstalled: Bool {
        FileManager.default.fileExists(atPath: SUDOERS_PATH)
    }

    /// Installs a sudoers rule granting THIS user passwordless access to exactly the two pmset
    /// disablesleep commands, via one native admin prompt (Touch ID or password).
    ///
    /// The rule is written, validated and installed entirely by the root shell, into a root-owned
    /// temp file. Staging it in the user's own temp directory instead would leave a window between
    /// `visudo` and `install` in which any process running as the user could swap in a different,
    /// equally valid rule — and have it installed as root.
    ///
    /// Blocks until the prompt is answered; call it off the main thread.
    static func installRule() -> Bool {
        guard let user = sudoersSafeUserName() else { return false }
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
        let shell = [
            "t=$(/usr/bin/mktemp /tmp/caffeinatecat.XXXXXX) || exit 1",
            "echo '\(rule)' > $t && /usr/sbin/visudo -cf $t && /usr/bin/install -m 0440 -o root -g wheel $t \(SUDOERS_PATH)",
            "r=$?; /bin/rm -f $t; exit $r",
        ].joined(separator: "; ")
        return runAsAdmin(shell)
    }

    /// Removes the rule again. Blocks until the prompt is answered; call it off the main thread.
    static func removeRule() -> Bool {
        runAsAdmin("/bin/rm -f \(SUDOERS_PATH)")
    }

    /// The user name ends up inside a root shell command and a sudoers line, so anything outside a
    /// conservative character set is refused rather than escaped.
    private static func sudoersSafeUserName() -> String? {
        let user = NSUserName()
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !user.isEmpty, user.first != "-", user.allSatisfy(allowed.contains) else { return nil }
        return user
    }

    /// `shell` is embedded in an AppleScript string literal, so it must not contain `"` or `\`.
    private static func runAsAdmin(_ shell: String) -> Bool {
        precondition(!shell.contains("\"") && !shell.contains("\\"))
        let script = "do shell script \"\(shell)\" with administrator privileges"
        return Shell.run("/usr/bin/osascript", ["-e", script]).status == 0
    }
}

// MARK: - Crash watchdog

/// A detached `sh` that outlives this process and restores `disablesleep 0` once we're gone.
///
/// `cleanup()` covers quitting and signals we can catch, but not SIGKILL, Force Quit or a crash —
/// and SleepDisabled is persistent, so any of those would leave the Mac unable to sleep, lid closed
/// or not, until someone noticed. The watchdog runs in its own process group so neither launchd
/// (which kills a job's group when its main process exits) nor a group-wide signal takes it down
/// with us.
final class LidWatchdog {
    private var pid: pid_t = 0

    var isRunning: Bool { pid > 0 }

    func start() {
        stop()
        let script = "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 2; done; "
            + "/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0"

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // New process group, and close every descriptor we'd otherwise leak into it.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in [0, 1, 2] {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }

        var argv: [UnsafeMutablePointer<CChar>?] = (["/bin/sh", "-c", script] as [String]).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        // A fixed, minimal environment: every command above is an absolute path anyway.
        var envp: [UnsafeMutablePointer<CChar>?] = (["PATH=/usr/bin:/bin:/usr/sbin:/sbin"] as [String]).map { strdup($0) } + [nil]
        defer { envp.forEach { free($0) } }

        var child: pid_t = 0
        if posix_spawn(&child, "/bin/sh", &actions, &attributes, &argv, &envp) == 0 {
            pid = child
        } else {
            NSLog("CaffeinateCat: could not start the lid watchdog")
        }
    }

    /// Restarts the watchdog if it has died (someone killed it, or it hit an error).
    func ensureRunning() {
        guard pid > 0 else { return }
        if waitpid(pid, nil, WNOHANG) == pid {
            pid = 0
            start()
        }
    }

    /// Stops it without letting it run its restore: the caller is about to manage the flag itself.
    func stop() {
        guard pid > 0 else { return }
        kill(-pid, SIGKILL) // the whole group, so its pending `sleep` goes too
        waitpid(pid, nil, 0)
        pid = 0
    }
}

// MARK: - Battery

/// Calls `onChange` whenever macOS reports a power-source change (plugging in, charge ticking
/// down). Uses the IOKit run-loop source rather than polling.
final class BatteryMonitor {
    var onChange: (() -> Void)?
    private var source: CFRunLoopSource?

    func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue().onChange?()
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = source
    }

    /// Charge percentage while running on the internal battery; nil on AC power or with no battery.
    static func dischargingLevel() -> Int? {
        guard let battery = internalBattery(), !battery.onAC else { return nil }
        return battery.percent
    }

    /// Charge percentage whatever the power source; nil on a Mac without a battery.
    static func chargeLevel() -> Int? {
        internalBattery()?.percent
    }

    private static func internalBattery() -> (percent: Int, onAC: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let onAC = description[kIOPSPowerSourceStateKey] as? String != kIOPSBatteryPowerValue
            return (max(0, min(100, current * 100 / maximum)), onAC)
        }
        return nil
    }
}
