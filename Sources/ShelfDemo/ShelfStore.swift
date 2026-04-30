import AppKit
import Foundation

private struct PersistedShelfItem: Codable {
    let id: UUID
    let type: String          // "file" | "image" | "text"
    let bookmark: Data?
    let text: String?
    let createdAt: Date
}

private struct PersistedShelf: Codable {
    let id: UUID
    let createdAt: Date
    let items: [PersistedShelfItem]
    // Added in v3 — optional so v2 payloads decode cleanly.
    let name: String?
    let pinned: Bool?
    let accent: ShelfAccent?
}

private struct PersistedStore: Codable {
    let version: Int
    let shelves: [PersistedShelf]
    let currentShelfID: UUID?
}

struct ShelfStoreContents {
    let shelves: [Shelf]
    let currentShelfID: UUID?
}

final class ShelfStore {
    private let storeURL: URL = {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("ShelfDemo", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("shelf.json")
    }()

    // MARK: - Save

    func save(shelves: [Shelf], currentShelfID: UUID?) {
        let records = shelves.map { shelf in
            PersistedShelf(
                id: shelf.id,
                createdAt: shelf.createdAt,
                items: shelf.items.map(persist),
                name: shelf.name,
                pinned: shelf.pinned ? true : nil,
                accent: shelf.accent
            )
        }
        let payload = PersistedStore(
            version: 3,
            shelves: records,
            currentShelfID: currentShelfID
        )
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            NSLog("Shelf: save failed — \(error)")
        }
    }

    private func persist(_ item: ShelfItem) -> PersistedShelfItem {
        let bookmark: Data? = {
            guard let url = item.fileURL else { return nil }
            return try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }()
        return PersistedShelfItem(
            id: item.id,
            type: typeKey(item.type),
            bookmark: bookmark,
            text: item.textContent,
            createdAt: item.createdAt
        )
    }

    // MARK: - Load

    func load() -> ShelfStoreContents {
        guard let data = try? Data(contentsOf: storeURL) else {
            return ShelfStoreContents(shelves: [], currentShelfID: nil)
        }
        guard let payload = try? JSONDecoder().decode(PersistedStore.self, from: data) else {
            return ShelfStoreContents(shelves: [], currentShelfID: nil)
        }

        var resolvedShelves: [Shelf] = []
        var anyStale = false
        let fm = FileManager.default

        for shelfRecord in payload.shelves {
            var items: [ShelfItem] = []
            for record in shelfRecord.items {
                if let bookmark = record.bookmark {
                    var stale = false
                    var isDir: ObjCBool = false
                    if let url = try? URL(
                        resolvingBookmarkData: bookmark,
                        options: [],
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale
                    ), fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                        let type: ShelfItem.ItemType = (record.type == "image") ? .image : .file
                        let icon = NSWorkspace.shared.icon(forFile: url.path)
                        let pixelSize = (type == .image)
                            ? ShelfItem.readImagePixelSize(url: url) : nil
                        let isPDF = url.pathExtension.lowercased() == "pdf"
                        let pageCount = isPDF ? ShelfItem.readPDFPageCount(url: url) : nil
                        items.append(ShelfItem(
                            id: record.id,
                            type: type,
                            fileURL: url,
                            textContent: nil,
                            thumbnail: icon,
                            createdAt: record.createdAt,
                            pixelSize: pixelSize,
                            pageCount: pageCount,
                            isDirectory: isDir.boolValue
                        ))
                        if stale { anyStale = true }
                    }
                } else if let text = record.text {
                    items.append(ShelfItem(
                        id: record.id,
                        type: .text,
                        fileURL: nil,
                        textContent: text,
                        thumbnail: nil,
                        createdAt: record.createdAt
                    ))
                }
            }
            resolvedShelves.append(Shelf(
                id: shelfRecord.id,
                items: items,
                createdAt: shelfRecord.createdAt,
                name: shelfRecord.name,
                pinned: shelfRecord.pinned ?? false,
                accent: shelfRecord.accent
            ))
        }

        let contents = ShelfStoreContents(
            shelves: resolvedShelves,
            currentShelfID: payload.currentShelfID
        )

        if anyStale {
            save(shelves: resolvedShelves, currentShelfID: contents.currentShelfID)
        }

        return contents
    }

    private func typeKey(_ type: ShelfItem.ItemType) -> String {
        switch type {
        case .file: return "file"
        case .image: return "image"
        case .text: return "text"
        }
    }
}
