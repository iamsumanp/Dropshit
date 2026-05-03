import Foundation
import SwiftUI

/// Short helper for plain-Swift / AppKit lookups. Resolves keys against
/// `Bundle.module` (where SwiftPM puts our .lproj resources) so localizations
/// are picked up regardless of how the build is run.
func L(_ key: String, comment: StaticString = "") -> String {
    NSLocalizedString(key, bundle: .module, comment: String(describing: comment))
}

/// SwiftUI: prefer `Text(L("key"))` for already-resolved strings.
/// For format interpolation use `String(format: L("..."), ...)` to avoid
/// LocalizedStringKey's auto-interpolation.

/// Available UI languages for the override picker. Keep in sync with the
/// `.lproj` directories under `Sources/ShelfDemo/Resources/`.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system  // sentinel — use macOS preferred language
    case english = "en"
    case polish = "pl"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case italian = "it"
    case chineseSimplified = "zh-Hans"
    case japanese = "ja"

    var id: String { rawValue }

    /// Native-language name, shown in the picker so each option is
    /// recognizable regardless of the user's current UI language.
    var displayName: String {
        switch self {
        case .system: return L("language.system")
        case .english: return "English"
        case .polish: return "Polski"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .spanish: return "Español"
        case .italian: return "Italiano"
        case .chineseSimplified: return "简体中文"
        case .japanese: return "日本語"
        }
    }
}

/// Owns the user's UI-language override. Default = follow macOS system.
/// Override is implemented via the `AppleLanguages` user-defaults key, read
/// once by `NSBundle` at first lookup; switching requires a relaunch.
enum LanguagePreference {
    private static let storageKey = "shelf.uiLanguage"
    private static let appleLanguagesKey = "AppleLanguages"

    static var current: AppLanguage {
        get {
            let raw = UserDefaults.standard.string(forKey: storageKey) ?? AppLanguage.system.rawValue
            return AppLanguage(rawValue: raw) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
            applyToAppleLanguages(newValue)
        }
    }

    /// Must be called once at process start, before any localized lookup. The
    /// `AppleLanguages` value is read by NSBundle the first time it resolves
    /// a string — overwriting it later in the same process is too late.
    static func applyAtLaunch() {
        applyToAppleLanguages(current)
    }

    /// Writes (or clears) the override into the user-defaults `AppleLanguages`
    /// key. Removing the key restores macOS's natural language preference.
    private static func applyToAppleLanguages(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        switch language {
        case .system:
            defaults.removeObject(forKey: appleLanguagesKey)
        case let explicit:
            defaults.set([explicit.rawValue], forKey: appleLanguagesKey)
        }
    }

    /// Re-launches the app so the new language takes effect. Falls back to
    /// quitting if `NSWorkspace` can't reopen the bundle (rare — happens for
    /// raw SwiftPM debug binaries that aren't a proper `.app`).
    @MainActor
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let isAppBundle = bundleURL.pathExtension == "app"
        if isAppBundle {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
                Task { @MainActor in NSApp.terminate(nil) }
            }
        } else {
            // Dev / raw executable — best effort: re-exec the same binary.
            let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            try? process.run()
            NSApp.terminate(nil)
        }
    }
}
