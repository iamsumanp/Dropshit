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
            return "Conversion failed: source file no longer exists."
        case .sourceUnreadable:
            return "Conversion failed: could not read the source."
        case .destinationUnwritable:
            return "Conversion failed: could not write to disk."
        case .encodingFailed(let reason):
            return "Conversion failed: \(reason)"
        case .cancelled:
            return "Conversion cancelled."
        }
    }
}
