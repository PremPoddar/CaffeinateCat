import Cocoa

#if canImport(Sparkle)
import Sparkle

/// Owns Sparkle. CaffeinateCat is a menu-bar (LSUIElement) app, so Sparkle's windows would open behind
/// other apps unless we bring ourselves forward. Scheduled checks stay quiet: they only mark the panel
/// row ("Update to 1.3.1…") and the user opens the update from there.
final class UpdateController: NSObject, SPUStandardUserDriverDelegate {
    let isAvailable = true

    private(set) var availableVersion: String? {
        didSet { if availableVersion != oldValue { onChange?() } }
    }
    var onChange: (() -> Void)?

    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Near launch Sparkle shows the update itself; any other scheduled update is only flagged.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if handleShowingUpdate {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            availableVersion = update.displayVersionString
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
}

#else

/// Builds without Sparkle (a plain swiftc build, or a Mac App Store build, which cannot contain it) have
/// no updater, so the panel hides its "Check for Updates…" row.
final class UpdateController {
    let isAvailable = false
    let availableVersion: String? = nil
    var onChange: (() -> Void)?

    func checkForUpdates() {}
}

#endif
