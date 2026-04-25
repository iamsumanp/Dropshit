import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ImageActionFormat: String, CaseIterable {
    case png = "PNG"
    case jpeg = "JPEG"
    case heic = "HEIC"
    case tiff = "TIFF"

    var utType: CFString {
        switch self {
        case .png: return UTType.png.identifier as CFString
        case .jpeg: return UTType.jpeg.identifier as CFString
        case .heic: return UTType.heic.identifier as CFString
        case .tiff: return UTType.tiff.identifier as CFString
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .tiff: return "tiff"
        }
    }
}

enum ImageActions {
    @discardableResult
    static func resize(url: URL, maxDimension: CGFloat) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let type = CGImageSourceGetType(source) ?? (UTType.png.identifier as CFString)
        let dest = uniqueURL(basedOn: url, suffix: " (resized)")
        return write(image: image, to: dest, type: type, properties: nil)
    }

    @discardableResult
    static func convert(url: URL, to format: ImageActionFormat) -> URL? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let stem = url.deletingPathExtension().lastPathComponent
        let candidate = url.deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension(format.fileExtension)
        let dest = uniqueURL(at: candidate)
        return write(image: image, to: dest, type: format.utType, properties: nil)
    }

    @discardableResult
    static func compress(url: URL, quality: Double) -> URL? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let stem = url.deletingPathExtension().lastPathComponent + " (compressed)"
        let candidate = url.deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension("jpg")
        let dest = uniqueURL(at: candidate)
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        return write(image: image, to: dest,
                     type: UTType.jpeg.identifier as CFString,
                     properties: props)
    }

    @discardableResult
    static func removeMetadata(url: URL) -> URL? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let type = CGImageSourceGetType(source) ?? (UTType.png.identifier as CFString)
        let dest = uniqueURL(basedOn: url, suffix: " (no metadata)")
        // Passing nil properties writes the pixels without carrying EXIF/GPS/IPTC.
        return write(image: image, to: dest, type: type, properties: nil)
    }

    @discardableResult
    static func createPDF(from urls: [URL]) -> URL? {
        let pdf = PDFDocument()
        for url in urls {
            guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else {
                continue
            }
            pdf.insert(page, at: pdf.pageCount)
        }
        guard pdf.pageCount > 0, let first = urls.first else { return nil }
        let stem = first.deletingPathExtension().lastPathComponent
        let candidate = first.deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension("pdf")
        let dest = uniqueURL(at: candidate)
        guard pdf.write(to: dest) else { return nil }
        return dest
    }

    // MARK: - Helpers

    private static func write(
        image: CGImage,
        to url: URL,
        type: CFString,
        properties: [CFString: Any]?
    ) -> URL? {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
    }

    static func uniqueURL(basedOn url: URL, suffix: String) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent + suffix
        var candidate = url.deletingLastPathComponent().appendingPathComponent(stem)
        if !ext.isEmpty { candidate.appendPathExtension(ext) }
        return uniqueURL(at: candidate)
    }

    static func uniqueURL(at url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var i = 2
        while true {
            var candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(stem) \(i)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            i += 1
        }
    }
}

// MARK: - Prompts

@MainActor
enum ImageActionPrompts {
    static func resizeMaxDimension(defaultValue: Int = 1024) -> CGFloat? {
        let alert = NSAlert()
        alert.messageText = "Resize Image"
        alert.informativeText = "Max dimension in pixels. Aspect ratio is preserved."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = String(defaultValue)
        alert.accessoryView = field
        alert.addButton(withTitle: "Resize")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let value = Double(field.stringValue), value > 0 else { return nil }
        return CGFloat(value)
    }

    static func format() -> ImageActionFormat? {
        let alert = NSAlert()
        alert.messageText = "Convert Format"
        alert.informativeText = "Choose an output format."
        let popup = NSPopUpButton(
            frame: NSRect(x: 0, y: 0, width: 220, height: 26),
            pullsDown: false
        )
        for format in ImageActionFormat.allCases {
            popup.addItem(withTitle: format.rawValue)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return ImageActionFormat.allCases[popup.indexOfSelectedItem]
    }

    static func compressionQuality(defaultValue: Double = 0.75) -> Double? {
        let alert = NSAlert()
        alert.messageText = "Compress Image"
        alert.informativeText = "JPEG quality (10% – 100%). Lower = smaller file."
        let slider = NSSlider(
            value: defaultValue,
            minValue: 0.1,
            maxValue: 1.0,
            target: nil,
            action: nil
        )
        slider.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = slider
        alert.addButton(withTitle: "Compress")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return slider.doubleValue
    }
}
