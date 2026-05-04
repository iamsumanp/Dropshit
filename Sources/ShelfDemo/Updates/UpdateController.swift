import AppKit
import Sparkle

/// Owns the Sparkle updater controller. One instance, created at launch and
/// retained for the app's lifetime by AppDelegate.
///
/// We use SPUStandardUpdaterController (vs SPUUpdater + SPUStandardUserDriver
/// directly) because it provides the standard prompt UI and binds correctly
/// to NSMenuItem validation out of the box.
@MainActor
final class UpdateController {
    /// Exposed so the menu item can target it directly with
    /// `#selector(SPUStandardUpdaterController.checkForUpdates(_:))`. That
    /// hookup gives us automatic NSMenuItem validation (Sparkle disables the
    /// item while a check or download is already running) without any glue.
    let updaterController: SPUStandardUpdaterController

    init() {
        // startingUpdater: true → Sparkle begins its periodic check timer
        //   immediately if SUEnableAutomaticChecks is on (default).
        // userDriverDelegate: nil — the standard driver's defaults are fine
        //   (modal "Update available" prompt; auto-installs on quit if user
        //   chose "Install on Quit").
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Bridges Sparkle's `SUEnableAutomaticChecks` UserDefaults key, which is
    /// the key that SPUUpdater reads itself. Setting it through Sparkle's API
    /// (`updater.automaticallyChecksForUpdates`) would also work, but the
    /// raw key is what the persisted setting is — exposing it as a static
    /// keeps SettingsView decoupled from Sparkle imports.
    static var automaticallyChecksForUpdates: Bool {
        get {
            // Sparkle's documented default is `true` when the key is absent.
            if UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "SUEnableAutomaticChecks")
        }
    }
}
