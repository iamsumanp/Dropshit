import Foundation

enum PDFEditError: Error, Equatable {
    case sourceMissing
    case sourceUnreadable
    case destinationUnwritable
    case flattenFailed(reason: String)
    case cancelled

    var displayMessage: String {
        switch self {
        case .sourceMissing:
            return "PDF edit failed: source file no longer exists."
        case .sourceUnreadable:
            return "PDF edit failed: could not read the source."
        case .destinationUnwritable:
            return "PDF edit failed: could not write to disk."
        case .flattenFailed(let reason):
            return "PDF edit failed: \(reason)"
        case .cancelled:
            return "PDF edit cancelled."
        }
    }
}
