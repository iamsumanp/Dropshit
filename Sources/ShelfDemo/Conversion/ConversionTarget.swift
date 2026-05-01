import Foundation
import UniformTypeIdentifiers

/// The format we're converting *to*. Sources are described by their UTI; the
/// per-source target list is encoded in `supportedImageTargets(for:)`.
enum ConversionTarget: String, CaseIterable, Equatable {
    case jpeg
    case png
    case mp4

    var displayName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png:  return "PNG"
        case .mp4:  return "MP4"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png:  return "png"
        case .mp4:  return "mp4"
        }
    }

    /// CFString UTI used by `CGImageDestinationCreateWithURL`. Not meaningful
    /// for `.mp4` (callers should not reach here for video).
    var imageDestinationUTI: CFString {
        switch self {
        case .jpeg: return UTType.jpeg.identifier as CFString
        case .png:  return UTType.png.identifier as CFString
        case .mp4:  preconditionFailure("mp4 is not an image target")
        }
    }

    // MARK: Source eligibility

    /// Image targets offered for a given source UTI. The matrix mirrors the
    /// design spec table; we keep it as a switch (not data) so the rules are
    /// audited at the type level.
    static func supportedImageTargets(for source: UTType) -> [ConversionTarget] {
        if source.conforms(to: .heic) { return [.jpeg, .png] }
        if source.conforms(to: .png)  { return [.jpeg] }
        if source.conforms(to: .jpeg) { return [.png] }
        if source.conforms(to: .tiff) { return [.jpeg, .png] }
        if source.conforms(to: .webP) { return [.jpeg, .png] }
        return []
    }

    /// Intersection of `supportedImageTargets(for:)` across a selection.
    /// Used by the menu builder to offer only targets valid for *every*
    /// selected item.
    static func commonImageTargets(forSourceUTIs utis: [UTType]) -> [ConversionTarget] {
        guard let first = utis.first else { return [] }
        let initial = Set(supportedImageTargets(for: first))
        let intersected = utis.dropFirst().reduce(initial) { acc, uti in
            acc.intersection(supportedImageTargets(for: uti))
        }
        // Preserve canonical order (jpeg before png) for stable menus.
        return ConversionTarget.allCases.filter { intersected.contains($0) }
    }

    /// True if the UTI is a video container we *might* be able to read
    /// (final eligibility is decided by `AVURLAsset.isReadable` at runtime,
    /// because MKV/AVI only work when the inner codec is supported).
    static func isVideoSourceUTI(_ uti: UTType) -> Bool {
        // movie covers QuickTime, MPEG-4, AVI, MKV-as-Matroska when registered.
        return uti.conforms(to: .movie) || uti.conforms(to: .video)
    }
}
