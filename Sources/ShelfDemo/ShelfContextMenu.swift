import AppKit
import UniformTypeIdentifiers

/// Target object for NSMenuItem actions. Must be retained for the menu's lifetime,
/// so we keep a strong reference on the ShelfMenu container.
@MainActor
final class ShelfItemActions: NSObject {
    let item: ShelfItem
    let selectedItems: [ShelfItem]   // includes `item` when present in selection;
                                     // [item] for non-selection right-clicks
    let shelfID: UUID
    weak var manager: ShelfManager?
    weak var conversionService: ConversionService?
    weak var ocrService: OCRService?

    init(
        item: ShelfItem,
        selectedItems: [ShelfItem],
        shelfID: UUID,
        manager: ShelfManager?,
        conversionService: ConversionService?,
        ocrService: OCRService?
    ) {
        self.item = item
        self.selectedItems = selectedItems
        self.shelfID = shelfID
        self.manager = manager
        self.conversionService = conversionService
        self.ocrService = ocrService
    }

    @objc func openWith(_ sender: NSMenuItem) {
        guard
            let appURL = sender.representedObject as? URL,
            let fileURL = item.fileURL
        else { return }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: config)
    }

    @objc func open() {
        guard let fileURL = item.fileURL else { return }
        NSWorkspace.shared.open(fileURL)
    }

    @objc func showInFinder() {
        guard let url = item.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func quickLook() {
        guard let manager else { return }
        let urls = manager.items(of: shelfID).compactMap { $0.fileURL }
        let start = (item.fileURL.flatMap { urls.firstIndex(of: $0) }) ?? 0
        QuickLookController.shared.show(startingAt: start)
    }

    @objc func copyToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let url = item.fileURL {
            pb.writeObjects([url as NSURL])
        } else if let text = item.textContent {
            pb.writeObjects([text as NSString])
        }
    }

    @objc func share() {
        ShareCoordinator.shared.share(item: item)
    }

    @objc func moveToTrash() {
        guard let url = item.fileURL else {
            // Text snippet (or any item missing a file) — just drop the row;
            // record an undo snapshot so Cmd-Z can restore it without needing
            // to round-trip through the Trash.
            manager?.captureTrashUndo(items: [item], trashedURLs: [:], in: shelfID)
            manager?.removeItem(id: item.id, from: shelfID)
            return
        }
        let itemID = item.id
        let shelfRef = shelfID
        let snapshotItem = item
        NSWorkspace.shared.recycle([url]) { [weak self] trashed, _ in
            Task { @MainActor in
                self?.manager?.captureTrashUndo(
                    items: [snapshotItem],
                    trashedURLs: trashed,
                    in: shelfRef
                )
                self?.manager?.removeItem(id: itemID, from: shelfRef)
            }
        }
    }

    @objc func rename() {
        guard let url = item.fileURL,
              FileManager.default.fileExists(atPath: url.path),
              let manager else { return }
        let current = url.lastPathComponent
        guard let newName = Self.promptRename(current: current),
              newName != current else { return }
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try manager.renameItem(id: item.id, to: newURL, in: shelfID)
        } catch {
            Self.showRenameError(error)
        }
    }

    @MainActor
    private static func promptRename(current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = L("Rename")
        alert.informativeText = L("alert.rename.body")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("Rename"))
        alert.addButton(withTitle: L("Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        field.stringValue = current
        // Pre-select the basename (stem) so typing replaces only the name and
        // keeps the extension — matches Finder's rename behavior.
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: current.count)
        alert.accessoryView = field
        // Window must exist for makeFirstResponder; defer the focus request to
        // the next runloop tick.
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(field)
            if let editor = field.currentEditor() {
                let stem = (current as NSString).deletingPathExtension
                editor.selectedRange = NSRange(location: 0, length: stem.count)
            }
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @MainActor
    private static func showRenameError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("Couldn't rename")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }

    @objc func duplicateFile() {
        guard let url = item.fileURL else { return }
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent + " copy"
        var candidate = url.deletingLastPathComponent().appendingPathComponent(stem)
        if !ext.isEmpty { candidate.appendPathExtension(ext) }
        var final = candidate
        var i = 2
        while FileManager.default.fileExists(atPath: final.path) {
            let name = stem + " \(i)"
            var u = url.deletingLastPathComponent().appendingPathComponent(name)
            if !ext.isEmpty { u.appendPathExtension(ext) }
            final = u
            i += 1
        }
        try? FileManager.default.copyItem(at: url, to: final)
    }

    @objc func removeFromShelf() {
        manager?.removeItem(id: item.id, from: shelfID)
    }

    // MARK: - Image actions

    @objc func resizeImage() {
        guard let url = item.fileURL else { return }
        guard let max = ImageActionPrompts.resizeMaxDimension() else { return }
        runImageAction { ImageActions.resize(url: url, maxDimension: max) }
    }

    @objc func convertTo(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ConversionTarget else { return }
        guard let service = conversionService else { return }
        for it in selectedItems {
            guard let url = it.fileURL else { continue }
            // Skip items already converting — re-enqueue would just queue
            // a redundant task at the back of the line.
            guard service.progress[it.id] == nil else { continue }
            service.enqueue(
                sourceItemID: it.id,
                shelfID: shelfID,
                source: url,
                target: target
            )
        }
    }

    @objc func makeSearchable(_ sender: NSMenuItem) {
        guard let service = ocrService else { return }
        for it in selectedItems {
            guard let url = it.fileURL else { continue }
            // Skip items already running an OCR task — re-enqueue would just
            // queue a redundant task at the back of the line.
            guard service.progress[it.id] == nil else { continue }
            service.enqueueMakeSearchable(
                sourceItemID: it.id,
                shelfID: shelfID,
                source: url
            )
        }
    }

    @objc func extractText(_ sender: NSMenuItem) {
        guard let service = ocrService else { return }
        for it in selectedItems {
            guard let url = it.fileURL else { continue }
            guard service.progress[it.id] == nil else { continue }
            let isPDF = url.pathExtension.lowercased() == "pdf"
                || (try? url.resourceValues(forKeys: [.contentTypeKey]))?
                    .contentType?.conforms(to: .pdf) == true
            service.enqueueExtractText(
                sourceItemID: it.id,
                shelfID: shelfID,
                source: url,
                isPDF: isPDF
            )
        }
    }

    @objc func compressImage() {
        guard let url = item.fileURL else { return }
        guard let quality = ImageActionPrompts.compressionQuality() else { return }
        runImageAction { ImageActions.compress(url: url, quality: quality) }
    }

    @objc func removeMetadata() {
        guard let url = item.fileURL else { return }
        runImageAction { ImageActions.removeMetadata(url: url) }
    }

    @objc func createPDF() {
        guard let url = item.fileURL else { return }
        runImageAction { ImageActions.createPDF(from: [url]) }
    }

    private func runImageAction(_ work: @escaping () -> URL?) {
        let shelfRef = shelfID
        let managerRef = manager
        Task.detached {
            let result = work()
            await MainActor.run {
                if let result {
                    managerRef?.addFile(url: result, to: shelfRef)
                } else {
                    Self.showFailureAlert()
                }
            }
        }
    }

    @MainActor
    private static func showFailureAlert() {
        let alert = NSAlert()
        alert.messageText = L("Action Failed")
        alert.informativeText = L("alert.action-failed.body")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }
}

