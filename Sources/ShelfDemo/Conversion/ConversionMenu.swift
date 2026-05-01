import AppKit
import UniformTypeIdentifiers

/// Builds the "Convert to ▶" submenu given a shelf-item selection. The
/// submenu is `nil` when the selection has no valid conversion target.
@MainActor
enum ConversionMenu {
    /// Selector handler signature: target action object owns a method that
    /// reads `representedObject as? ConversionTarget` and dispatches into
    /// the service.
    static func makeSubmenu(
        items: [ShelfItem],
        target: AnyObject,
        action: Selector
    ) -> NSMenu? {
        let urls = items.compactMap(\.fileURL)
        guard !urls.isEmpty, urls.count == items.count else { return nil }

        let utis = urls.compactMap(uti(for:))
        guard utis.count == urls.count else { return nil }

        // Image case: at least one image UTI in the selection. Take the
        // intersection of supported targets across selection.
        let imageTargets: [ConversionTarget]
        if utis.allSatisfy({ !ConversionTarget.supportedImageTargets(for: $0).isEmpty }) {
            imageTargets = ConversionTarget.commonImageTargets(forSourceUTIs: utis)
        } else {
            imageTargets = []
        }

        // Video case: every selected file is a readable video container.
        let isAllVideo = utis.allSatisfy(ConversionTarget.isVideoSourceUTI)
        let allReadable = isAllVideo && urls.allSatisfy { url in
            AVAssetReadabilityCache.isReadable(url)
        }

        var options: [ConversionTarget] = imageTargets
        if isAllVideo, allReadable { options.append(.mp4) }

        guard !options.isEmpty else { return nil }

        let menu = NSMenu()
        for option in options {
            let item = NSMenuItem(
                title: option.displayName,
                action: action,
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = option
            menu.addItem(item)
        }
        return menu
    }

    private static func uti(for url: URL) -> UTType? {
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let t = values.contentType { return t }
        return UTType(filenameExtension: url.pathExtension)
    }
}

// AVURLAsset.isReadable is expensive (opens the file). Cache one lookup per
// URL string for the lifetime of the menu — context menus rebuild on every
// open so this cache is effectively per-open.
import AVFoundation

@MainActor
private enum AVAssetReadabilityCache {
    private static var cache: [String: Bool] = [:]
    static func isReadable(_ url: URL) -> Bool {
        let key = url.path
        if let cached = cache[key] { return cached }
        let result = AVURLAsset(url: url).isReadable
        cache[key] = result
        return result
    }
}
