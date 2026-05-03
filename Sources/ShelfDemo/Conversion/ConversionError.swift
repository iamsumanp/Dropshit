import Foundation

enum ConversionError: Error, Equatable {
    case sourceMissing
    case sourceUnreadable
    case destinationUnwritable
    case encodingFailed(reason: String)
    case cancelled

    /// User-facing string for the toast banner.
    var displayMessage: String {
        switch self {
        case .sourceMissing:
            return L("conversion.error.source-missing")
        case .sourceUnreadable:
            return L("conversion.error.source-unreadable")
        case .destinationUnwritable:
            return L("conversion.error.destination-unwritable")
        case .encodingFailed(let reason):
            return String(format: L("conversion.error.encoding-failed"), reason)
        case .cancelled:
            return L("conversion.error.cancelled")
        }
    }
}
