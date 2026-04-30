import AppKit
import Combine
import Foundation
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ShelfManager: ObservableObject {
    @Published private(set) var shelves: [Shelf]
    @Published var isDragging: Bool = false
    /// True while *any* visible shelf panel is currently being targeted by
    /// an in-flight drop. Used by the status item to swap its icon glyph.
    @Published private(set) var isAnyShelfDropTarget: Bool = false

    private var dropTargetedShelves: Set<UUID> = []

    func setDropTargeted(shelfID: UUID, _ targeted: Bool) {
        if targeted {
            dropTargetedShelves.insert(shelfID)
        } else {
            dropTargetedShelves.remove(shelfID)
        }
        let any = !dropTargetedShelves.isEmpty
        if isAnyShelfDropTarget != any { isAnyShelfDropTarget = any }
    }

    // Emits the shelfID that rejected a duplicate file/folder.
    let duplicateRejected = PassthroughSubject<UUID, Never>()
    // Emits the shelfID when a docked panel was dragged away from the edge
    // and should revert to collapsed state in-place.
    let undockRequested = PassthroughSubject<UUID, Never>()
    // Emits the key shelfID when Cmd-A is pressed in its panel; the
    // expanded view picks this up to select every shelf-root item.
    let selectAllRequested = PassthroughSubject<UUID, Never>()
    // Emits the key shelfID when Cmd-C is pressed in its panel; the
    // expanded view writes the current selection (root or folder) to
    // the pasteboard.
    let copyRequested = PassthroughSubject<UUID, Never>()
    // Emits a shelfID when the AppDelegate wants the corresponding panel
    // to collapse from its expanded state back to the pill view (e.g. on
    // an outside click when the close-on-outside-click setting is on).
    let collapseRequested = PassthroughSubject<UUID, Never>()

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
                    if item.isDirectory {
                        recomputeFolderSize(itemID: item.id, in: shelf.id)
                    } else {
                        generateThumbnail(for: url, replacing: item.id)
                    }
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

    func containsFile(url: URL, in shelfID: UUID) -> Bool {
        let key = url.resolvingSymlinksInPath().standardizedFileURL.path
        return items(of: shelfID).contains { item in
            guard let existing = item.fileURL else { return false }
            return existing.resolvingSymlinksInPath().standardizedFileURL.path == key
        }
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

    /// Sets a custom display name for a shelf. Pass nil/empty to clear.
    func renameShelf(id: UUID, to name: String?) {
        guard let i = index(of: id) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard shelves[i].name != newName else { return }
        shelves[i].name = newName
    }

    func setShelfPinned(id: UUID, _ pinned: Bool) {
        guard let i = index(of: id) else { return }
        guard shelves[i].pinned != pinned else { return }
        shelves[i].pinned = pinned
    }

    func setShelfAccent(id: UUID, _ accent: ShelfAccent?) {
        guard let i = index(of: id) else { return }
        guard shelves[i].accent != accent else { return }
        shelves[i].accent = accent
    }

    /// Removes shelves whose last activity (most recent item add, falling back
    /// to shelf createdAt) is older than `days`. For each removed shelf, files
    /// that the shelf owns (i.e. live under our temporary directory) are also
    /// deleted from disk; files originally from Finder or anywhere else are
    /// left untouched.
    /// Returns the IDs of the shelves that were pruned so callers can close
    /// any associated UI.
    @discardableResult
    func pruneShelves(olderThanDays days: Int) -> [UUID] {
        guard days > 0 else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let tempPath = FileManager.default.temporaryDirectory
            .standardizedFileURL.path

        let expired = shelves.filter { shelf in
            // Pinned shelves are exempt from auto-expiry regardless of age.
            guard !shelf.pinned else { return false }
            let last = shelf.items.map(\.createdAt).max() ?? shelf.createdAt
            return last < cutoff
        }
        guard !expired.isEmpty else { return [] }

        for shelf in expired {
            for item in shelf.items {
                guard let url = item.fileURL else { continue }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(tempPath) else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
        let ids = expired.map(\.id)
        shelves.removeAll { ids.contains($0.id) }
        return ids
    }

    private func index(of shelfID: UUID) -> Int? {
        shelves.firstIndex { $0.id == shelfID }
    }

    // MARK: - Items

    func addItem(_ item: ShelfItem, to shelfID: UUID) {
        guard let idx = index(of: shelfID) else { return }
        // Animate the insertion so dropped tiles slide/fade in instead of
        // popping (and so any layout reflow in the grid is smoothed too).
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            shelves[idx].items.append(item)
        }
    }

    func removeItem(id itemID: UUID, from shelfID: UUID) {
        guard let idx = index(of: shelfID) else { return }
        shelves[idx].items.removeAll { $0.id == itemID }
    }

    func clear(shelfID: UUID) {
        guard let idx = index(of: shelfID) else { return }
        shelves[idx].items.removeAll()
    }

    /// Drops items whose backing file is gone (e.g. moved to Trash from
    /// Finder while the shelf was open). Text items have no fileURL and are
    /// always kept. Returns the number of items removed.
    @discardableResult
    func pruneMissingFiles() -> Int {
        let fm = FileManager.default
        var removed = 0
        for sIdx in shelves.indices {
            let before = shelves[sIdx].items.count
            shelves[sIdx].items.removeAll { item in
                guard let url = item.fileURL else { return false }
                return !fm.fileExists(atPath: url.path)
            }
            removed += before - shelves[sIdx].items.count
        }
        return removed
    }

    enum RenameError: LocalizedError {
        case itemNotFound
        case missingURL
        case sourceMissing(URL)
        case destinationExists(URL)
        case moveFailed(URL, URL, Error)
        case moveDidNotTakeEffect(URL, URL)

        var errorDescription: String? {
            switch self {
            case .itemNotFound: return "Item not found."
            case .missingURL: return "Item has no file URL."
            case .sourceMissing(let url):
                return "Source no longer exists: \(url.path)"
            case .destinationExists(let url):
                return "A file already exists at \(url.lastPathComponent)."
            case .moveFailed(_, _, let err):
                return err.localizedDescription
            case .moveDidNotTakeEffect:
                return "Rename reported success but the file did not move."
            }
        }
    }

    func renameItem(id itemID: UUID, to newURL: URL, in shelfID: UUID) throws {
        guard let sIdx = index(of: shelfID),
              let iIdx = shelves[sIdx].items.firstIndex(where: { $0.id == itemID })
        else { throw RenameError.itemNotFound }
        guard let oldURL = shelves[sIdx].items[iIdx].fileURL
        else { throw RenameError.missingURL }
        guard FileManager.default.fileExists(atPath: oldURL.path)
        else { throw RenameError.sourceMissing(oldURL) }

        if oldURL.standardizedFileURL.path != newURL.standardizedFileURL.path {
            guard !FileManager.default.fileExists(atPath: newURL.path)
            else { throw RenameError.destinationExists(newURL) }
        }

        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
        } catch {
            throw RenameError.moveFailed(oldURL, newURL, error)
        }

        // Verify the rename actually took effect — covers weird cases
        // (aliases, sync engines, case-insensitive filesystems).
        guard FileManager.default.fileExists(atPath: newURL.path)
        else { throw RenameError.moveDidNotTakeEffect(oldURL, newURL) }

        let old = shelves[sIdx].items[iIdx]
        shelves[sIdx].items[iIdx] = ShelfItem(
            id: old.id,
            type: old.type,
            fileURL: newURL,
            textContent: old.textContent,
            thumbnail: old.thumbnail,
            thumbnailIsIcon: old.thumbnailIsIcon,
            createdAt: old.createdAt,
            pixelSize: old.pixelSize,
            pageCount: old.pageCount,
            isDirectory: old.isDirectory,
            cachedFolderBytes: old.cachedFolderBytes
        )
    }

    @discardableResult
    func addFile(url: URL, to shelfID: UUID) -> ShelfItem? {
        guard index(of: shelfID) != nil else { return nil }
        if containsFile(url: url, in: shelfID) {
            duplicateRejected.send(shelfID)
            return nil
        }
        // Use UTType conformance instead of a hardcoded extension list so RAW
        // formats (CR2, NEF, ARW, DNG, etc.) and newer codecs (AVIF, HEIF) all
        // get image-style flush rendering rather than the doc-card white frame.
        let values = (try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey]))
        let contentType = values?.contentType
        let isDirectory = values?.isDirectory ?? false
        let isImage = !isDirectory && (contentType?.conforms(to: .image) ?? false)
        let type: ShelfItem.ItemType = isImage ? .image : .file
        let placeholder = NSWorkspace.shared.icon(forFile: url.path)
        let pixelSize = isImage ? ShelfItem.readImagePixelSize(url: url) : nil
        let pageCount = (!isDirectory && (contentType?.conforms(to: .pdf) ?? false))
            ? ShelfItem.readPDFPageCount(url: url) : nil
        let item = ShelfItem(
            type: type,
            fileURL: url,
            thumbnail: placeholder,
            pixelSize: pixelSize,
            pageCount: pageCount,
            isDirectory: isDirectory
        )
        addItem(item, to: shelfID)
        if isDirectory {
            recomputeFolderSize(itemID: item.id, in: shelfID)
        } else {
            generateThumbnail(for: url, replacing: item.id)
        }
        return item
    }

    /// Walks the directory at the item's URL and writes the total content
    /// size back to the item. Runs on a detached task so a multi-GB folder
    /// can't block the UI.
    func recomputeFolderSize(itemID: UUID, in shelfID: UUID) {
        guard let sIdx = index(of: shelfID),
              let iIdx = shelves[sIdx].items.firstIndex(where: { $0.id == itemID }),
              shelves[sIdx].items[iIdx].isDirectory,
              let url = shelves[sIdx].items[iIdx].fileURL
        else { return }
        Task.detached(priority: .utility) {
            let bytes = Self.totalBytes(of: url)
            await MainActor.run { [weak self] in
                self?.applyFolderSize(itemID: itemID, in: shelfID, bytes: bytes)
            }
        }
    }

    private func applyFolderSize(itemID: UUID, in shelfID: UUID, bytes: Int64) {
        guard let sIdx = index(of: shelfID),
              let iIdx = shelves[sIdx].items.firstIndex(where: { $0.id == itemID })
        else { return }
        let old = shelves[sIdx].items[iIdx]
        guard old.cachedFolderBytes != bytes else { return }
        shelves[sIdx].items[iIdx] = ShelfItem(
            id: old.id,
            type: old.type,
            fileURL: old.fileURL,
            textContent: old.textContent,
            thumbnail: old.thumbnail,
            thumbnailIsIcon: old.thumbnailIsIcon,
            createdAt: old.createdAt,
            pixelSize: old.pixelSize,
            pageCount: old.pageCount,
            isDirectory: old.isDirectory,
            cachedFolderBytes: bytes
        )
    }

    private nonisolated static func totalBytes(of url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
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
                let new = ShelfItem(
                    id: old.id,
                    type: old.type,
                    fileURL: old.fileURL,
                    textContent: old.textContent,
                    thumbnail: image,
                    thumbnailIsIcon: isIcon,
                    createdAt: old.createdAt,
                    pixelSize: old.pixelSize,
                    pageCount: old.pageCount,
                    isDirectory: old.isDirectory,
                    cachedFolderBytes: old.cachedFolderBytes
                )
                // Crossfade the skeleton/icon → real preview swap so it
                // doesn't read as a hard pop.
                withAnimation(.easeInOut(duration: 0.18)) {
                    shelves[sIdx].items[iIdx] = new
                }
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
        // Only image files get the full QL preview pipeline; everything else
        // gets the file-type icon. QL's "thumbnail" rep for text/markdown/json
        // is a rendered page on a white background, which clashes with the
        // dark shelf and reads as a stray paper backdrop.
        let isImage = (try? url.resourceValues(forKeys: [.contentTypeKey])
            .contentType)?.conforms(to: .image) ?? false
        let reprTypes: QLThumbnailGenerator.Request.RepresentationTypes =
            isImage ? .all : .icon
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: reprTypes
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
