import AppKit

/// Target object for NSMenuItem actions. Must be retained for the menu's lifetime,
/// so we keep a strong reference on the ShelfMenu container.
@MainActor
final class ShelfItemActions: NSObject {
    let item: ShelfItem
    let shelfID: UUID
    weak var manager: ShelfManager?

    init(item: ShelfItem, shelfID: UUID, manager: ShelfManager?) {
        self.item = item
        self.shelfID = shelfID
        self.manager = manager
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
            manager?.removeItem(id: item.id, from: shelfID)
            return
        }
        let itemID = item.id
        let shelfRef = shelfID
        NSWorkspace.shared.recycle([url]) { [weak self] _, _ in
            Task { @MainActor in
                self?.manager?.removeItem(id: itemID, from: shelfRef)
            }
        }
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
            var name = stem + " \(i)"
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

    @objc func convertFormat() {
        guard let url = item.fileURL else { return }
        guard let format = ImageActionPrompts.format() else { return }
        runImageAction { ImageActions.convert(url: url, to: format) }
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
        alert.messageText = "Action Failed"
        alert.informativeText = "The image could not be processed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

final class ShelfMenu: NSMenu {
    var actions: ShelfItemActions?
}

enum ShelfContextMenu {
    @MainActor
    static func make(for item: ShelfItem, shelfID: UUID, manager: ShelfManager?) -> NSMenu {
        let menu = ShelfMenu()
        let actions = ShelfItemActions(item: item, shelfID: shelfID, manager: manager)
        menu.actions = actions
        let hasFile = item.fileURL != nil

        // Open With
        let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWithItem.submenu = makeOpenWithMenu(for: item, actions: actions)
        openWithItem.isEnabled = hasFile
        menu.addItem(openWithItem)

        // Show in Finder
        let show = NSMenuItem(
            title: "Show in Finder",
            action: #selector(ShelfItemActions.showInFinder),
            keyEquivalent: ""
        )
        show.target = actions
        show.isEnabled = hasFile
        menu.addItem(show)

        // Quick Look
        let ql = NSMenuItem(
            title: "Quick Look",
            action: #selector(ShelfItemActions.quickLook),
            keyEquivalent: " "
        )
        ql.keyEquivalentModifierMask = []
        ql.target = actions
        ql.isEnabled = hasFile
        menu.addItem(ql)

        // Copy
        let copy = NSMenuItem(
            title: "Copy",
            action: #selector(ShelfItemActions.copyToPasteboard),
            keyEquivalent: "c"
        )
        copy.target = actions
        menu.addItem(copy)

        // Share
        let share = NSMenuItem(
            title: "Share…",
            action: #selector(ShelfItemActions.share),
            keyEquivalent: ""
        )
        share.target = actions
        menu.addItem(share)

        menu.addItem(.separator())

        // Move to Trash
        let trash = NSMenuItem(
            title: "Move to Trash",
            action: #selector(ShelfItemActions.moveToTrash),
            keyEquivalent: ""
        )
        trash.target = actions
        menu.addItem(trash)

        menu.addItem(.separator())

        // All Actions submenu
        let allActions = NSMenuItem(title: "All Actions", action: nil, keyEquivalent: "")
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
            let none = NSMenuItem(title: "No File", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return menu
        }

        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        let allApps = NSWorkspace.shared.urlsForApplications(toOpen: url)

        if let defaultApp {
            let title = appDisplayName(defaultApp) + " (default)"
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
            let none = NSMenuItem(title: "No Applications", action: nil, keyEquivalent: "")
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

        if isImage {
            menu.addItem(sectionHeader("Image Actions"))

            addItem(to: menu, title: "Resize…",
                    selector: #selector(ShelfItemActions.resizeImage),
                    symbol: "arrow.down.right.and.arrow.up.left",
                    target: actions)
            addItem(to: menu, title: "Convert Format…",
                    selector: #selector(ShelfItemActions.convertFormat),
                    symbol: "arrow.triangle.2.circlepath",
                    target: actions)
            addItem(to: menu, title: "Compress…",
                    selector: #selector(ShelfItemActions.compressImage),
                    symbol: "arrow.down.to.line.compact",
                    target: actions)
            addItem(to: menu, title: "Remove Metadata",
                    selector: #selector(ShelfItemActions.removeMetadata),
                    symbol: "tag.slash",
                    target: actions)
            addItem(to: menu, title: "Create PDF",
                    selector: #selector(ShelfItemActions.createPDF),
                    symbol: "doc.badge.plus",
                    target: actions)

            menu.addItem(.separator())
            menu.addItem(sectionHeader("General Actions"))
        }

        let open = NSMenuItem(
            title: "Open",
            action: #selector(ShelfItemActions.open),
            keyEquivalent: ""
        )
        open.target = actions
        open.isEnabled = hasFile
        menu.addItem(open)

        let duplicate = NSMenuItem(
            title: "Duplicate",
            action: #selector(ShelfItemActions.duplicateFile),
            keyEquivalent: ""
        )
        duplicate.target = actions
        duplicate.isEnabled = hasFile
        menu.addItem(duplicate)

        menu.addItem(.separator())

        let remove = NSMenuItem(
            title: "Remove from Shelf",
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
