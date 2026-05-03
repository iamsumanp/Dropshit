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
            return L("ocr.error.source-missing")
        case .sourceUnreadable:
            return L("ocr.error.source-unreadable")
        case .destinationUnwritable:
            return L("ocr.error.destination-unwritable")
        case .recognitionFailed(let reason):
            return String(format: L("ocr.error.recognition-failed"), reason)
        case .noTextFound:
            return L("ocr.error.no-text")
        case .cancelled:
            return L("ocr.error.cancelled")
        }
    }
}
