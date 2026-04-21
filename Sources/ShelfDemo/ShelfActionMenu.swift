import AppKit
import SwiftUI

struct ShelfActionMenu: View {
    @ObservedObject var manager: ShelfManager
    let shelfID: UUID

    var body: some View {
        CircularIconButton(systemName: "chevron.down", action: presentMenu)
    }

    private func presentMenu() {
        let menu = ShelfActionMenuBuilder.make(manager: manager, shelfID: shelfID)
        if let event = NSApp.currentEvent, let view = event.window?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

// MARK: - Actions target

@MainActor
private final class ShelfActionTargets: NSObject {
    let manager: ShelfManager
    let shelfID: UUID

    init(manager: ShelfManager, shelfID: UUID) {
        self.manager = manager
        self.shelfID = shelfID
    }

    private var items: [ShelfItem] { manager.items(of: shelfID) }
    private var urls: [URL] {
        items.compactMap { $0.fileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    @objc func openWith(_ sender: NSMenuItem) {
        guard
            let appURL = sender.representedObject as? URL,
            let fileURL = items.first?.fileURL
        else { return }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: config)
    }

    @objc func showInFinder() {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func quickLook() {
        guard !urls.isEmpty else { return }
        QuickLookController.shared.show(startingAt: urls.count - 1)
    }

    @objc func airDrop() {
        guard !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop) else { return }
        service.perform(withItems: urls)
    }

    @objc func messages() {
        guard !urls.isEmpty,
              let service = NSSharingService(named: .composeMessage) else { return }
        service.perform(withItems: urls)
    }

    @objc func copyLink() {
        let token = UUID().uuidString.prefix(10).lowercased()
        let link = "https://shelf.local/s/\(token)"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([link as NSString])
    }

    @objc func addFromClipboard() {
        _ = manager.addFromClipboard(to: shelfID)
    }

    @objc func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        var objects: [NSPasteboardWriting] = []
        for item in items {
            if let url = item.fileURL, FileManager.default.fileExists(atPath: url.path) {
                objects.append(url as NSURL)
            } else if let text = item.textContent {
                objects.append(text as NSString)
            }
        }
        if !objects.isEmpty { pb.writeObjects(objects) }
    }

    @objc func clear() {
        manager.clear(shelfID: shelfID)
    }
}

private final class ShelfActionNSMenu: NSMenu {
    var targets: ShelfActionTargets?
}

// MARK: - Menu builder

@MainActor
enum ShelfActionMenuBuilder {
    static func make(manager: ShelfManager, shelfID: UUID) -> NSMenu {
        let menu = ShelfActionNSMenu()
        let targets = ShelfActionTargets(manager: manager, shelfID: shelfID)
        menu.targets = targets

        let items = manager.items(of: shelfID)
        let urls = items.compactMap { $0.fileURL }
        let hasFiles = !urls.isEmpty

        // Open With — only for a single file
        if items.count == 1, let url = items[0].fileURL {
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWith.image = symbol("square.stack")
            openWith.submenu = makeOpenWithMenu(for: url, targets: targets)
            menu.addItem(openWith)
        }

        menu.addItem(makeItem(
            title: "Show in Finder",
            symbol: "folder",
            action: #selector(ShelfActionTargets.showInFinder),
            target: targets,
            enabled: hasFiles
        ))

        menu.addItem(makeItem(
            title: "Quick Look",
            symbol: "eye",
            action: #selector(ShelfActionTargets.quickLook),
            target: targets,
            enabled: hasFiles
        ))

        menu.addItem(.separator())

        menu.addItem(makeItem(
            title: "AirDrop",
            symbol: "wave.3.right",
            action: #selector(ShelfActionTargets.airDrop),
            target: targets,
            enabled: hasFiles
        ))

        menu.addItem(makeItem(
            title: "Messages",
            symbol: "message",
            action: #selector(ShelfActionTargets.messages),
            target: targets,
            enabled: hasFiles
        ))

        menu.addItem(.separator())

        menu.addItem(makeItem(
            title: "Copy Shareable Link",
            symbol: "link",
            action: #selector(ShelfActionTargets.copyLink),
            target: targets,
            enabled: hasFiles
        ))

        menu.addItem(.separator())

        menu.addItem(makeItem(
            title: "Add From Clipboard",
            symbol: "doc.on.clipboard",
            action: #selector(ShelfActionTargets.addFromClipboard),
            target: targets,
            enabled: true
        ))

        let copyTitle = items.count <= 1 ? "Copy" : "Copy \(items.count) Files"
        menu.addItem(makeItem(
            title: copyTitle,
            symbol: "doc.on.doc",
            action: #selector(ShelfActionTargets.copyAll),
            target: targets,
            enabled: !items.isEmpty
        ))

        menu.addItem(.separator())

        menu.addItem(makeItem(
            title: "Clear Shelf",
            symbol: "xmark.bin",
            action: #selector(ShelfActionTargets.clear),
            target: targets,
            enabled: !items.isEmpty
        ))

        return menu
    }

    private static func makeOpenWithMenu(for url: URL, targets: ShelfActionTargets) -> NSMenu {
        let menu = NSMenu()
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        let allApps = NSWorkspace.shared.urlsForApplications(toOpen: url)

        if let app = defaultApp {
            let mi = NSMenuItem(
                title: appDisplayName(app) + " (default)",
                action: #selector(ShelfActionTargets.openWith(_:)),
                keyEquivalent: ""
            )
            mi.target = targets
            mi.representedObject = app
            mi.image = appIcon(app)
            menu.addItem(mi)
            menu.addItem(.separator())
        }

        let others = allApps
            .filter { $0 != defaultApp }
            .sorted { appDisplayName($0).localizedCaseInsensitiveCompare(appDisplayName($1)) == .orderedAscending }

        for app in others {
            let mi = NSMenuItem(
                title: appDisplayName(app),
                action: #selector(ShelfActionTargets.openWith(_:)),
                keyEquivalent: ""
            )
            mi.target = targets
            mi.representedObject = app
            mi.image = appIcon(app)
            menu.addItem(mi)
        }

        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "No Applications", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        return menu
    }

    private static func makeItem(
        title: String,
        symbol name: String,
        action: Selector,
        target: AnyObject,
        enabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.image = symbol(name)
        item.isEnabled = enabled
        return item
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
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
