import AppKit
import SwiftUI

@main
struct ShelfDemoApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        app.delegate = delegate

        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let manager = ShelfManager()
    private let shakeDetector = ShakeDetector()

    // One panel per shelf.
    private var panels: [UUID: FloatingPanel<ShelfContainerView>] = [:]
    private var expandedShelfIDs: Set<UUID> = []

    private var shakeReleaseGlobalMonitor: Any?
    private var shakeReleaseLocalMonitor: Any?
    private var pendingShelfID: UUID?
    private var itemCountOnShakeOpen: Int = 0

    private let collapsedSize = NSSize(width: 178, height: 234)
    private let expandedSize = NSSize(width: 520, height: 560)

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "square.stack.3d.up.fill",
                accessibilityDescription: "Shelf"
            )
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        shakeDetector.onShake = { [weak self] in self?.handleShake() }
        shakeDetector.start()

        QuickLookController.shared.urlsProvider = { [weak self] in
            self?.urlsForKeyPanel() ?? []
        }

        installPasteShortcut()
    }

    private func urlsForKeyPanel() -> [URL] {
        guard let (shelfID, _) = panels.first(where: { $0.value.isKeyWindow })
                ?? panels.first(where: { $0.value.isVisible })
        else { return [] }
        return manager.items(of: shelfID).compactMap { $0.fileURL }
    }

    // MARK: - Status menu

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        Task { @MainActor in
            self.rebuildStatusMenu(menu)
        }
    }

    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let newShelf = NSMenuItem(
            title: "New Shelf",
            action: #selector(newShelfAction),
            keyEquivalent: "n"
        )
        newShelf.target = self
        newShelf.keyEquivalentModifierMask = [.option, .shift]
        menu.addItem(newShelf)

        let newFromClip = NSMenuItem(
            title: "New Shelf From Clipboard",
            action: #selector(newShelfFromClipboardAction),
            keyEquivalent: "a"
        )
        newFromClip.target = self
        newFromClip.keyEquivalentModifierMask = [.option, .shift]
        menu.addItem(newFromClip)

        let recent = NSMenuItem(title: "Recent Shelves", action: nil, keyEquivalent: "")
        recent.submenu = buildRecentShelvesMenu()
        menu.addItem(recent)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit",
            action: #selector(NSApp.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
    }

    private func buildRecentShelvesMenu() -> NSMenu {
        let submenu = NSMenu()
        let shelves = manager.shelves.reversed()

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true

        var shown = 0
        for shelf in shelves {
            guard !shelf.items.isEmpty else { continue }
            shown += 1
            let item = NSMenuItem(
                title: "",
                action: #selector(openShelfAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = shelf.id

            let title = shelf.items.count == 1
                ? shelf.items[0].displayName
                : "\(shelf.items.count) Files"
            let subtitle = formatter.string(from: shelf.createdAt)

            let attr = NSMutableAttributedString()
            attr.append(NSAttributedString(string: title + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]))
            attr.append(NSAttributedString(string: subtitle, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            item.attributedTitle = attr

            if let first = shelf.items.first, let url = first.fileURL {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 28, height: 28)
                item.image = icon
            }
            submenu.addItem(item)
        }

        if shown == 0 {
            let empty = NSMenuItem(title: "No Recent Shelves", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            submenu.addItem(.separator())
            let clear = NSMenuItem(
                title: "Clear Recent Shelves",
                action: #selector(clearAllShelvesAction),
                keyEquivalent: ""
            )
            clear.target = self
            submenu.addItem(clear)
        }

        return submenu
    }

    @objc private func newShelfAction() {
        let shelfID = manager.createShelf()
        openPanel(for: shelfID, nearCursor: false)
    }

    @objc private func newShelfFromClipboardAction() {
        let shelfID = manager.createShelf()
        _ = manager.addFromClipboard(to: shelfID)
        openPanel(for: shelfID, nearCursor: false)
    }

    @objc private func openShelfAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        openPanel(for: id, nearCursor: false)
    }

    @objc private func clearAllShelvesAction() {
        for shelf in manager.shelves {
            panels[shelf.id]?.orderOut(nil)
            panels.removeValue(forKey: shelf.id)
            manager.removeShelf(id: shelf.id)
        }
        if manager.shelves.isEmpty {
            _ = manager.createShelf()
        }
    }

    // MARK: - Shake

    private func handleShake() {
        // Every shake creates its own empty shelf + panel near the cursor.
        let shelfID = manager.createShelf()
        pendingShelfID = shelfID
        itemCountOnShakeOpen = 0
        openPanel(for: shelfID, nearCursor: true)
        armShakeReleaseWatcher(for: shelfID)
    }

    private func armShakeReleaseWatcher(for shelfID: UUID) {
        disarmShakeReleaseWatcher()

        let handle: (NSEvent) -> Void = { [weak self] _ in
            guard let self else { return }
            self.disarmShakeReleaseWatcher()
            // Drop handlers run asynchronously after mouseUp; give them a chance
            // to land before deciding whether the shelf should close.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if self.manager.items(of: shelfID).count == self.itemCountOnShakeOpen,
                   let panel = self.panels[shelfID], panel.isVisible {
                    panel.orderOut(nil)
                    self.manager.removeShelf(id: shelfID)
                    self.panels.removeValue(forKey: shelfID)
                }
                self.pendingShelfID = nil
            }
        }

        shakeReleaseGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .leftMouseUp
        ) { event in
            handle(event)
        }
        shakeReleaseLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseUp
        ) { event in
            handle(event)
            return event
        }
    }

    private func disarmShakeReleaseWatcher() {
        if let m = shakeReleaseGlobalMonitor { NSEvent.removeMonitor(m) }
        if let m = shakeReleaseLocalMonitor { NSEvent.removeMonitor(m) }
        shakeReleaseGlobalMonitor = nil
        shakeReleaseLocalMonitor = nil
    }

    // MARK: - Panel management

    private func openPanel(for shelfID: UUID, nearCursor: Bool) {
        let panel: FloatingPanel<ShelfContainerView>
        if let existing = panels[shelfID] {
            panel = existing
        } else {
            panel = makePanel(for: shelfID)
            panels[shelfID] = panel
        }

        let expanded = expandedShelfIDs.contains(shelfID)
        let size = expanded ? expandedSize : collapsedSize

        if nearCursor {
            positionPanelNearCursor(panel, size: size)
        } else if panel.frame.size == .zero || !panel.isVisible {
            positionPanelBelowStatusItem(panel, size: size)
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func hidePanel(for shelfID: UUID) {
        panels[shelfID]?.orderOut(nil)
    }

    private func makePanel(for shelfID: UUID) -> FloatingPanel<ShelfContainerView> {
        let rect = NSRect(origin: .zero, size: collapsedSize)
        return FloatingPanel(contentRect: rect) { [weak self, manager] in
            ShelfContainerView(
                manager: manager,
                shelfID: shelfID,
                onClose: { self?.hidePanel(for: shelfID) },
                onResize: { expanded in self?.setPanelExpanded(shelfID, expanded: expanded) },
                onOpenShelf: { id in self?.openPanel(for: id, nearCursor: false) }
            )
        }
    }

    private func setPanelExpanded(_ shelfID: UUID, expanded: Bool) {
        guard let panel = panels[shelfID] else { return }
        if expanded { expandedShelfIDs.insert(shelfID) } else { expandedShelfIDs.remove(shelfID) }

        let newSize = expanded ? expandedSize : collapsedSize

        let currentFrame = panel.frame
        let topY = currentFrame.maxY
        let centerX = currentFrame.midX

        var originX = centerX - newSize.width / 2
        var originY = topY - newSize.height

        if let screenFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            originX = max(screenFrame.minX + 8,
                          min(originX, screenFrame.maxX - newSize.width - 8))
            originY = max(screenFrame.minY + 8, originY)
        }

        let newFrame = NSRect(x: originX, y: originY,
                              width: newSize.width, height: newSize.height)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.5
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1.0)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(newFrame, display: true)
        }
    }

    // MARK: - Positioning

    private func positionPanelNearCursor(_ panel: NSPanel, size: NSSize) {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let edgeMargin: CGFloat = 12
        let dockThreshold: CGFloat = 72
        let cursorGap: CGFloat = 16

        let distLeft = cursor.x - frame.minX
        let distRight = frame.maxX - cursor.x
        let distTop = frame.maxY - cursor.y
        let distBottom = cursor.y - frame.minY

        var originX: CGFloat
        if distRight < dockThreshold {
            originX = frame.maxX - size.width - edgeMargin
        } else if distLeft < dockThreshold {
            originX = frame.minX + edgeMargin
        } else {
            let rightCandidate = cursor.x + cursorGap
            originX = rightCandidate + size.width <= frame.maxX - edgeMargin
                ? rightCandidate
                : cursor.x - size.width - cursorGap
        }

        var originY: CGFloat
        if distTop < dockThreshold {
            originY = frame.maxY - size.height - edgeMargin
        } else if distBottom < dockThreshold {
            originY = frame.minY + edgeMargin
        } else {
            let belowCandidate = cursor.y - size.height - cursorGap
            originY = belowCandidate >= frame.minY + edgeMargin
                ? belowCandidate
                : cursor.y + cursorGap
        }

        originX = max(frame.minX + edgeMargin,
                      min(originX, frame.maxX - size.width - edgeMargin))
        originY = max(frame.minY + edgeMargin,
                      min(originY, frame.maxY - size.height - edgeMargin))

        panel.setFrame(
            NSRect(origin: NSPoint(x: originX, y: originY), size: size),
            display: true
        )
    }

    private func positionPanelBelowStatusItem(_ panel: NSPanel, size: NSSize) {
        guard
            let button = statusItem.button,
            let buttonWindow = button.window
        else { return }

        let buttonFrameOnScreen = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let gap: CGFloat = 8

        var originX = buttonFrameOnScreen.midX - size.width / 2
        originX = max(screenFrame.minX + 8,
                      min(originX, screenFrame.maxX - size.width - 8))
        let originY = buttonFrameOnScreen.minY - size.height - gap

        panel.setFrame(NSRect(origin: NSPoint(x: originX, y: originY), size: size),
                       display: true)
    }

    // MARK: - Paste shortcut

    private func installPasteShortcut() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard let (shelfID, panel) = self.panels.first(where: { $0.value.isKeyWindow }) else {
                return event
            }
            _ = panel
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
                return event
            }
            guard event.charactersIgnoringModifiers == "v" else { return event }
            let added = self.manager.addFromClipboard(to: shelfID)
            return added > 0 ? nil : event
        }
    }
}
