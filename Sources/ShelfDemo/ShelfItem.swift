import AppKit
import Foundation

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

    init(
        id: UUID = UUID(),
        type: ItemType,
        fileURL: URL? = nil,
        textContent: String? = nil,
        thumbnail: NSImage? = nil,
        thumbnailIsIcon: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.fileURL = fileURL
        self.textContent = textContent
        self.thumbnail = thumbnail
        self.thumbnailIsIcon = thumbnailIsIcon
        self.createdAt = createdAt
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
        case .file, .image:
            let ext = fileURL?.pathExtension.uppercased() ?? ""
            let size = byteSize.map { Self.format(bytes: $0) }
            return [ext, size].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        case .text:
            let chars = textContent?.count ?? 0
            return "Text · \(chars) chars"
        }
    }

    static func format(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}
