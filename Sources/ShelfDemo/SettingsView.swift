import AppKit
import SwiftUI

enum ShelfExpiry: Int, CaseIterable, Identifiable {
    case never = 0
    case oneDay = 1
    case sevenDays = 7
    case tenDays = 10
    case thirtyDays = 30

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .never: return L("Never")
        case .oneDay: return L("After 1 day")
        case .sevenDays: return L("After 7 days")
        case .tenDays: return L("After 10 days")
        case .thirtyDays: return L("After 30 days")
        }
    }
}

struct SettingsView: View {
    @AppStorage("shelf.expiryDays") private var expiryDays: Int = ShelfExpiry.tenDays.rawValue
    @AppStorage("shelf.autoParkTopRight") private var autoParkTopRight: Bool = false
    @AppStorage("shelf.closeOnOutsideClick") private var closeOnOutsideClick: Bool = false

    /// Source of truth is whether our LaunchAgent plist exists in
    /// `~/Library/LaunchAgents/`. Mirrored into local state so the toggle
    /// stays in sync if the file is removed externally.
    @State private var launchAtLogin: Bool = LaunchAtLoginManager.isEnabled

    @State private var pickedLanguage: AppLanguage = LanguagePreference.current

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Settings"))
                .font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Auto-delete shelves"))
                    .font(.system(size: 13, weight: .medium))
                Picker("", selection: $expiryDays) {
                    ForEach(ShelfExpiry.allCases) { opt in
                        Text(opt.label).tag(opt.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                // The .menu Picker bridges to NSPopUpButton and caches its
                // option Text views, so the dropdown doesn't relabel when
                // the language flips. A fresh identity on language change
                // forces it to rebuild from scratch.
                .id(pickedLanguage)

                Text(L("settings.expiry.description"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle(L("Park new shelves at the top-right corner"), isOn: $autoParkTopRight)
                    .toggleStyle(.switch)
                Text(L("settings.park.description"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle(L("Collapse expanded shelf when clicking outside"), isOn: $closeOnOutsideClick)
                    .toggleStyle(.switch)
                Text(L("settings.collapse.description"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Language"))
                    .font(.system(size: 13, weight: .medium))
                // Custom binding so the LanguagePreference write happens
                // synchronously inside the Picker's setter, before SwiftUI
                // tears down anything in response to the @State change.
                // .onChange is unreliable here — when the surrounding view
                // gets re-identified by a peer Picker's .id(), the handler
                // can be discarded before it runs.
                Picker("", selection: Binding(
                    get: { pickedLanguage },
                    set: { newValue in
                        pickedLanguage = newValue
                        LanguagePreference.current = newValue
                    }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Text(L("settings.language.description"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle(L("Launch at login"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in applyLaunchAtLogin(newValue) }
                ))
                .toggleStyle(.switch)
                Text(L("settings.launch.description"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
        .onAppear {
            launchAtLogin = LaunchAtLoginManager.isEnabled
            pickedLanguage = LanguagePreference.current
        }
    }

    private func applyLaunchAtLogin(_ enable: Bool) {
        do {
            try LaunchAtLoginManager.setEnabled(enable)
            launchAtLogin = LaunchAtLoginManager.isEnabled
        } catch {
            NSLog("Shelf: launch-at-login toggle failed — \(error)")
            launchAtLogin = LaunchAtLoginManager.isEnabled
            let alert = NSAlert()
            alert.messageText = L("Couldn't Update Login Items")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
        }
    }
}

/// Writes a LaunchAgent plist to `~/Library/LaunchAgents/` so launchd will
/// start Shelf at the next login. Works for both `.app` bundles (uses
/// `/usr/bin/open -a` so the app activates with the right policy) and raw
/// SwiftPM debug binaries (executes them directly). Toggling off just
/// removes the plist — already-running processes keep running until the
/// user logs out, which is fine because the user is editing settings inside
/// that running process.
enum LaunchAtLoginManager {
    static let label = "com.shelf.ShelfDemo.LaunchAgent"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enable: Bool) throws {
        if enable {
            try install()
        } else {
            try uninstall()
        }
    }

    private static func install() throws {
        let dir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )

        let arguments: [String]
        if let appURL = appBundleURL() {
            // Activation through `open -a` — launchd execs the binary directly
            // otherwise, which doesn't give a `.app` its expected activation
            // policy and would cause a duplicate process.
            arguments = ["/usr/bin/open", "-a", appURL.path]
        } else {
            // Dev / raw executable — launch it directly. Path is captured at
            // toggle time, so if the user later moves the binary they need
            // to re-toggle.
            arguments = [Bundle.main.executablePath ?? CommandLine.arguments[0]]
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "RunAtLoad": true,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: plistURL, options: .atomic)
    }

    private static func uninstall() throws {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private static func appBundleURL() -> URL? {
        let path = Bundle.main.bundlePath
        return path.hasSuffix(".app") ? URL(fileURLWithPath: path) : nil
    }
}
