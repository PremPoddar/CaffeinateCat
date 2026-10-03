import Cocoa

// What survives a relaunch: the user's options and duration choices, plus the bookkeeping the
// safety mechanisms need. Also the launch-at-login agent.

// What the custom duration starts at, and what it is restored to whenever it is emptied to zero.
// A zero-length custom value can't run, so it is never left in place.
let DEFAULT_CUSTOM_HOURS = 2
let DEFAULT_CUSTOM_MINUTES = 0

/// Battery levels that switch keep-awake off when the charge falls through them (with the
/// low-battery option on). Two, so a run started below the first still has a floor.
let LOW_BATTERY_THRESHOLDS = [20, 10]

/// Thin typed wrapper over UserDefaults. Every read goes to the store, so there is no cached copy
/// to fall out of step with it.
final class Preferences {
    private let defaults = UserDefaults.standard

    private enum Key {
        static let allowDisplaySleep = "allowDisplaySleep"
        static let stopOnLowBattery = "stopOnLowBattery"
        static let activateOnLaunch = "activateOnLaunch"
        static let optionsExpanded = "optionsExpanded"
        static let lidSetupDeclined = "lidSetupDeclined"
        static let lidFlagOwned = "lidFlagOwned"
        static let lastFeature = "lastFeature"
        static func duration(_ feature: Feature) -> String { "\(feature.key).duration" }
        static func customHours(_ feature: Feature) -> String { "\(feature.key).customHours" }
        static func customMinutes(_ feature: Feature) -> String { "\(feature.key).customMinutes" }
    }

    init() {
        defaults.register(defaults: [
            Key.stopOnLowBattery: true,
            Key.activateOnLaunch: true,
            Key.customHours(.caffeinate): DEFAULT_CUSTOM_HOURS,
            Key.customMinutes(.caffeinate): DEFAULT_CUSTOM_MINUTES,
            Key.customHours(.lid): DEFAULT_CUSTOM_HOURS,
            Key.customMinutes(.lid): DEFAULT_CUSTOM_MINUTES,
        ])
    }

    /// Keep the system awake but let the display turn off on its normal schedule.
    var allowDisplaySleep: Bool {
        get { defaults.bool(forKey: Key.allowDisplaySleep) }
        set { defaults.set(newValue, forKey: Key.allowDisplaySleep) }
    }

    var stopOnLowBattery: Bool {
        get { defaults.bool(forKey: Key.stopOnLowBattery) }
        set { defaults.set(newValue, forKey: Key.stopOnLowBattery) }
    }

    var activateOnLaunch: Bool {
        get { defaults.bool(forKey: Key.activateOnLaunch) }
        set { defaults.set(newValue, forKey: Key.activateOnLaunch) }
    }

    var optionsExpanded: Bool {
        get { defaults.bool(forKey: Key.optionsExpanded) }
        set { defaults.set(newValue, forKey: Key.optionsExpanded) }
    }

    /// The user answered "Not Now" to the first-launch lid setup; don't ask on every launch.
    var lidSetupDeclined: Bool {
        get { defaults.bool(forKey: Key.lidSetupDeclined) }
        set { defaults.set(newValue, forKey: Key.lidSetupDeclined) }
    }

    /// Set just before we turn `disablesleep` on and cleared once it is verifiably off again. Still
    /// set at launch means the last run died holding the flag, so it has to be restored.
    var lidFlagOwned: Bool {
        get { defaults.bool(forKey: Key.lidFlagOwned) }
        set {
            defaults.set(newValue, forKey: Key.lidFlagOwned)
            defaults.synchronize() // it's only useful if it's on disk before we might crash
        }
    }

    /// The feature right-click turns on.
    var lastFeature: Feature {
        get { defaults.string(forKey: Key.lastFeature) == Feature.lid.key ? .lid : .caffeinate }
        set { defaults.set(newValue.key, forKey: Key.lastFeature) }
    }

    // Durations are stored as an Int: minutes for a preset, or a negative sentinel.
    func duration(for feature: Feature) -> AwakeDuration {
        switch defaults.integer(forKey: Key.duration(feature)) {
        case 0, -1: return .indefinite
        case -2:    return .custom
        case let minutes: return .minutes(minutes)
        }
    }

    func setDuration(_ duration: AwakeDuration, for feature: Feature) {
        let raw: Int
        switch duration {
        case .indefinite:           raw = -1
        case .custom:               raw = -2
        case .minutes(let minutes): raw = minutes
        }
        defaults.set(raw, forKey: Key.duration(feature))
    }

    func customHours(for feature: Feature) -> Int {
        max(0, min(23, defaults.integer(forKey: Key.customHours(feature))))
    }

    func customMinutes(for feature: Feature) -> Int {
        max(0, min(59, defaults.integer(forKey: Key.customMinutes(feature))))
    }

    func setCustom(hours: Int, minutes: Int, for feature: Feature) {
        defaults.set(max(0, min(23, hours)), forKey: Key.customHours(feature))
        defaults.set(max(0, min(59, minutes)), forKey: Key.customMinutes(feature))
    }
}

private extension Feature {
    var key: String { self == .caffeinate ? "caffeinate" : "lid" }
}

// MARK: - Launch at login

/// A per-user LaunchAgent. SMAppService would need macOS 13 and a signed bundle; this works for the
/// bare `swiftc` binary and the .app alike, back to macOS 11.
enum LoginItem {
    private static let label = "com.caffeinatecat.launcher"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard enabled else {
            do {
                if isEnabled { try FileManager.default.removeItem(at: plistURL) }
                return true
            } catch {
                return false
            }
        }

        // Launched through LaunchServices when we're a bundle, so it runs as a normal app instance;
        // the bare binary is run directly. Either way the agent must not reap our process group on
        // exit, or it would take the lid watchdog with it.
        let bundle = Bundle.main.bundleURL
        let arguments = bundle.pathExtension == "app"
            ? ["/usr/bin/open", "-a", bundle.path]
            : [Bundle.main.executableURL?.path ?? CommandLine.arguments[0]]
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "AbandonProcessGroup": true,
        ]
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Rewrites the agent with the current path, so moving the app doesn't silently break it.
    static func refreshIfEnabled() {
        if isEnabled { setEnabled(true) }
    }
}
