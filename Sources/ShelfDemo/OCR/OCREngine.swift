import Foundation
import Vision
import CoreGraphics

/// One recognized line of text. `boundingBox` uses Vision's native
/// normalized-bottom-up convention: origin at lower-left of the image,
/// values in 0...1.
struct RecognizedLine: Equatable, Sendable {
    let text: String
    let boundingBox: CGRect
}

/// Pure async Vision wrapper. Designed to be called off the main thread.
enum OCREngine {
    static func recognize(image: CGImage) async throws -> [RecognizedLine] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { obs -> RecognizedLine? in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return RecognizedLine(
                        text: candidate.string,
                        boundingBox: obs.boundingBox
                    )
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
