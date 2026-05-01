import Foundation

enum OCRError: Error, Equatable {
    case sourceMissing
    case sourceUnreadable
    case destinationUnwritable
    case recognitionFailed(reason: String)
    case noTextFound
    case cancelled

    /// User-facing string for the toast banner.
    var displayMessage: String {
        switch self {
        case .sourceMissing:
            return "OCR failed: source file no longer exists."
        case .sourceUnreadable:
            return "OCR failed: could not read the source."
        case .destinationUnwritable:
            return "OCR failed: could not write to disk."
        case .recognitionFailed(let reason):
            return "OCR failed: \(reason)"
        case .noTextFound:
            return "OCR found no text."
        case .cancelled:
            return "OCR cancelled."
        }
    }
}
