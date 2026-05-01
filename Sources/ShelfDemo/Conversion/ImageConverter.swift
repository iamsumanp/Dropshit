import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Synchronous ImageIO-backed converter. Designed to be called from a
/// background queue (the service handles dispatch).
enum ImageConverter {
    /// JPEG quality from the spec (0.9, sRGB).
    private static let jpegQuality: CGFloat = 0.9

    /// Convert `source` to `target`. Writes next to the source; falls back
    /// to `~/Library/Caches/Dropshit/Converted` if the source dir refuses
    /// writes. Atomic: writes to a sibling `<name>.partXXXX.<ext>` and
    /// renames into place on success.
    @discardableResult
    static func convert(
        source: URL,
        target: ConversionTarget,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard target != .mp4 else {
            preconditionFailure("ImageConverter cannot produce mp4")
        }
        guard fileManager.fileExists(atPath: source.path) else {
            throw ConversionError.sourceMissing
        }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw ConversionError.sourceUnreadable
        }

        let finalDestination = try resolveDestination(
            for: source, target: target, fileManager: fileManager
        )

        // Atomic write: encode to a temp sibling, then rename.
        let tempURL = finalDestination
            .deletingPathExtension()
            .appendingPathExtension("part\(UUID().uuidString.prefix(8))")
            .appendingPathExtension(target.fileExtension)

        let properties = makeProperties(for: target)

        guard let dest = CGImageDestinationCreateWithURL(
            tempURL as CFURL, target.imageDestinationUTI, 1, nil
        ) else {
            throw ConversionError.destinationUnwritable
        }
        CGImageDestinationAddImage(dest, cgImage, properties)
        guard CGImageDestinationFinalize(dest) else {
            try? fileManager.removeItem(at: tempURL)
            throw ConversionError.encodingFailed(reason: "image encoder failed")
        }

        do {
            try fileManager.moveItem(at: tempURL, to: finalDestination)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw ConversionError.destinationUnwritable
        }
        return finalDestination
    }

    // MARK: - Internals

    private static func makeProperties(for target: ConversionTarget) -> CFDictionary? {
        switch target {
        case .jpeg:
            let dict: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: jpegQuality
            ]
            return dict as CFDictionary
        case .png, .mp4:
            return nil
        }
    }

    private static func resolveDestination(
        for source: URL,
        target: ConversionTarget,
        fileManager: FileManager
    ) throws -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let preferred = source
            .deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension(target.fileExtension)
        let candidate = UniqueDestination.url(preferred: preferred, fileManager: fileManager)

        // Probe writability empirically: try to create an empty placeholder.
        // If that fails with a permission-class error, redirect to the
        // fallback cache dir.
        if canCreateFile(at: candidate, fileManager: fileManager) {
            return candidate
        }
        return try fallbackDestination(stem: stem, target: target, fileManager: fileManager)
    }

    private static func canCreateFile(at url: URL, fileManager: FileManager) -> Bool {
        let probe = url
            .deletingPathExtension()
            .appendingPathExtension("probe\(UUID().uuidString.prefix(6))")
        do {
            try Data().write(to: probe)
            try? fileManager.removeItem(at: probe)
            return true
        } catch let error as NSError {
            // EACCES (13), EPERM (1), EROFS (30) → not writable.
            let writeFailures: Set<Int> = [1, 13, 30]
            if writeFailures.contains(error.code) { return false }
            // Some other failure (e.g., parent dir doesn't exist) — also bail.
            return false
        }
    }

    private static func fallbackDestination(
        stem: String,
        target: ConversionTarget,
        fileManager: FileManager
    ) throws -> URL {
        let cache = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Dropshit/Converted", isDirectory: true)

        try fileManager.createDirectory(
            at: cache, withIntermediateDirectories: true
        )

        let preferred = cache
            .appendingPathComponent(stem)
            .appendingPathExtension(target.fileExtension)
        return UniqueDestination.url(preferred: preferred, fileManager: fileManager)
    }
}
