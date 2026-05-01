import Foundation
import PDFKit
import CoreGraphics
import CoreText

/// Multi-page PDF orchestrator. Public entry points:
///   - `extractText(source:progress:) -> String`
///   - `makeSearchable(source:progress:) -> URL`   (added in Task 5)
enum PDFOCR {
    /// DPI used to rasterize each PDF page before sending to Vision and
    /// before re-encoding into the rebuilt searchable PDF.
    static let renderDPI: CGFloat = 150
    static let renderScale: CGFloat = renderDPI / 72.0

    /// Joins a list of per-page recognized strings with the page-marker
    /// separator the spec requires.
    static func joinedPageText(_ pages: [String]) -> String {
        pages.enumerated().map { (index, text) in
            "--- Page \(index + 1) ---\n\n\(text)"
        }.joined(separator: "\n\n")
    }

    /// Render `page` at `renderDPI` and return the resulting `CGImage`.
    /// Returns `nil` on context-allocation failure (very rare).
    static func renderPageImage(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let pixelWidth = Int(ceil(bounds.width * renderScale))
        let pixelHeight = Int(ceil(bounds.height * renderScale))
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // White background — many scanned PDFs draw black text on transparent.
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        ctx.scaleBy(x: renderScale, y: renderScale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// Recognize text on each page, return concatenated string with page
    /// markers between sections. `progress(0...1)` is called on the calling
    /// actor after each page is processed.
    static func extractText(
        source: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw OCRError.sourceMissing
        }
        guard let pdf = PDFDocument(url: source), pdf.pageCount > 0 else {
            throw OCRError.sourceUnreadable
        }

        var pageTexts: [String] = []
        let pageCount = pdf.pageCount
        for i in 0..<pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: i),
                  let image = renderPageImage(page) else {
                pageTexts.append("")
                progress(Double(i + 1) / Double(pageCount))
                continue
            }
            let lines: [RecognizedLine]
            do {
                lines = try await OCREngine.recognize(image: image)
            } catch {
                throw OCRError.recognitionFailed(reason: error.localizedDescription)
            }
            pageTexts.append(lines.map(\.text).joined(separator: "\n"))
            progress(Double(i + 1) / Double(pageCount))
        }

        let joined = joinedPageText(pageTexts)
        guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OCRError.noTextFound
        }
        return joined
    }
}

// `import AppKit` is implicit in the project (every other file does); the
// `NSColor.white.cgColor` call above relies on it being resolved through the
// SwiftPM module's transitive AppKit import. If a future refactor splits
// modules, switch to `CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)` here.
import AppKit
