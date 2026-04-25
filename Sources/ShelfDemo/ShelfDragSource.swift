import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A transparent NSView overlay that starts a real NSDraggingSession with one
/// or more file URLs. Works inside a non-activating NSPanel where SwiftUI's
/// `.onDrag` silently fails.
struct ShelfDragOverlay: NSViewRepresentable {
    /// Resolved at drag-start time so callers can vend the latest items.
    let provider: () -> [URL]
    let onStart: () -> Void
    let onEnd: () -> Void
    var menuBuilder: (() -> NSMenu?)? = nil
    var onClick: ((NSEvent.ModifierFlags) -> Void)? = nil
    var onDoubleClick: (() -> Void)? = nil

    func makeNSView(context: Context) -> DragInitiatorView {
        let view = DragInitiatorView()
        view.provider = provider
        view.onStart = onStart
        view.onEnd = onEnd
        view.menuBuilder = menuBuilder
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: DragInitiatorView, context: Context) {
        nsView.provider = provider
        nsView.onStart = onStart
        nsView.onEnd = onEnd
        nsView.menuBuilder = menuBuilder
        nsView.onClick = onClick
        nsView.onDoubleClick = onDoubleClick
    }
}

final class DragInitiatorView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    var provider: (() -> [URL])?
    var onStart: (() -> Void)?
    var onEnd: (() -> Void)?
    var menuBuilder: (() -> NSMenu?)?
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    var onDoubleClick: (() -> Void)?

    private var mouseDownPoint: NSPoint?
    private var sessionActive = false
    private let dragThreshold: CGFloat = 4

    private static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    override func menu(for event: NSEvent) -> NSMenu? {
        menuBuilder?()
    }

    override var isFlipped: Bool { false }

    // Keep the window-background drag (isMovableByWindowBackground) from stealing
    // our tile's mouse gesture.
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Claim hits when we can drag or when we offer a context menu.
        let hasDrag = !(provider?() ?? []).isEmpty
        let hasMenu = menuBuilder != nil
        return (hasDrag || hasMenu) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard !sessionActive, let start = mouseDownPoint else { return }
        let loc = event.locationInWindow
        let distance = hypot(loc.x - start.x, loc.y - start.y)
        if distance > dragThreshold {
            mouseDownPoint = nil
            beginDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let start = mouseDownPoint, !sessionActive {
            let loc = event.locationInWindow
            let distance = hypot(loc.x - start.x, loc.y - start.y)
            if distance < dragThreshold {
                if event.clickCount >= 2 {
                    onDoubleClick?()
                } else {
                    onClick?(event.modifierFlags)
                }
            }
        }
        mouseDownPoint = nil
    }

    private func beginDrag(with event: NSEvent) {
        let urls = (provider?() ?? []).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !urls.isEmpty else { return }

        let local = convert(event.locationInWindow, from: nil)
        let iconSize: CGFloat = 64

        var draggingItems: [NSDraggingItem] = []
        for (index, url) in urls.enumerated() {
            // File promise lets the destination construct the destination URL
            // (with collision handling) and ask us to write the file there.
            // Critically, destinations honor pathExtension correctly even for
            // unregistered UTIs (e.g. .cube), so collisions become "name 2.cube"
            // rather than "name.cube 2".
            let typeID = (try? url.resourceValues(forKeys: [.contentTypeKey])
                .contentType?.identifier) ?? UTType.data.identifier
            let promise = NSFilePromiseProvider(fileType: typeID, delegate: self)
            promise.userInfo = url
            let item = NSDraggingItem(pasteboardWriter: promise)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: iconSize, height: iconSize)
            let off = CGFloat(index) * 1.5
            let frame = NSRect(
                x: local.x - iconSize / 2 + off,
                y: local.y - iconSize / 2 - off,
                width: iconSize,
                height: iconSize
            )
            item.setDraggingFrame(frame, contents: icon)
            draggingItems.append(item)
        }

        sessionActive = true
        onStart?()
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .stack
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        sessionActive = false
        onEnd?()
    }

    // MARK: - NSFilePromiseProviderDelegate

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        guard let url = filePromiseProvider.userInfo as? URL else { return "Untitled" }
        return url.lastPathComponent
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let sourceURL = filePromiseProvider.userInfo as? URL else {
            completionHandler(NSError(
                domain: "ShelfDragSource", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Promise has no source URL"]
            ))
            return
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: sourceURL, to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.promiseQueue
    }
}
