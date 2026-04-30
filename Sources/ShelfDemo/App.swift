import AppKit
import Combine
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

    // Shelves created via shake auto-close when emptied; menu-created shelves don't.
    private var ephemeralShelfIDs: Set<UUID> = []
    private var emptyCloseTimers: [UUID: Timer] = [:]
    private var shelvesCancellable: AnyCancellable?
    private let emptyCloseGrace: TimeInterval = 1.2

    // Duplicate-drop toast.
    private var duplicateToastCancellable: AnyCancellable?
    private var toastPanel: NSPanel?
    private var toastHideTimer: Timer?
    private let toastVisibleDuration: TimeInterval = 2.5

    // Settings window (accessory app — created lazily, reused).
    private var settingsWindow: NSWindow?

    // Hourly check that prunes shelves whose last activity is older than the
    // user's configured retention duration (in @AppStorage as `shelf.expiryDays`).
    private var expiryTimer: Timer?

    // Polls for files that disappeared (e.g. moved to Trash from Finder) so
    // ghost entries vanish from the shelf without requiring user interaction.
    private var missingFileSweepTimer: Timer?

    private var statusItemIconCancellable: AnyCancellable?

    // Auto-park (top-right stack) state — populated only when the
    // "shelf.autoParkTopRight" preference is on. We track per-shelf item
    // counts so we only park on the 0→non-empty transition (the first drop
    // after creation), not on every subsequent change.
    private var lastItemCounts: [UUID: Int] = [:]
    private var parkedShelfIDs: Set<UUID> = []
    private var parkedShelfOrder: [UUID] = []
    private let parkMargin: CGFloat = 12
    private let parkSpacing: CGFloat = 12

    // Outside-click watcher: a single global mouse-down monitor that's
    // always installed; the "shelf.closeOnOutsideClick" flag is checked
    // inside the handler so toggling the setting takes effect immediately
    // without needing to install/uninstall the monitor.
    private var outsideClickMonitor: Any?

    private func applyStatusIcon(dropping: Bool) {
        guard let button = statusItem?.button else { return }
        // Custom-drawn glyph: rounded-square outline with the dot fully
        // inside the frame at the top-right (the SF `app.badge` symbol
        // parks the dot at the corner so it pokes out of the outline).
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let outline = NSBezierPath(
                roundedRect: rect.insetBy(dx: 1.75, dy: 1.75),
                xRadius: 4,
                yRadius: 4
            )
            outline.lineWidth = 1.6
            NSColor.black.setStroke()
            outline.stroke()

            // Slightly larger dot when a drop is active for visual emphasis.
            let dotSize: CGFloat = dropping ? 5 : 4
            let inset: CGFloat = 3.5
            let dotRect = NSRect(
                x: rect.maxX - inset - dotSize,
                y: rect.maxY - inset - dotSize,
                width: dotSize,
                height: dotSize
            )
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = true
        button.image = image
    }

    private let collapsedSize = NSSize(width: 210, height: 210)
    private let expandedSize = NSSize(width: 520, height: 560)
    private let expandedMinHeight: CGFloat = 280
    private let dockedSize = NSSize(width: 44, height: 150)
    private let dockedOffscreen: CGFloat = 18  // hides the right-side curve past the screen edge

    /// Compute an expanded panel size that hugs the actual content. Cap at
    /// `expandedSize.height` so we never grow taller than the original max.
    /// The ScrollView inside takes care of any overflow above the cap.
    private func expandedSize(for shelfID: UUID) -> NSSize {
        let count = manager.items(of: shelfID).count
        // Constants mirror DocumentGridItem layout + ExpandedShelfView chrome.
        let cellHeight: CGFloat = 154   // 8 + 100 + 8 + ~22 + 8 + 8 padding
        let rowSpacing: CGFloat = 18
        // Chrome = panel padding (20) + outer VStack header (~32) + spacing
        // (14×2) + reveal pill (~32) + grid vertical inset (~8) + safety (4).
        let chrome: CGFloat = 130

        // Adaptive grid: minimum column 96, spacing 16. Available width is
        // expanded panel width minus FloatingPanel padding (20).
        let available = expandedSize.width - 20
        let columns = max(1, Int((available + 16) / (96 + 16)))
        let rows = max(1, (count + columns - 1) / columns)

        let contentH = CGFloat(rows) * cellHeight
            + CGFloat(max(rows - 1, 0)) * rowSpacing
        let h = min(chrome + contentH, expandedSize.height)
        return NSSize(width: expandedSize.width, height: max(h, expandedMinHeight))
    }

    // Docked-to-edge state.
    private var dockedShelfIDs: Set<UUID> = []
    private var preDockFrames: [UUID: NSRect] = [:]
    private var dockedFrames: [UUID: NSRect] = [:]
    private var windowMoveObserver: NSObjectProtocol?
    private var suppressMoveCheck = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyStatusIcon(dropping: false)
        // Flip the glyph while any panel is being targeted by a drop so the
        // menubar mirrors the "ready to receive" state visually.
        statusItemIconCancellable = manager.$isAnyShelfDropTarget
            .removeDuplicates()
            .sink { [weak self] dropping in
                self?.applyStatusIcon(dropping: dropping)
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

        shelvesCancellable = manager.$shelves
            .sink { [weak self] shelves in
                self?.reconcileEmptyEphemeralShelves(shelves)
                self?.checkAutoPark(shelves)
            }

        installOutsideClickWatcher()

        duplicateToastCancellable = manager.duplicateRejected
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] shelfID in
                self?.showDuplicateToast(for: shelfID)
            }

        runShelfExpiryPrune()
        expiryTimer = Timer.scheduledTimer(
            withTimeInterval: 3600, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.runShelfExpiryPrune() }
        }

        // Sweep stale entries (files trashed from Finder while we were idle).
        // App activation isn't reliable for an accessory app, so back it up
        // with a low-frequency timer that runs unconditionally — fileExists
        // is cheap and the worst case is a few dozen stat calls per tick.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppOrFocusChange),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        manager.pruneMissingFiles()
        missingFileSweepTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.manager.pruneMissingFiles() }
        }
    }

    @objc private func handleAppOrFocusChange() {
        manager.pruneMissingFiles()
    }

    private func runShelfExpiryPrune() {
        let days = UserDefaults.standard.integer(forKey: "shelf.expiryDays")
        guard days > 0 else { return }
        let removed = manager.pruneShelves(olderThanDays: days)
        for shelfID in removed {
            panels[shelfID]?.orderOut(nil)
            panels.removeValue(forKey: shelfID)
            ephemeralShelfIDs.remove(shelfID)
            emptyCloseTimers.removeValue(forKey: shelfID)?.invalidate()
        }
        if manager.shelves.isEmpty {
            _ = manager.createShelf()
        }
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

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(
            title: "Quit",
            action: #selector(NSApp.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
    }

    @objc private func openSettingsAction() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Shelf Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        // Accessory app: temporarily bring to front so the window receives focus.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func buildRecentShelvesMenu() -> NSMenu {
        let submenu = NSMenu()

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true

        // Pinned shelves float to the top; remaining shelves stay in
        // most-recent-first order (the tail of the array is newest).
        let nonEmpty = manager.shelves.filter { !$0.items.isEmpty }
        let pinned = nonEmpty.filter { $0.pinned }.reversed()
        let rest = nonEmpty.filter { !$0.pinned }.reversed()
        let ordered = Array(pinned) + Array(rest)

        var shown = 0
        for shelf in ordered {
            shown += 1
            let item = NSMenuItem(
                title: "",
                action: #selector(openShelfAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = shelf.id

            let title: String
            if let n = shelf.name, !n.isEmpty {
                title = n
            } else if shelf.items.count == 1 {
                title = shelf.items[0].displayName
            } else {
                title = "\(shelf.items.count) Files"
            }
            var subtitle = formatter.string(from: shelf.createdAt)
            if shelf.name?.isEmpty == false {
                let count = shelf.items.count == 1 ? "1 file" : "\(shelf.items.count) files"
                subtitle = "\(count) · \(subtitle)"
            }

            let attr = NSMutableAttributedString()
            if shelf.pinned {
                let pin = NSTextAttachment()
                pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
                attr.append(NSAttributedString(attachment: pin))
                attr.append(NSAttributedString(string: " "))
            }
            attr.append(NSAttributedString(string: title + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]))
            attr.append(NSAttributedString(string: subtitle, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            item.attributedTitle = attr

            if let accentImage = recentMenuIcon(for: shelf) {
                item.image = accentImage
            } else if let first = shelf.items.first, let url = first.fileURL {
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

    /// When the shelf has an accent (color or emoji), render a 28×28 swatch
    /// for the menu item icon so the accent dominates the visual identity.
    /// Returns nil when no accent is set, letting the caller fall back to
    /// the file icon.
    private func recentMenuIcon(for shelf: Shelf) -> NSImage? {
        guard let accent = shelf.accent else { return nil }
        let size = NSSize(width: 28, height: 28)
        switch accent {
        case .color(let hex):
            return NSImage(size: size, flipped: false) { rect in
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
                (NSColor(hex: hex) ?? .systemGray).setFill()
                path.fill()
                NSColor.black.withAlphaComponent(0.15).setStroke()
                path.lineWidth = 0.5
                path.stroke()
                return true
            }
        case .emoji(let glyph):
            return NSImage(size: size, flipped: false) { rect in
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 18)
                ]
                let s = (glyph as NSString)
                let measured = s.size(withAttributes: attrs)
                let origin = NSPoint(
                    x: rect.midX - measured.width / 2,
                    y: rect.midY - measured.height / 2
                )
                s.draw(at: origin, withAttributes: attrs)
                return true
            }
        }
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
            ephemeralShelfIDs.remove(shelf.id)
            emptyCloseTimers.removeValue(forKey: shelf.id)?.invalidate()
        }
        if manager.shelves.isEmpty {
            _ = manager.createShelf()
        }
    }

    // MARK: - Shake

    private func handleShake() {
        // Ignore further shakes while a shake-created shelf is still pending.
        // Otherwise rapid shakes pile up panels and only the latest one's
        // release watcher survives, leaving earlier empties on screen.
        if let pending = pendingShelfID,
           let panel = panels[pending], panel.isVisible {
            return
        }
        let shelfID = manager.createShelf()
        ephemeralShelfIDs.insert(shelfID)
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
            // Drop handlers run asynchronously after mouseUp — NSItemProvider
            // load + temp-file write + MainActor hop. 1.2s gives the chain
            // time to land before we decide whether to close the shelf.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                if self.manager.items(of: shelfID).count == self.itemCountOnShakeOpen,
                   let panel = self.panels[shelfID], panel.isVisible {
                    panel.orderOut(nil)
                    self.manager.removeShelf(id: shelfID)
                    self.panels.removeValue(forKey: shelfID)
                    self.ephemeralShelfIDs.remove(shelfID)
                    self.emptyCloseTimers.removeValue(forKey: shelfID)?.invalidate()
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

    // MARK: - Auto-close on empty

    private func reconcileEmptyEphemeralShelves(_ shelves: [Shelf]) {
        let existingIDs = Set(shelves.map { $0.id })

        // Drop tracking for shelves that no longer exist.
        ephemeralShelfIDs.formIntersection(existingIDs)
        dockedShelfIDs.formIntersection(existingIDs)
        preDockFrames = preDockFrames.filter { existingIDs.contains($0.key) }
        // Auto-close on empty was disabled — the panel stays open until the
        // user dismisses it explicitly via the X button. Tear down any
        // lingering timers regardless of shelf liveness.
        for (_, timer) in emptyCloseTimers { timer.invalidate() }
        emptyCloseTimers.removeAll()
    }

    private func scheduleEmptyClose(for shelfID: UUID) {
        guard emptyCloseTimers[shelfID] == nil else { return }
        guard let panel = panels[shelfID], panel.isVisible else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: emptyCloseGrace, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fireEmptyClose(for: shelfID)
            }
        }
        emptyCloseTimers[shelfID] = timer
    }

    private func fireEmptyClose(for shelfID: UUID) {
        emptyCloseTimers.removeValue(forKey: shelfID)?.invalidate()
        guard ephemeralShelfIDs.contains(shelfID) else { return }
        guard manager.items(of: shelfID).isEmpty else { return }
        panels[shelfID]?.orderOut(nil)
        panels.removeValue(forKey: shelfID)
        ephemeralShelfIDs.remove(shelfID)
        manager.removeShelf(id: shelfID)
    }

    private func disarmShakeReleaseWatcher() {
        if let m = shakeReleaseGlobalMonitor { NSEvent.removeMonitor(m) }
        if let m = shakeReleaseLocalMonitor { NSEvent.removeMonitor(m) }
        shakeReleaseGlobalMonitor = nil
        shakeReleaseLocalMonitor = nil
    }

    // MARK: - Panel management

    private func openPanel(for shelfID: UUID, nearCursor: Bool) {
        // Drop any items whose files have disappeared since we last looked,
        // so a freshly-opened panel never shows ghost entries.
        manager.pruneMissingFiles()

        let panel: FloatingPanel<ShelfContainerView>
        if let existing = panels[shelfID] {
            panel = existing
        } else {
            panel = makePanel(for: shelfID)
            panels[shelfID] = panel
        }

        let expanded = expandedShelfIDs.contains(shelfID)
        let size = expanded ? expandedSize(for: shelfID) : collapsedSize

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
        // Empty shelves are invisible in Recent Shelves, so dismissing them
        // would otherwise leave a zombie behind. Tear them down completely
        // when the user clicks X on an empty shelf.
        if manager.items(of: shelfID).isEmpty {
            panels.removeValue(forKey: shelfID)
            ephemeralShelfIDs.remove(shelfID)
            emptyCloseTimers.removeValue(forKey: shelfID)?.invalidate()
            manager.removeShelf(id: shelfID)
        }
    }

    private func makePanel(for shelfID: UUID) -> FloatingPanel<ShelfContainerView> {
        let rect = NSRect(origin: .zero, size: collapsedSize)
        let isEphemeral = ephemeralShelfIDs.contains(shelfID)
        return FloatingPanel(contentRect: rect) { [weak self, manager] in
            ShelfContainerView(
                manager: manager,
                shelfID: shelfID,
                isEphemeral: isEphemeral,
                onClose: { self?.hidePanel(for: shelfID) },
                onResize: { expanded in self?.setPanelExpanded(shelfID, expanded: expanded) },
                onDockChanged: { docked in self?.setPanelDocked(shelfID, docked: docked) }
            )
        }
    }

    private func setPanelExpanded(_ shelfID: UUID, expanded: Bool) {
        guard let panel = panels[shelfID] else { return }
        if expanded { expandedShelfIDs.insert(shelfID) } else { expandedShelfIDs.remove(shelfID) }

        let newSize = expanded ? expandedSize(for: shelfID) : collapsedSize

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

        animate(panel: panel, to: newFrame)
    }

    private func setPanelDocked(_ shelfID: UUID, docked: Bool) {
        guard let panel = panels[shelfID] else { return }

        if docked {
            preDockFrames[shelfID] = panel.frame
            dockedShelfIDs.insert(shelfID)
            installWindowMoveObserverIfNeeded()

            let currentFrame = panel.frame
            let screenFrame = panel.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? currentFrame
            // Position so the right-side curve sits past the screen edge,
            // giving a flat flush-to-edge look on the visible side.
            let originX = screenFrame.maxX - dockedSize.width + dockedOffscreen
            var originY = currentFrame.midY - dockedSize.height / 2
            originY = max(screenFrame.minY + 4,
                          min(originY, screenFrame.maxY - dockedSize.height - 4))
            let newFrame = NSRect(
                x: originX, y: originY,
                width: dockedSize.width, height: dockedSize.height
            )
            dockedFrames[shelfID] = newFrame
            animate(panel: panel, to: newFrame)
        } else {
            dockedShelfIDs.remove(shelfID)
            dockedFrames.removeValue(forKey: shelfID)
            if dockedShelfIDs.isEmpty { removeWindowMoveObserver() }
            let restore: NSRect
            if let saved = preDockFrames.removeValue(forKey: shelfID) {
                restore = saved
            } else {
                let size = expandedShelfIDs.contains(shelfID) ? expandedSize(for: shelfID) : collapsedSize
                let currentFrame = panel.frame
                let screenFrame = panel.screen?.visibleFrame
                    ?? NSScreen.main?.visibleFrame
                    ?? currentFrame
                let originX = max(screenFrame.minX + 8,
                                  screenFrame.maxX - size.width - 8)
                let originY = max(screenFrame.minY + 8,
                                  currentFrame.midY - size.height / 2)
                restore = NSRect(origin: NSPoint(x: originX, y: originY), size: size)
            }
            animate(panel: panel, to: restore)
        }
    }

    // MARK: - Auto-park (top-right)

    /// Detects 0→non-empty transitions per shelf and, if the setting is on,
    /// slides the shelf's panel up to the top-right corner where it stacks
    /// behind any other parked shelves. Also prunes tracking for shelves
    /// that have been removed.
    private func checkAutoPark(_ shelves: [Shelf]) {
        let live = Set(shelves.map(\.id))
        // Drop tracking for shelves that no longer exist so the stacking
        // index stays compact when shelves are dismissed.
        if parkedShelfOrder.contains(where: { !live.contains($0) }) {
            parkedShelfOrder.removeAll { !live.contains($0) }
            parkedShelfIDs.formIntersection(live)
            // Reposition remaining parked shelves into the now-tighter stack.
            relayoutParkedShelves()
        }
        lastItemCounts = lastItemCounts.filter { live.contains($0.key) }

        let enabled = UserDefaults.standard.bool(forKey: "shelf.autoParkTopRight")
        for shelf in shelves {
            let prev = lastItemCounts[shelf.id] ?? 0
            let now = shelf.items.count
            lastItemCounts[shelf.id] = now
            // Park on the very first drop into a freshly-empty shelf.
            // Subsequent drops are ignored so the user can drag the panel
            // anywhere they like without it snapping back.
            if enabled, prev == 0, now > 0, !parkedShelfIDs.contains(shelf.id) {
                parkShelf(id: shelf.id)
            }
        }
    }

    private func parkShelf(id: UUID) {
        guard let panel = panels[id] else { return }
        parkedShelfIDs.insert(id)
        parkedShelfOrder.append(id)
        let frame = parkedFrame(for: id, on: panel.screen)
        animate(panel: panel, to: frame)
    }

    private func relayoutParkedShelves() {
        for id in parkedShelfOrder {
            guard let panel = panels[id] else { continue }
            animate(panel: panel, to: parkedFrame(for: id, on: panel.screen))
        }
    }

    private func parkedFrame(for id: UUID, on screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let index = parkedShelfOrder.firstIndex(of: id) ?? 0
        let originX = visible.maxX - collapsedSize.width - parkMargin
        let originY = visible.maxY - collapsedSize.height - parkMargin
            - CGFloat(index) * (collapsedSize.height + parkSpacing)
        return NSRect(
            x: originX,
            y: max(visible.minY + parkMargin, originY),
            width: collapsedSize.width,
            height: collapsedSize.height
        )
    }

    // MARK: - Close on outside click

    private func installOutsideClickWatcher() {
        guard outsideClickMonitor == nil else { return }
        // Global monitor only fires for clicks NOT in our app, so clicks on
        // the panels themselves (and on our menu bar item) don't trigger
        // this — exactly the semantics we want.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleOutsideClick()
            }
        }
    }

    private func handleOutsideClick() {
        guard UserDefaults.standard.bool(forKey: "shelf.closeOnOutsideClick") else { return }
        let visible = panels.filter { $0.value.isVisible }
        guard !visible.isEmpty else { return }
        let location = NSEvent.mouseLocation
        // Inside-panel safety net: a click that lands on a panel's frame is
        // treated as inside even if the global monitor still routed it to
        // us (e.g. the panel is non-activating and the OS counted the click
        // as "outside the app").
        let inside = visible.contains { $0.value.frame.contains(location) }
        guard !inside else { return }
        // Only collapse panels that are currently in expanded mode — the
        // user wants the detail view to fold back to the pill, not for the
        // whole shelf to disappear.
        for shelfID in expandedShelfIDs where visible.keys.contains(shelfID) {
            manager.collapseRequested.send(shelfID)
        }
    }

    private func animate(panel: NSPanel, to frame: NSRect) {
        suppressMoveCheck = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1.0)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            self?.suppressMoveCheck = false
        })
    }

    // MARK: - Docked drag-off detection

    private func installWindowMoveObserverIfNeeded() {
        guard windowMoveObserver == nil else { return }
        windowMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSPanel else { return }
            Task { @MainActor in self.handleDockedPanelMoved(window) }
        }
    }

    private func removeWindowMoveObserver() {
        if let obs = windowMoveObserver {
            NotificationCenter.default.removeObserver(obs)
            windowMoveObserver = nil
        }
    }

    private func handleDockedPanelMoved(_ window: NSPanel) {
        if suppressMoveCheck { return }
        guard let (shelfID, _) = panels.first(where: { $0.value === window }) else { return }
        guard dockedShelfIDs.contains(shelfID) else { return }
        guard let anchored = dockedFrames[shelfID] else { return }

        let dx = abs(window.frame.minX - anchored.minX)
        let dy = abs(window.frame.minY - anchored.minY)
        guard dx > 4 || dy > 4 else { return }

        undockInPlace(shelfID: shelfID, fromFrame: window.frame)
    }

    private func undockInPlace(shelfID: UUID, fromFrame: NSRect) {
        guard let panel = panels[shelfID] else { return }
        dockedShelfIDs.remove(shelfID)
        dockedFrames.removeValue(forKey: shelfID)
        preDockFrames.removeValue(forKey: shelfID)
        if dockedShelfIDs.isEmpty { removeWindowMoveObserver() }

        let size = expandedShelfIDs.contains(shelfID) ? expandedSize(for: shelfID) : collapsedSize
        // Keep the current top-left roughly where the user let go.
        let topY = fromFrame.maxY
        let newFrame = NSRect(
            x: fromFrame.minX,
            y: topY - size.height,
            width: size.width,
            height: size.height
        )
        animate(panel: panel, to: newFrame)
        manager.undockRequested.send(shelfID)
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

    // MARK: - Duplicate toast

    private func showDuplicateToast(for shelfID: UUID) {
        guard let shelfPanel = panels[shelfID], shelfPanel.isVisible else { return }

        let panel = toastPanel ?? makeToastPanel()
        toastPanel = panel

        let shelfFrame = shelfPanel.frame
        let size = NSSize(width: shelfFrame.width, height: 56)
        let gap: CGFloat = 10
        var originX = shelfFrame.midX - size.width / 2
        var originY = shelfFrame.minY - size.height - gap

        if let screenFrame = shelfPanel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            originX = max(screenFrame.minX + 8,
                          min(originX, screenFrame.maxX - size.width - 8))
            if originY < screenFrame.minY + 8 {
                // Not enough room below; show above the shelf instead.
                originY = shelfFrame.maxY + gap
            }
        }

        panel.setFrame(
            NSRect(origin: NSPoint(x: originX, y: originY), size: size),
            display: true
        )
        panel.orderFront(nil)

        toastHideTimer?.invalidate()
        toastHideTimer = Timer.scheduledTimer(
            withTimeInterval: toastVisibleDuration,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.toastPanel?.orderOut(nil)
            }
        }
    }

    private func makeToastPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .utilityWindow

        let hosting = NSHostingView(rootView: DuplicateToastView())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: panel.contentView?.bounds ?? .zero)
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        return panel
    }

    // MARK: - Paste shortcut

    private func installPasteShortcut() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard let (shelfID, _) = self.panels.first(where: { $0.value.isKeyWindow }) else {
                return event
            }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
                return event
            }
            switch event.charactersIgnoringModifiers {
            case "v":
                let added = self.manager.addFromClipboard(to: shelfID)
                return added > 0 ? nil : event
            case "a":
                // Forward to the expanded view via Combine; it owns the
                // selection state and decides what "all" means in the
                // current view (shelf root vs folder browse).
                self.manager.selectAllRequested.send(shelfID)
                return nil
            case "c":
                self.manager.copyRequested.send(shelfID)
                return nil
            default:
                return event
            }
        }
    }
}

private struct DuplicateToastView: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
            Text("One or more items is\nalready present in the shelf")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(white: 0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }
}
