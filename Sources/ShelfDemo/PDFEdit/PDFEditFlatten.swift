import AppKit
import Foundation
import PDFKit
import CoreGraphics
import CoreText

enum PDFEditFlatten {
    static let renderDPI: CGFloat = 150
    static let renderScale: CGFloat = renderDPI / 72.0
    static let outputJPEGQuality: Double = 0.9

    /// Flatten `edits` into a new PDF beside `source`. Returns the URL of
    /// the new file. `progress(0...1)` is reported per page.
    static func flatten(
        source: URL,
        edits: PDFEditDocument,
        progress: @Sendable (Double) -> Void
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw PDFEditError.sourceMissing
        }
        guard let pdf = PDFDocument(url: source), pdf.pageCount > 0 else {
            throw PDFEditError.sourceUnreadable
        }

        let finalDest = try resolveDestination(for: source)
        let tempURL = finalDest
            .deletingPathExtension()
            .appendingPathExtension("part\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("pdf")

        guard let consumer = CGDataConsumer(url: tempURL as CFURL) else {
            throw PDFEditError.destinationUnwritable
        }
        var emptyBox = CGRect.zero
        guard let writeContext = CGContext(consumer: consumer, mediaBox: &emptyBox, nil) else {
            throw PDFEditError.destinationUnwritable
        }

        // Group edits by page so we don't re-iterate the full list per page.
        let editsByPage: [Int: [PDFTextEdit]] = Dictionary(
            grouping: edits.edits, by: \.pageIndex
        )

        let pageCount = pdf.pageCount
        for i in 0..<pageCount {
            do {
                try Task.checkCancellation()
            } catch {
                writeContext.closePDF()
                try? FileManager.default.removeItem(at: tempURL)
                throw PDFEditError.cancelled
            }
            guard let page = pdf.page(at: i) else {
                progress(Double(i + 1) / Double(pageCount))
                continue
            }
            let pageBounds = page.bounds(for: .mediaBox)
            try drawPage(
                into: writeContext,
                page: page,
                pageBounds: pageBounds,
                edits: editsByPage[i] ?? []
            )
            progress(Double(i + 1) / Double(pageCount))
        }

        writeContext.closePDF()

        do {
            try FileManager.default.moveItem(at: tempURL, to: finalDest)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw PDFEditError.destinationUnwritable
        }
        return finalDest
    }

    private static func drawPage(
        into ctx: CGContext,
        page: PDFPage,
        pageBounds: CGRect,
        edits: [PDFTextEdit]
    ) throws {
        // Render the page as a CGImage (white background, then page draw).
        let pixelWidth = Int(ceil(pageBounds.width * renderScale))
        let pixelHeight = Int(ceil(pageBounds.height * renderScale))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let renderCtx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PDFEditError.flattenFailed(reason: "couldn't allocate render context")
        }
        renderCtx.setFillColor(NSColor.white.cgColor)
        renderCtx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        renderCtx.scaleBy(x: renderScale, y: renderScale)
        page.draw(with: .mediaBox, to: renderCtx)
        guard let pageImage = renderCtx.makeImage() else {
            throw PDFEditError.flattenFailed(reason: "couldn't render page image")
        }

        // Re-encode as JPEG quality 0.9 so CGPDFContext embeds verbatim.
        let jpegData = NSMutableData()
        guard let imageDest = CGImageDestinationCreateWithData(
            jpegData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            throw PDFEditError.flattenFailed(reason: "image encoder unavailable")
        }
        let imageProps: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: outputJPEGQuality
        ]
        CGImageDestinationAddImage(imageDest, pageImage, imageProps as CFDictionary)
        guard CGImageDestinationFinalize(imageDest) else {
            throw PDFEditError.flattenFailed(reason: "image encode failed")
        }
        guard let jpegSource = CGImageSourceCreateWithData(jpegData, nil),
              let embeddable = CGImageSourceCreateImageAtIndex(jpegSource, 0, nil) else {
            throw PDFEditError.flattenFailed(reason: "JPEG read-back failed")
        }

        // Begin a new PDF page with the source's exact mediaBox.
        var rect = pageBounds
        let mediaData = NSData(bytes: &rect, length: MemoryLayout<CGRect>.size)
        let pageInfo: [String: Any] = [
            kCGPDFContextMediaBox as String: mediaData
        ]
        ctx.beginPDFPage(pageInfo as CFDictionary)
        ctx.draw(embeddable, in: pageBounds)

        // Apply each edit: cover rectangle(s), then draw replacement text.
        for edit in edits {
            // Cover rectangles (one per line).
            ctx.saveGState()
            ctx.setFillColor(edit.backgroundColor.cgColor)
            for lineRect in edit.lineRects {
                ctx.fill(lineRect)
            }
            ctx.restoreGState()

            // Draw replacement text spanning the union rect.
            let union = edit.lineRects.reduce(CGRect.null) { $0.union($1) }
            guard !union.isNull, !edit.replacement.isEmpty else { continue }

            let attrs: [NSAttributedString.Key: Any] = [
                .font: edit.font,
                .foregroundColor: edit.color
            ]
            let attr = NSAttributedString(string: edit.replacement, attributes: attrs)
            let frameSetter = CTFramesetterCreateWithAttributedString(attr)
            let path = CGPath(rect: union, transform: nil)
            let frame = CTFramesetterCreateFrame(
                frameSetter,
                CFRange(location: 0, length: 0),
                path,
                nil
            )
            ctx.saveGState()
            ctx.setTextDrawingMode(.fill)
            CTFrameDraw(frame, ctx)
            ctx.restoreGState()
        }

        ctx.endPDFPage()
    }

    private static func resolveDestination(for source: URL) throws -> URL {
        let stem = source.deletingPathExtension().lastPathComponent + " (edited)"
        let preferred = source
            .deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension("pdf")
        let candidate = UniqueDestination.url(preferred: preferred)

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
            ).appendingPathComponent("Dropshit/Edits", isDirectory: true)
            try FileManager.default.createDirectory(
                at: cache, withIntermediateDirectories: true
            )
            let p = cache.appendingPathComponent(stem).appendingPathExtension("pdf")
            return UniqueDestination.url(preferred: p)
        }
    }
}