final class ShelfMenu: NSMenu {
    var actions: ShelfItemActions?
}

enum ShelfContextMenu {
    @MainActor
    static func make(
        for item: ShelfItem,
        selectedItems: [ShelfItem],
        shelfID: UUID,
        manager: ShelfManager?,
        conversionService: ConversionService?,
        ocrService: OCRService?
    ) -> NSMenu {
        let menu = ShelfMenu()
        let actions = ShelfItemActions(
            item: item,
            selectedItems: selectedItems,
            shelfID: shelfID,
            manager: manager,
            conversionService: conversionService,
            ocrService: ocrService
        )
        menu.actions = actions
        let hasFile = item.fileURL != nil

        // Open With
        let openWithItem = NSMenuItem(title: L("Open With"), action: nil, keyEquivalent: "")
        openWithItem.submenu = makeOpenWithMenu(for: item, actions: actions)
        openWithItem.isEnabled = hasFile
        menu.addItem(openWithItem)

        // Show in Finder
        let show = NSMenuItem(
            title: L("Show in Finder"),
            action: #selector(ShelfItemActions.showInFinder),
            keyEquivalent: ""
        )
        show.target = actions
        show.isEnabled = hasFile
        menu.addItem(show)

        // Quick Look
        let ql = NSMenuItem(
            title: L("Quick Look"),
            action: #selector(ShelfItemActions.quickLook),
            keyEquivalent: " "
        )
        ql.keyEquivalentModifierMask = []
        ql.target = actions
        ql.isEnabled = hasFile
        menu.addItem(ql)

        // Copy
        let copy = NSMenuItem(
            title: L("Copy"),
            action: #selector(ShelfItemActions.copyToPasteboard),
            keyEquivalent: "c"
        )
        copy.target = actions
        menu.addItem(copy)

        // Share
        let share = NSMenuItem(
            title: L("Share…"),
            action: #selector(ShelfItemActions.share),
            keyEquivalent: ""
        )
        share.target = actions
        menu.addItem(share)

        menu.addItem(.separator())

        // Rename — only for items with a real file path. Text snippets and
        // missing files don't get a rename row.
        let canRename = (item.fileURL != nil) && (item.type != .text)
        let rename = NSMenuItem(
            title: L("Rename…"),
            action: #selector(ShelfItemActions.rename),
            keyEquivalent: ""
        )
        rename.target = actions
        rename.isEnabled = canRename
        menu.addItem(rename)

        menu.addItem(.separator())

        // Move to Trash
        let trash = NSMenuItem(
            title: L("Move to Trash"),
            action: #selector(ShelfItemActions.moveToTrash),
            keyEquivalent: ""
        )
        trash.target = actions
        menu.addItem(trash)

        menu.addItem(.separator())

        // All Actions submenu
        let allActions = NSMenuItem(title: L("All Actions"), action: nil, keyEquivalent: "")
        allActions.submenu = makeAllActionsMenu(
            actions: actions,
            hasFile: hasFile,
            isImage: item.type == .image
        )
        menu.addItem(allActions)

        return menu
    }

