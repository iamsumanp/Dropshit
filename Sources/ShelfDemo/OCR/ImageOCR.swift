import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Extracts plain text from an image file (JPEG/PNG/HEIC/TIFF/WebP).
enum ImageOCR {
    static func extractText(source: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw OCRError.sourceMissing
        }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw OCRError.sourceUnreadable
        }

        let lines: [RecognizedLine]
        do {
            lines = try await OCREngine.recognize(image: cgImage)
        } catch {
            throw OCRError.recognitionFailed(reason: error.localizedDescription)
        }

        let joined = lines.map(\.text).joined(separator: "\n")
        guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OCRError.noTextFound
        }
        return joined
    }
}
