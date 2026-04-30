import AppKit
import CryptoKit
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
    let isDirectory: Bool
    /// Recursive total of bytes owned by a directory item. Populated lazily
    /// in the background by `ShelfManager.recomputeFolderSize` because
    /// `URLResourceKey.fileSizeKey` on a directory returns ~0 instead of the
    /// content total. nil for files (which use `byteSize` directly) and for
    /// directories whose computation hasn't finished yet.
    let cachedFolderBytes: Int64?

    init(
        id: UUID = UUID(),
        type: ItemType,
        fileURL: URL? = nil,
        textContent: String? = nil,
        thumbnail: NSImage? = nil,
        thumbnailIsIcon: Bool = true,
        createdAt: Date = Date(),
        pixelSize: CGSize? = nil,
        pageCount: Int? = nil,
        isDirectory: Bool = false,
        cachedFolderBytes: Int64? = nil
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
        self.isDirectory = isDirectory
        self.cachedFolderBytes = cachedFolderBytes
    }

    var displayName: String {
        // Text snippets prefer the snippet preview as the visible label, even
        // when they're backed by a temp file (so Open / Reveal-in-Finder can
        // route through the standard file path). Falling back to the temp
        // filename would surface gibberish like "Snippet-1a2b3c4d.txt".
        if type == .text, let text = textContent {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Untitled Text" : String(trimmed.prefix(40))
        }
        if let url = fileURL { return url.lastPathComponent }
        if let text = textContent {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Untitled Text" : String(trimmed.prefix(40))
        }
        return "Untitled"
    }

    /// Writes a pasted/dropped text snippet to a deterministic `.txt` file in
    /// the system temp dir so the snippet has a real backing fileURL. That URL
    /// is what makes "Open" (TextEdit) and "Reveal in Finder" work for text
    /// items — both go through `NSWorkspace` APIs that need a file path. The
    /// content hash makes the path stable across re-pastes of the same text.
    static func writeTextToTemp(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? ""
        let stem = String(firstLine.prefix(40))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let safeStem = stem.isEmpty ? "Snippet" : stem
        let hash = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined().prefix(8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeStem)-\(hash).txt")
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            return url
        } catch {
            NSLog("Shelf: failed to write text snippet to temp: \(error)")
            return nil
        }
    }

    var byteSize: Int64? {
        if isDirectory { return cachedFolderBytes }
        guard let url = fileURL,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    var displayMeta: String {
        if isDirectory {
            if let bytes = cachedFolderBytes {
                return Self.format(bytes: bytes)
            }
            return "Folder"
        }
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