    @MainActor
    private static func makeOpenWithMenu(for item: ShelfItem, actions: ShelfItemActions) -> NSMenu {
        let menu = NSMenu()
        guard let url = item.fileURL else {
            let none = NSMenuItem(title: L("No File"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return menu
        }

        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        let allApps = NSWorkspace.shared.urlsForApplications(toOpen: url)

        if let defaultApp {
            let title = appDisplayName(defaultApp) + L("openwith.default.suffix")
            let mi = NSMenuItem(
                title: title,
                action: #selector(ShelfItemActions.openWith(_:)),
                keyEquivalent: ""
            )
            mi.target = actions
            mi.representedObject = defaultApp
            mi.image = appIcon(defaultApp)
            menu.addItem(mi)
            menu.addItem(.separator())
        }

        let others = allApps.filter { $0 != defaultApp }
            .sorted { appDisplayName($0).localizedCaseInsensitiveCompare(appDisplayName($1)) == .orderedAscending }

        if others.isEmpty && defaultApp == nil {
            let none = NSMenuItem(title: L("No Applications"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for appURL in others {
                let mi = NSMenuItem(
                    title: appDisplayName(appURL),
                    action: #selector(ShelfItemActions.openWith(_:)),
                    keyEquivalent: ""
                )
                mi.target = actions
                mi.representedObject = appURL
                mi.image = appIcon(appURL)
                menu.addItem(mi)
            }
        }

        return menu
    }

    @MainActor
    private static func makeAllActionsMenu(
        actions: ShelfItemActions,
        hasFile: Bool,
        isImage: Bool
    ) -> NSMenu {
        let menu = NSMenu()

        if let submenu = ConversionMenu.makeSubmenu(
            items: actions.selectedItems,
            target: actions,
            action: #selector(ShelfItemActions.convertTo(_:))
        ) {
            let title = actions.selectedItems.count > 1
                ? String(format: L("Convert %lld Items to"), actions.selectedItems.count)
                : L("Convert to")
            let entry = NSMenuItem(
                title: title,
                action: nil,
                keyEquivalent: ""
            )
            entry.image = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath",
                accessibilityDescription: nil
            )
            entry.submenu = submenu
            menu.addItem(entry)
        }

        let appendedOCR = OCRMenu.appendItems(
            to: menu,
            items: actions.selectedItems,
            target: actions,
            makeSearchableSelector: #selector(ShelfItemActions.makeSearchable(_:)),
            extractTextSelector: #selector(ShelfItemActions.extractText(_:))
        )
        if appendedOCR > 0 {
            // No separator — sits in the same logical group as Convert to ▶.
        }

        if isImage {
            menu.addItem(sectionHeader(L("Image Actions")))

            addItem(to: menu, title: L("Resize…"),
                    selector: #selector(ShelfItemActions.resizeImage),
                    symbol: "arrow.down.right.and.arrow.up.left",
                    target: actions)
            addItem(to: menu, title: L("Compress…"),
                    selector: #selector(ShelfItemActions.compressImage),
                    symbol: "arrow.down.to.line.compact",
                    target: actions)
            addItem(to: menu, title: L("Remove Metadata"),
                    selector: #selector(ShelfItemActions.removeMetadata),
                    symbol: "tag.slash",
                    target: actions)
            addItem(to: menu, title: L("Create PDF"),
                    selector: #selector(ShelfItemActions.createPDF),
                    symbol: "doc.badge.plus",
                    target: actions)

            menu.addItem(.separator())
            menu.addItem(sectionHeader(L("General Actions")))
        }

        let open = NSMenuItem(
            title: L("Open"),
            action: #selector(ShelfItemActions.open),
            keyEquivalent: ""
        )
        open.target = actions
        open.isEnabled = hasFile
        menu.addItem(open)

        let duplicate = NSMenuItem(
            title: L("Duplicate"),
            action: #selector(ShelfItemActions.duplicateFile),
            keyEquivalent: ""
        )
        duplicate.target = actions
        duplicate.isEnabled = hasFile
        menu.addItem(duplicate)

        menu.addItem(.separator())

        let remove = NSMenuItem(
            title: L("Remove from Shelf"),
            action: #selector(ShelfItemActions.removeFromShelf),
            keyEquivalent: ""
        )
        remove.target = actions
        menu.addItem(remove)

        return menu
    }

    private static func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        return item
    }

    @MainActor
    private static func addItem(
        to menu: NSMenu,
        title: String,
        selector: Selector,
        symbol: String,
        target: AnyObject
    ) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = target
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            image.isTemplate = true
            item.image = image
        }
        menu.addItem(item)
    }

    private static func appDisplayName(_ url: URL) -> String {
        if let bundle = Bundle(url: url),
           let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                        ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                        ?? (bundle.infoDictionary?["CFBundleName"] as? String) {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func appIcon(_ url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}
