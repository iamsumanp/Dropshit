import AppKit
import Combine
import Foundation
import QuickLookThumbnailing

@MainActor
final class ShelfManager: ObservableObject {
    @Published private(set) var shelves: [Shelf]
    @Published var isDragging: Bool = false

    private final class CachedThumbnail: NSObject {
        let image: NSImage
        let isIcon: Bool
        init(image: NSImage, isIcon: Bool) {
            self.image = image
            self.isIcon = isIcon
        }
    }

    private static let thumbnailCache: NSCache<NSString, CachedThumbnail> = {
        let cache = NSCache<NSString, CachedThumbnail>()
        cache.countLimit = 256
        return cache
    }()

    private let store = ShelfStore()
    private var cancellables = Set<AnyCancellable>()

    init() {
        let loaded = store.load()
        self.shelves = loaded.shelves.isEmpty ? [Shelf()] : loaded.shelves

        for shelf in shelves {
            for item in shelf.items {
                if let url = item.fileURL {
                    generateThumbnail(for: url, replacing: item.id)
                }
            }
        }

        $shelves
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] shelves in
                self?.store.save(shelves: shelves, currentShelfID: shelves.last?.id)
            }
            .store(in: &cancellables)
    }

    // MARK: - Queries

    func shelf(id: UUID) -> Shelf? {
        shelves.first { $0.id == id }
    }

    func items(of shelfID: UUID) -> [ShelfItem] {
        shelf(id: shelfID)?.items ?? []
    }

    func totalBytes(of shelfID: UUID) -> Int64 {
        items(of: shelfID).reduce(0) { $0 + ($1.byteSize ?? 0) }
    }

    func displayTotalSize(of shelfID: UUID) -> String {
        let total = totalBytes(of: shelfID)
        guard total > 0 else { return "—" }
        return ShelfItem.format(bytes: total)
    }

    // MARK: - Shelves

    @discardableResult
    func createShelf() -> UUID {
        let shelf = Shelf()
        shelves.append(shelf)
        return shelf.id
    }

    func removeShelf(id: UUID) {
        shelves.removeAll { $0.id == id }
    }

    private func index(of shelfID: UUID) -> Int? {
        shelves.firstIndex { $0.id == shelfID }
    }

    // MARK: - Items

    func addItem(_ item: ShelfItem, to shelfID: UUID) {
        guard let idx = index(of: shelfID) else { return }
        shelves[idx].items.append(item)
    }

    func removeItem(id itemID: UUID, from shelfID: UUID) {
        guard let idx = index(of: shelfID) else { return }
        shelves[idx].items.removeAll { $0.id == itemID }
    }

    func clear(shelfID: UUID) {
        guard let idx = index(of: shelfID) else { return }
        shelves[idx].items.removeAll()
    }

    @discardableResult
    func addFile(url: URL, to shelfID: UUID) -> ShelfItem? {
        guard index(of: shelfID) != nil else { return nil }
        let ext = url.pathExtension.lowercased()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "bmp", "webp"]
        let type: ShelfItem.ItemType = imageExts.contains(ext) ? .image : .file
        let placeholder = NSWorkspace.shared.icon(forFile: url.path)
        let item = ShelfItem(type: type, fileURL: url, thumbnail: placeholder)
        addItem(item, to: shelfID)
        generateThumbnail(for: url, replacing: item.id)
        return item
    }

    @discardableResult
    func addText(_ text: String, to shelfID: UUID) -> ShelfItem? {
        guard index(of: shelfID) != nil else { return nil }
        let item = ShelfItem(type: .text, textContent: text)
        addItem(item, to: shelfID)
        return item
    }

    @discardableResult
    func addFromClipboard(to shelfID: UUID) -> Int {
        let pb = NSPasteboard.general
        var added = 0

        let fileURLs = (pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        if !fileURLs.isEmpty {
            for url in fileURLs {
                addFile(url: url, to: shelfID)
                added += 1
            }
            return added
        }

        let images = (pb.readObjects(forClasses: [NSImage.self]) as? [NSImage]) ?? []
        if !images.isEmpty {
            for image in images {
                guard
                    let tiff = image.tiffRepresentation,
                    let bitmap = NSBitmapImageRep(data: tiff),
                    let png = bitmap.representation(using: .png, properties: [:])
                else { continue }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Shelf-\(UUID().uuidString).png")
                do {
                    try png.write(to: url)
                    addFile(url: url, to: shelfID)
                    added += 1
                } catch {
                    NSLog("Shelf: failed to save clipboard image: \(error)")
                }
            }
            if added > 0 { return added }
        }

        if let text = pb.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addText(text, to: shelfID)
            added += 1
        }

        return added
    }

    // MARK: - Thumbnails

    private func updateThumbnail(id: UUID, image: NSImage, isIcon: Bool) {
        for (sIdx, shelf) in shelves.enumerated() {
            if let iIdx = shelf.items.firstIndex(where: { $0.id == id }) {
                let old = shelves[sIdx].items[iIdx]
                shelves[sIdx].items[iIdx] = ShelfItem(
                    id: old.id,
                    type: old.type,
                    fileURL: old.fileURL,
                    textContent: old.textContent,
                    thumbnail: image,
                    thumbnailIsIcon: isIcon,
                    createdAt: old.createdAt
                )
                return
            }
        }
    }

    private func generateThumbnail(for url: URL, replacing id: UUID) {
        let key = Self.cacheKey(for: url)
        if let cached = Self.thumbnailCache.object(forKey: key) {
            updateThumbnail(id: id, image: cached.image, isIcon: cached.isIcon)
            return
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: 256, height: 320)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .all
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            let image = rep.nsImage
            let isIcon = (rep.type == .icon)
            Self.thumbnailCache.setObject(CachedThumbnail(image: image, isIcon: isIcon), forKey: key)
            Task { @MainActor [weak self] in
                self?.updateThumbnail(id: id, image: image, isIcon: isIcon)
            }
        }
    }

    private static func cacheKey(for url: URL) -> NSString {
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate?.timeIntervalSince1970) ?? 0
        return "\(url.path)#\(mod)" as NSString
    }
}
