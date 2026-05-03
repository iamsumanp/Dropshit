import Foundation
import SwiftUI

/// Short helper for plain-Swift / AppKit lookups. Resolves keys against the
/// .lproj bundle that matches the user's chosen language. We can't rely on
/// the standard `AppleLanguages` UserDefaults override here because that
/// override only steers `Bundle.main`'s preferred localizations — SwiftPM's
/// resource sub-bundle (`Bundle.module`) ignores it and always falls back
/// to the development localization, so we resolve the lproj manually.
func L(_ key: String, comment: StaticString = "") -> String {
    let bundle = LanguagePreference.activeBundle()
    return NSLocalizedString(key, bundle: bundle, comment: String(describing: comment))
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
            // Drop the cached bundle so a subsequent L() call re-resolves
            // against the freshly-chosen language.
            cachedBundle = nil
        }
    }

    /// Must be called once at process start, before any localized lookup. The
    /// `AppleLanguages` value is read by NSBundle the first time it resolves
    /// a string — overwriting it later in the same process is too late.
    static func applyAtLaunch() {
        applyToAppleLanguages(current)
        // Warm the bundle cache. Cheap, and means the first L() call doesn't
        // pay for filesystem lookup of the lproj path.
        _ = activeBundle()
    }

    /// Returns the `.lproj` sub-bundle of `Bundle.module` matching the user's
    /// chosen language, or `Bundle.module` itself if no override applies (or
    /// the lproj can't be opened, in which case NSLocalizedString will fall
    /// through to its dev-localization default).
    static func activeBundle() -> Bundle {
        // Lock onto the resolved code per-process; the user can't change
        // language without a relaunch, so this is safe to cache.
        if let cached = cachedBundle { return cached }
        let resolved = resolveActiveBundle()
        cachedBundle = resolved
        return resolved
    }

    private static var cachedBundle: Bundle?

    private static func resolveActiveBundle() -> Bundle {
        let module = Bundle.module
        let code: String
        switch current {
        case .system:
            // Pick the first system-preferred language that we actually have
            // an lproj for. Falls through to module (dev localization) when
            // none of the user's preferred languages are translated.
            let preferred = Locale.preferredLanguages
            let available = Set(module.localizations.map { $0.lowercased() })
            let match = preferred.first { lang in
                available.contains(lang.lowercased())
                    || available.contains(canonicalize(lang).lowercased())
            }
            guard let match else { return module }
            code = canonicalize(match)
        case let explicit:
            code = explicit.rawValue
        }
        // SwiftPM lower-cases lproj directory names on disk for some locales
        // (e.g. zh-Hans → zh-hans), so probe both variants.
        let candidates = [code, code.lowercased()]
        for candidate in candidates {
            if let path = module.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return module
    }

    /// Strips region/script qualifiers we don't care about (e.g. `en-US` → `en`)
    /// while preserving canonical script tags we use directly (`zh-Hans`,
    /// `zh-Hant`). Keeps fallback matching forgiving.
    private static func canonicalize(_ tag: String) -> String {
        let lower = tag.lowercased()
        if lower.hasPrefix("zh-hans") { return "zh-Hans" }
        if lower.hasPrefix("zh-hant") { return "zh-Hant" }
        return String(tag.split(separator: "-").first ?? Substring(tag))
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

}
