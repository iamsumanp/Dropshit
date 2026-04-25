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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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

                Text("A shelf is removed when its most recent activity is older than the chosen duration. Files dragged in from Finder are kept on disk; only files staged inside the shelf (e.g. clipboard images) are deleted.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 360, alignment: .leading)
    }
}
