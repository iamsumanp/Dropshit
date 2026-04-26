import AppKit
import Foundation
import ImageIO
import Quartz

struct ShelfItem: Identifiable, Equatable {
    enum ItemType: Equatable {
        case file
        case image
        case text
    }

    let id: UUID
    let type: ItemType
    let fileURL: URL?
    let textContent: String?
    let thumbnail: NSImage?
    let thumbnailIsIcon: Bool
    let createdAt: Date
    let pixelSize: CGSize?
    let pageCount: Int?

    init(
        id: UUID = UUID(),
        type: ItemType,
        fileURL: URL? = nil,
        textContent: String? = nil,
        thumbnail: NSImage? = nil,
        thumbnailIsIcon: Bool = true,
        createdAt: Date = Date(),
        pixelSize: CGSize? = nil,
        pageCount: Int? = nil
    ) {
        self.id = id
        self.type = type
        self.fileURL = fileURL
        self.textContent = textContent
        self.thumbnail = thumbnail
        self.thumbnailIsIcon = thumbnailIsIcon
        self.createdAt = createdAt
        self.pixelSize = pixelSize
        self.pageCount = pageCount
    }

    var displayName: String {
        if let url = fileURL { return url.lastPathComponent }
        if let text = textContent {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Untitled Text" : String(trimmed.prefix(40))
        }
        return "Untitled"
    }

    var byteSize: Int64? {
        guard let url = fileURL,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    var displayMeta: String {
        switch type {
        case .image:
            let size = byteSize.map { Self.format(bytes: $0) }
            let dims = pixelSize.map { "\(Int($0.width))x\(Int($0.height))" }
            let parts = [size, dims].compactMap { $0?.isEmpty == false ? $0 : nil }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
            return fileURL?.pathExtension.uppercased() ?? ""
        case .file:
            let size = byteSize.map { Self.format(bytes: $0) }
            let pages = pageCount.map { "\($0) page\($0 == 1 ? "" : "s")" }
            let ext = fileURL?.pathExtension.uppercased()
            let detail = pages ?? ext
            let parts = [size, detail].compactMap { $0?.isEmpty == false ? $0 : nil }
            return parts.joined(separator: " · ")
        case .text:
            let chars = textContent?.count ?? 0
            return "Text · \(chars) chars"
        }
    }

    /// Reads pixel dimensions from an image file's metadata (no pixel decode).
    /// Works for RAW formats (CR2/NEF/ARW/DNG) too, via ImageIO.
    static func readImagePixelSize(url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0
        else { return nil }
        return CGSize(width: w, height: h)
    }

    static func readPDFPageCount(url: URL) -> Int? {
        guard let doc = CGPDFDocument(url as CFURL) else { return nil }
        let count = doc.numberOfPages
        return count > 0 ? count : nil
    }

    static func format(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}
