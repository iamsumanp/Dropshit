import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

    @objc func undo() {
        manager.performUndo()
    }

    // MARK: - Identity

    @objc func renameShelf() {
        let current = manager.shelf(id: shelfID)?.name ?? ""
        guard let new = Self.promptShelfName(current: current) else { return }
        manager.renameShelf(id: shelfID, to: new)
    }

    @objc func togglePinned() {
        let current = manager.shelf(id: shelfID)?.pinned ?? false
        manager.setShelfPinned(id: shelfID, !current)
    }

    @objc func setAccentColor(_ sender: NSMenuItem) {
        guard let hex = sender.representedObject as? String else { return }
        manager.setShelfAccent(id: shelfID, .color(hex))
    }

    @objc func pickAccentEmoji() {
        // Toggling the character palette is the cheapest way to let the user
        // pick an emoji without rolling a custom picker. The user copies the
        // glyph; we read it back from the pasteboard via promptShelfName-style
        // alert for now.
        guard let emoji = Self.promptEmoji() else { return }
        manager.setShelfAccent(id: shelfID, .emoji(emoji))
    }

    @objc func clearAccent() {
        manager.setShelfAccent(id: shelfID, nil)
    }

    // MARK: - Global actions

    @objc func getInfo() {
        let urls = self.urls
        guard !urls.isEmpty else { return }
        // Cap to avoid spamming windows for huge shelves.
        for url in urls.prefix(8) {
            let escaped = url.path.replacingOccurrences(of: "\"", with: "\\\"")
            let source = """
            tell application "Finder"
                activate
                open information window of (POSIX file "\(escaped)" as alias)
            end tell
            """
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    @objc func batchRename() {
        let items = manager.items(of: shelfID)
        let renamable = items.compactMap { item -> (UUID, URL)? in
            guard let url = item.fileURL,
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (item.id, url)
        }
        guard !renamable.isEmpty else { return }
        guard let pattern = Self.promptBatchRename() else { return }

        var failures: [(name: String, reason: String)] = []
        var renamedCount = 0

        // Files we're about to rename away — don't treat them as collisions.
        let sourcePaths = Set(renamable.map { $0.1.standardizedFileURL.path })
        var plannedPaths: Set<String> = []

        for (i, pair) in renamable.enumerated() {
            let number = i + 1
            let url = pair.1
            let ext = url.pathExtension
            let dir = url.deletingLastPathComponent()

            // Only insert a number when the pattern asks for it.
            let baseName = pattern.contains("#")
                ? pattern.replacingOccurrences(of: "#", with: "\(number)")
                : pattern

            var target = dir.appendingPathComponent(baseName)
            if !ext.isEmpty { target.appendPathExtension(ext) }

            // Disambiguate only when the intended name really collides.
            var n = 2
            while target.standardizedFileURL.path != url.standardizedFileURL.path {
                let key = target.standardizedFileURL.path
                let existsOnDisk = FileManager.default.fileExists(atPath: target.path)
                    && !sourcePaths.contains(key)
                if !plannedPaths.contains(key) && !existsOnDisk { break }
                var cand = dir.appendingPathComponent("\(baseName) \(n)")
                if !ext.isEmpty { cand.appendPathExtension(ext) }
                target = cand
                n += 1
            }

            plannedPaths.insert(target.standardizedFileURL.path)
            guard target.standardizedFileURL.path != url.standardizedFileURL.path else {
                continue
            }

            do {
                try manager.renameItem(id: pair.0, to: target, in: shelfID)
                renamedCount += 1
            } catch {
                failures.append((
                    name: url.lastPathComponent,
                    reason: (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                ))
            }
        }

        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = renamedCount > 0
                ? String(format: L("alert.batch-renamed.title"), renamedCount, failures.count)
                : L("Batch Rename Failed")
            alert.informativeText = failures
                .map { "• \($0.name) — \($0.reason)" }
                .joined(separator: "\n")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
        }
    }

    @objc func createZipArchive() {
        let urls = self.urls
        guard !urls.isEmpty else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Archive.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        try? FileManager.default.removeItem(at: dest)

        // Stage the sources by hard-link (falls back to copy) into a temp dir,
        // then run `zip -r` from that dir using basenames. This sidesteps
        // `zip -j` path-junk warnings and avoids any TCC surprises from
        // spawning zip with absolute paths into protected folders.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shelf-zip-\(UUID().uuidString)")

        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            Self.showZipError(String(format: L("alert.zip.staging-failed"), error.localizedDescription))
            return
        }

        var basenames: [String] = []
        var seen: Set<String> = []
        for src in urls {
            let name = Self.uniqueName(for: src.lastPathComponent, in: &seen)
            let link = staging.appendingPathComponent(name)
            do {
                try FileManager.default.linkItem(at: src, to: link)
            } catch {
                // Fall back to copy for cross-volume or permission cases.
                do {
                    try FileManager.default.copyItem(at: src, to: link)
                } catch {
                    Self.showZipError(String(format: L("alert.zip.stage-failed"), src.lastPathComponent, error.localizedDescription))
                    try? FileManager.default.removeItem(at: staging)
                    return
                }
            }
            basenames.append(name)
        }

        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = staging
            process.arguments = ["-r", dest.path] + basenames

            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = Pipe()

            do {
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: staging)
                await Self.showZipError(String(format: L("alert.zip.launch-failed"), error.localizedDescription))
                return
            }
            process.waitUntilExit()

            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status = process.terminationStatus
            try? FileManager.default.removeItem(at: staging)

            if status != 0 {
                let detail = errText.isEmpty
                    ? String(format: L("alert.zip.exit-status"), Int(status))
                    : errText
                await Self.showZipError(detail)
            }
        }
    }

    @MainActor
    private static func showZipError(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = L("Archive Failed")
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static func uniqueName(for name: String, in seen: inout Set<String>) -> String {
        var candidate = name
        if !seen.contains(candidate) {
            seen.insert(candidate)
            return candidate
        }
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        while true {
            candidate = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            if !seen.contains(candidate) {
                seen.insert(candidate)
                return candidate
            }
            i += 1
        }
    }

    @objc func copyPath() {
        let urls = self.urls
        guard !urls.isEmpty else { return }
        let joined = urls.map { $0.path }.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([joined as NSString])
    }

    @objc func moveAllToTrash() {
        let items = manager.items(of: shelfID)
        var urlToItem: [String: ShelfItem] = [:]
        var urls: [URL] = []
        for item in items {
            guard let url = item.fileURL,
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            urlToItem[url.standardizedFileURL.path] = item
            urls.append(url)
        }
        guard !urls.isEmpty else { return }

        let mgr = manager
        let shelfRef = shelfID
        NSWorkspace.shared.recycle(urls) { trashed, _ in
            Task { @MainActor in
                let trashedItems = trashed.keys.compactMap {
                    urlToItem[$0.standardizedFileURL.path]
                }
                mgr.captureTrashUndo(
                    items: trashedItems,
                    trashedURLs: trashed,
                    in: shelfRef
                )
                for item in trashedItems {
                    mgr.removeItem(id: item.id, from: shelfRef)
                }
            }
        }
    }

    static func promptShelfName(current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = L("Rename Shelf")
        alert.informativeText = L("alert.shelf-rename.body")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    static func promptEmoji() -> String? {
        let alert = NSAlert()
        alert.messageText = L("Set Accent Emoji")
        alert.informativeText = L("alert.emoji.body")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L("Set"))
        alert.addButton(withTitle: L("Cancel"))
        // Open the system character palette so the user can pick one.
        NSApp.orderFrontCharacterPalette(nil)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        return String(first)
    }

    static func promptBatchRename(defaultPattern: String = "File #") -> String? {
        let alert = NSAlert()
        alert.messageText = L("Batch Rename")
        alert.informativeText = L("alert.batch-rename.body")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultPattern
        alert.accessoryView = field
        alert.addButton(withTitle: L("Rename"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
            let openWith = NSMenuItem(title: L("Open With"), action: nil, keyEquivalent: "")
            openWith.image = symbol("square.stack")
            openWith.submenu = makeOpenWithMenu(for: url, targets: targets)
            menu.addItem(openWith)
        }

        menu.addItem(makeItem(
            title: L("Show in Finder"),
            symbol: "folder",
            action: #selector(ShelfActionTargets.showInFinder),
            target: targets,
            enabled: hasFiles
        ))

        menu.addItem(makeItem(
            title: L("Quick Look"),
            symbol: "eye",
            action: #selector(ShelfActionTargets.quickLook),
            target: targets,
            enabled: hasFiles
        ))

        menu.addItem(.separator())

        menu.addItem(makeItem(
            title: L("AirDrop"),
            symbol: "wave.3.right",
            action: #selector(ShelfActionTargets.airDrop),
            target: targets,
            enabled: hasFiles
        ))

        menu.addItem(makeItem(
            title: L("Messages"),
            symbol: "message",
            action: #selector(ShelfActionTargets.messages),
            target: targets,
            enabled: hasFiles
        ))

        menu.addItem(.separator())

        menu.addItem(makeItem(
            title: L("Add From Clipboard"),
            symbol: "doc.on.clipboard",
            action: #selector(ShelfActionTargets.addFromClipboard),
            target: targets,
            enabled: true
        ))

        let copyTitle = items.count <= 1
            ? L("Copy")
            : String(format: L("Copy %lld Files"), items.count)
        menu.addItem(makeItem(
            title: copyTitle,
            symbol: "doc.on.doc",
            action: #selector(ShelfActionTargets.copyAll),
            target: targets,
            enabled: !items.isEmpty
        ))

        menu.addItem(.separator())

        let allActions = NSMenuItem(title: L("All Actions"), action: nil, keyEquivalent: "")
        allActions.image = symbol("ellipsis.circle")
        allActions.submenu = makeAllActionsMenu(targets: targets, hasFiles: hasFiles)
        menu.addItem(allActions)

        let identity = NSMenuItem(title: L("Shelf"), action: nil, keyEquivalent: "")
        identity.image = symbol("tag")
        identity.submenu = makeIdentityMenu(manager: manager, shelfID: shelfID, targets: targets)
        menu.addItem(identity)

        // Undo (Cmd-Z) — title reflects what's about to be reversed so the
        // user knows whether they're undoing a Clear or a Move-to-Trash. The
        // row stays in the menu when there's nothing to undo (disabled), so
        // discoverability isn't tied to recent activity.
        let undoTitle = manager.undoSnapshot?.menuTitle ?? L("Undo")
        let undo = NSMenuItem(
            title: undoTitle,
            action: #selector(ShelfActionTargets.undo),
            keyEquivalent: "z"
        )
        undo.keyEquivalentModifierMask = .command
        undo.target = targets
        undo.image = symbol("arrow.uturn.backward")
        undo.isEnabled = manager.canUndo
        menu.addItem(undo)

        menu.addItem(makeItem(
            title: L("Clear Shelf"),
            symbol: "xmark.bin",
            action: #selector(ShelfActionTargets.clear),
            target: targets,
            enabled: !items.isEmpty
        ))

        return menu
    }

    private static func makeIdentityMenu(
        manager: ShelfManager,
        shelfID: UUID,
        targets: ShelfActionTargets
    ) -> NSMenu {
        let menu = NSMenu()
        let shelf = manager.shelf(id: shelfID)
        let isPinned = shelf?.pinned ?? false
        let currentAccent = shelf?.accent

        let renameTitle = (shelf?.name?.isEmpty == false) ? L("Rename Shelf…") : L("Name Shelf…")
        menu.addItem(makeItem(
            title: renameTitle,
            symbol: "character.cursor.ibeam",
            action: #selector(ShelfActionTargets.renameShelf),
            target: targets,
            enabled: true
        ))

        let pin = makeItem(
            title: isPinned ? L("Unpin Shelf") : L("Pin Shelf"),
            symbol: isPinned ? "pin.slash" : "pin",
            action: #selector(ShelfActionTargets.togglePinned),
            target: targets,
            enabled: true
        )
        if isPinned { pin.state = .on }
        menu.addItem(pin)

        menu.addItem(.separator())

        let accentLabel = NSMenuItem(title: L("Accent"), action: nil, keyEquivalent: "")
        accentLabel.image = symbol("paintpalette")
        accentLabel.submenu = makeAccentMenu(currentAccent: currentAccent, targets: targets)
        menu.addItem(accentLabel)

        return menu
    }

    private static func makeAccentMenu(
        currentAccent: ShelfAccent?,
        targets: ShelfActionTargets
    ) -> NSMenu {
        let menu = NSMenu()

        let none = NSMenuItem(
            title: L("None"),
            action: #selector(ShelfActionTargets.clearAccent),
            keyEquivalent: ""
        )
        none.target = targets
        if currentAccent == nil { none.state = .on }
        menu.addItem(none)

        menu.addItem(.separator())

        let palette: [(String, String)] = [
            (L("Red"),    "#FF453A"),
            (L("Orange"), "#FF9F0A"),
            (L("Yellow"), "#FFD60A"),
            (L("Green"),  "#30D158"),
            (L("Blue"),   "#0A84FF"),
            (L("Purple"), "#BF5AF2"),
        ]
        for (label, hex) in palette {
            let mi = NSMenuItem(
                title: label,
                action: #selector(ShelfActionTargets.setAccentColor(_:)),
                keyEquivalent: ""
            )
            mi.target = targets
            mi.representedObject = hex
            mi.image = colorSwatch(hex: hex)
            if case .color(let active) = currentAccent, active == hex { mi.state = .on }
            menu.addItem(mi)
        }

        menu.addItem(.separator())

        let emoji = NSMenuItem(
            title: L("Pick Emoji…"),
            action: #selector(ShelfActionTargets.pickAccentEmoji),
            keyEquivalent: ""
        )
        emoji.target = targets
        if case .emoji = currentAccent { emoji.state = .on }
        menu.addItem(emoji)

        return menu
    }

    private static func colorSwatch(hex: String) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            (NSColor(hex: hex) ?? .systemGray).setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.15).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
        return image
    }

    private static func makeAllActionsMenu(
        targets: ShelfActionTargets,
        hasFiles: Bool
    ) -> NSMenu {
        let menu = NSMenu()

        menu.addItem(makeItem(
            title: L("Get Info"),
            symbol: "info.circle",
            action: #selector(ShelfActionTargets.getInfo),
            target: targets,
            enabled: hasFiles
        ))

        menu.addItem(makeItem(
            title: L("Batch Rename…"),
            symbol: "character.cursor.ibeam",
            action: #selector(ShelfActionTargets.batchRename),
            target: targets,
            enabled: hasFiles
        ))

        menu.addItem(makeItem(
            title: L("Create ZIP Archive…"),
            symbol: "doc.zipper",
            action: #selector(ShelfActionTargets.createZipArchive),
            target: targets,
            enabled: hasFiles
        ))

        menu.addItem(makeItem(
            title: L("Copy Path"),
            symbol: "doc.on.doc",
            action: #selector(ShelfActionTargets.copyPath),
            target: targets,
            enabled: hasFiles
        ))

        menu.addItem(.separator())

        menu.addItem(makeItem(
            title: L("Move to Trash"),
            symbol: "trash",
            action: #selector(ShelfActionTargets.moveAllToTrash),
            target: targets,
            enabled: hasFiles
        ))

        return menu
    }

    private static func makeOpenWithMenu(for url: URL, targets: ShelfActionTargets) -> NSMenu {
        let menu = NSMenu()
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        let allApps = NSWorkspace.shared.urlsForApplications(toOpen: url)

        if let app = defaultApp {
            let mi = NSMenuItem(
                title: appDisplayName(app) + L("openwith.default.suffix"),
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
            let empty = NSMenuItem(title: L("No Applications"), action: nil, keyEquivalent: "")
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

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
