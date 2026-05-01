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

    /// Rebuild a searchable copy of `source` next to it as
    /// `<stem> (searchable).pdf`. Falls back to `~/Library/Caches/Dropshit/OCR/`
    /// when the source directory is read-only.
    static func makeSearchable(
        source: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw OCRError.sourceMissing
        }
        guard let pdf = PDFDocument(url: source), pdf.pageCount > 0 else {
            throw OCRError.sourceUnreadable
        }

        let finalDest = try resolveSearchableDestination(for: source)
        let tempURL = finalDest
            .deletingPathExtension()
            .appendingPathExtension("part\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("pdf")

        // Open a CGContext-backed PDF for writing. Pass nil mediaBox here; we
        // override per-page in beginPDFPage's pageInfo dict so each page can
        // adopt its source's exact size.
        guard let consumer = CGDataConsumer(url: tempURL as CFURL) else {
            throw OCRError.destinationUnwritable
        }
        var emptyBox = CGRect.zero
        guard let writeContext = CGContext(consumer: consumer, mediaBox: &emptyBox, nil) else {
            throw OCRError.destinationUnwritable
        }

        let pageCount = pdf.pageCount
        for i in 0..<pageCount {
            do {
                try Task.checkCancellation()
            } catch {
                writeContext.closePDF()
                try? FileManager.default.removeItem(at: tempURL)
                throw OCRError.cancelled
            }
            guard let page = pdf.page(at: i),
                  let pageImage = renderPageImage(page) else {
                progress(Double(i + 1) / Double(pageCount))
                continue
            }

            let pageBounds = page.bounds(for: .mediaBox)
            let lines: [RecognizedLine]
            do {
                lines = try await OCREngine.recognize(image: pageImage)
            } catch {
                writeContext.closePDF()
                try? FileManager.default.removeItem(at: tempURL)
                throw OCRError.recognitionFailed(reason: error.localizedDescription)
            }

            try drawSearchablePage(
                into: writeContext,
                pageBounds: pageBounds,
                pageImage: pageImage,
                lines: lines
            )

            progress(Double(i + 1) / Double(pageCount))
        }

        writeContext.closePDF()

        do {
            try FileManager.default.moveItem(at: tempURL, to: finalDest)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw OCRError.destinationUnwritable
        }
        return finalDest
    }

    /// Draw one page into the output PDF: the rendered imagery as a JPEG
    /// at quality 0.9 (re-encoded explicitly so CGPDFContext embeds the
    /// JPEG bytes as-is instead of re-compressing at its lower default),
    /// plus invisible CoreText runs over each recognized line.
    private static func drawSearchablePage(
        into ctx: CGContext,
        pageBounds: CGRect,
        pageImage: CGImage,
        lines: [RecognizedLine]
    ) throws {
        // Re-encode the page imagery as JPEG quality 0.9. CGPDFContext
        // recognizes a JPEG-backed CGImage and embeds the source bytes
        // verbatim — that's how we get the 0.9 quality the spec calls for.
        let jpegData = NSMutableData()
        guard let imageDest = CGImageDestinationCreateWithData(
            jpegData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            throw OCRError.recognitionFailed(reason: "image encoder unavailable")
        }
        let imageProps: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        CGImageDestinationAddImage(imageDest, pageImage, imageProps as CFDictionary)
        guard CGImageDestinationFinalize(imageDest) else {
            throw OCRError.recognitionFailed(reason: "image encode failed")
        }
        guard let jpegSource = CGImageSourceCreateWithData(jpegData, nil),
              let embeddableImage = CGImageSourceCreateImageAtIndex(jpegSource, 0, nil)
        else {
            throw OCRError.recognitionFailed(reason: "JPEG read-back failed")
        }

        var rect = pageBounds
        let mediaData = NSData(bytes: &rect, length: MemoryLayout<CGRect>.size)
        let pageInfo: [String: Any] = [
            kCGPDFContextMediaBox as String: mediaData
        ]
        ctx.beginPDFPage(pageInfo as CFDictionary)
        ctx.draw(embeddableImage, in: pageBounds)

        // Invisible text mode: glyph metrics are recorded so selection /
        // search work, but no visible ink is laid down.
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for line in lines {
            // Vision's boundingBox is normalized + bottom-left origin —
            // exactly the convention CGContext uses, so scale directly.
            let lineRect = CGRect(
                x: line.boundingBox.minX * pageBounds.width,
                y: line.boundingBox.minY * pageBounds.height,
                width: line.boundingBox.width * pageBounds.width,
                height: line.boundingBox.height * pageBounds.height
            )
            // OCR boxes are tight to glyphs; using the box height as the
            // font size keeps select-rects close to what the user sees.
            let fontSize = max(lineRect.height, 1)
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font
            ]
            let attr = NSAttributedString(string: line.text, attributes: attributes)
            let ctLine = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: lineRect.minX, y: lineRect.minY)
            CTLineDraw(ctLine, ctx)
        }
        ctx.restoreGState()

        ctx.endPDFPage()
    }

    private static func resolveSearchableDestination(for source: URL) throws -> URL {
        let stem = source.deletingPathExtension().lastPathComponent + " (searchable)"
        let preferred = source
            .deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension("pdf")
        let candidate = UniqueDestination.url(preferred: preferred)

        // Empirical writability probe — same pattern as the Conversion module.
        let probe = candidate
            .deletingPathExtension()
            .appendingPathExtension("probe\(UUID().uuidString.prefix(6))")
        do {
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return candidate
        } catch {
            let cache = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Dropshit/OCR", isDirectory: true)
            try FileManager.default.createDirectory(
                at: cache, withIntermediateDirectories: true
            )
            let p = cache.appendingPathComponent(stem).appendingPathExtension("pdf")
            return UniqueDestination.url(preferred: p)
        }
    }
}

// `import AppKit` is implicit in the project (every other file does); the
// `NSColor.white.cgColor` call above relies on it being resolved through the
// SwiftPM module's transitive AppKit import. If a future refactor splits
// modules, switch to `CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)` here.
import AppKit
