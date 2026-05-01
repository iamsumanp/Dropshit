import AppKit
import UniformTypeIdentifiers

/// Builds the OCR menu items for the All Actions submenu. Two pure
/// eligibility predicates power the inclusion logic and are unit-tested
/// directly.
@MainActor
enum OCRMenu {
    /// `Make Searchable` is offered only when every selected item is a PDF.
    static func shouldOfferMakeSearchable(forSourceUTIs utis: [UTType]) -> Bool {
        guard !utis.isEmpty else { return false }
        return utis.allSatisfy { $0.conforms(to: .pdf) }
    }

    /// `Extract Text` is offered when every selected item is either a PDF
    /// or one of the supported image types.
    static func shouldOfferExtractText(forSourceUTIs utis: [UTType]) -> Bool {
        guard !utis.isEmpty else { return false }
        return utis.allSatisfy(isExtractTextEligible)
    }

    private static func isExtractTextEligible(_ uti: UTType) -> Bool {
        if uti.conforms(to: .pdf) { return true }
        if uti.conforms(to: .heic) { return true }
        if uti.conforms(to: .png) { return true }
        if uti.conforms(to: .jpeg) { return true }
        if uti.conforms(to: .tiff) { return true }
        if uti.conforms(to: .webP) { return true }
        return false
    }

    /// Inserts up to two NSMenuItems (Make Searchable, Extract Text) into
    /// `menu` based on the selection. Returns the count appended.
    @discardableResult
    static func appendItems(
        to menu: NSMenu,
        items: [ShelfItem],
        target: AnyObject,
        makeSearchableSelector: Selector,
        extractTextSelector: Selector
    ) -> Int {
        let utis = items.compactMap(uti(for:))
        guard utis.count == items.count else { return 0 }

        var appended = 0

        if shouldOfferMakeSearchable(forSourceUTIs: utis) {
            let title = items.count > 1 ? "Make \(items.count) Searchable" : "Make Searchable"
            let item = NSMenuItem(
                title: title,
                action: makeSearchableSelector,
                keyEquivalent: ""
            )
            item.target = target
            item.image = NSImage(
                systemSymbolName: "doc.text.magnifyingglass",
                accessibilityDescription: nil
            )
            menu.addItem(item)
            appended += 1
        }

        if shouldOfferExtractText(forSourceUTIs: utis) {
            let title = items.count > 1 ? "Extract Text from \(items.count) Items" : "Extract Text"
            let item = NSMenuItem(
                title: title,
                action: extractTextSelector,
                keyEquivalent: ""
            )
            item.target = target
            item.image = NSImage(
                systemSymbolName: "text.viewfinder",
                accessibilityDescription: nil
            )
            menu.addItem(item)
            appended += 1
        }

        return appended
    }

    private static func uti(for item: ShelfItem) -> UTType? {
        guard let url = item.fileURL else { return nil }
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let t = values.contentType { return t }
        return UTType(filenameExtension: url.pathExtension)
    }
}
