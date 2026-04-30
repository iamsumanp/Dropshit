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
        case .never: return "Never"
        case .oneDay: return "After 1 day"
        case .sevenDays: return "After 7 days"
        case .tenDays: return "After 10 days"
        case .thirtyDays: return "After 30 days"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Auto-delete shelves")
                    .font(.system(size: 13, weight: .medium))
                Picker("", selection: $expiryDays) {
                    ForEach(ShelfExpiry.allCases) { opt in
                        Text(opt.label).tag(opt.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Text("A shelf is removed when its most recent activity is older than the chosen duration. Files dragged in from Finder are kept on disk; only files staged inside the shelf (e.g. clipboard images) are deleted. Pinned shelves are never auto-deleted regardless of this setting.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Park new shelves at the top-right corner", isOn: $autoParkTopRight)
                    .toggleStyle(.switch)
                Text("After the first item lands on a freshly-created shelf, the shelf slides up to the top-right of the screen and out of the way. New shelves stack vertically below it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Collapse expanded shelf when clicking outside", isOn: $closeOnOutsideClick)
                    .toggleStyle(.switch)
                Text("When a shelf is in its expanded detail view and you click somewhere else, it folds back to the small pill. The pill stays put — collapsed shelves are unaffected.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in applyLaunchAtLogin(newValue) }
                ))
                .toggleStyle(.switch)
                Text("Starts Shelf automatically when you log in. We install a LaunchAgent in ~/Library/LaunchAgents — works for both packaged and unsigned dev builds.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
        .onAppear {
            launchAtLogin = LaunchAtLoginManager.isEnabled
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
            alert.messageText = "Couldn't Update Login Items"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
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
