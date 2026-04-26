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
    /// Optional explicit visible card size, in points. When the SwiftUI
    /// hosting view sizes the overlay larger than the actual card (because
    /// of shadows, scale effects, or sibling overlays), this lets us
    /// snapshot only the card and avoid pulling in the dark panel backdrop.
    var visibleCardSize: (() -> CGSize)? = nil

    func makeNSView(context: Context) -> DragInitiatorView {
        let view = DragInitiatorView()
        view.provider = provider
        view.onStart = onStart
        view.onEnd = onEnd
        view.menuBuilder = menuBuilder
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.visibleCardSize = visibleCardSize
        return view
    }

    func updateNSView(_ nsView: DragInitiatorView, context: Context) {
        nsView.provider = provider
        nsView.onStart = onStart
        nsView.onEnd = onEnd
        nsView.menuBuilder = menuBuilder
        nsView.onClick = onClick
        nsView.onDoubleClick = onDoubleClick
        nsView.visibleCardSize = visibleCardSize
    }
}

final class DragInitiatorView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    var provider: (() -> [URL])?
    var onStart: (() -> Void)?
    var onEnd: (() -> Void)?
    var menuBuilder: (() -> NSMenu?)?
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    var onDoubleClick: (() -> Void)?
    var visibleCardSize: (() -> CGSize)?

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

        // Snapshot the actual rendered tile *before* notifying the source
        // (which fades the tile out). Use the caller-provided visible card
        // size when available — SwiftUI's overlay host can be larger than
        // the visible card (because of sibling overlays / hover effects),
        // so snapshotting plain `bounds` would pull in the dark panel
        // backdrop and surround the drag preview with a black frame.
        let cardSize = visibleCardSize?() ?? bounds.size
        let cw = min(cardSize.width, bounds.width)
        let ch = min(cardSize.height, bounds.height)
        let snapshotRect = NSRect(
            x: (bounds.width - cw) / 2,
            y: (bounds.height - ch) / 2,
            width: cw,
            height: ch
        )
        let dragImage = snapshotTile(rectInSelf: snapshotRect)
            ?? NSWorkspace.shared.icon(forFile: urls[0].path)

        var draggingItems: [NSDraggingItem] = []
        for (index, url) in urls.enumerated() {
            // File promise lets the destination construct the destination URL
            // (with collision handling) and ask us to write the file there.
            // Critically, destinations honor pathExtension correctly even for
            // unregistered UTIs (e.g. .cube), so collisions become "name 2.cube"
            // rather than "name.cube 2".
            //
            // We also vend `public.file-url` directly (via FileURLPromiseProvider)
            // so that non-Finder destinations — browsers, web upload zones, and
            // most native apps — can read the source URL straight off the
            // pasteboard. Without this, only Finder honors the drag.
            let typeID = (try? url.resourceValues(forKeys: [.contentTypeKey])
                .contentType?.identifier) ?? UTType.data.identifier
            let promise = FileURLPromiseProvider(fileType: typeID, delegate: self)
            promise.userInfo = url
            let item = NSDraggingItem(pasteboardWriter: promise)
            let off = CGFloat(index) * 4
            let frame = NSRect(
                x: snapshotRect.minX + off,
                y: snapshotRect.minY - off,
                width: snapshotRect.width,
                height: snapshotRect.height
            )
            item.setDraggingFrame(frame, contents: dragImage)
            draggingItems.append(item)
        }

        sessionActive = true
        onStart?()
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .stack
    }

    /// Renders the underlying SwiftUI tile (everything beneath this transparent
    /// overlay) into a bitmap so the drag preview matches the visible UI
    /// instead of a generic file icon.
    private func snapshotTile(rectInSelf: NSRect) -> NSImage? {
        guard let window = window,
              let rootLayer = window.contentView?.layer
        else { return nil }
        guard rectInSelf.width > 0, rectInSelf.height > 0 else { return nil }

        let scale = window.backingScaleFactor
        let pixelW = Int(ceil(rectInSelf.width * scale))
        let pixelH = Int(ceil(rectInSelf.height * scale))
        guard pixelW > 0, pixelH > 0 else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.scaleBy(x: scale, y: scale)

        // Translate so the snapshot rect's origin (in window coords) becomes (0,0).
        let rectInWindow = convert(rectInSelf, to: nil)
        ctx.translateBy(x: -rectInWindow.minX, y: -rectInWindow.minY)

        rootLayer.render(in: ctx)

        guard let cgImage = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: rectInSelf.size)
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

/// NSFilePromiseProvider that *also* writes `public.file-url` to the pasteboard.
/// Browsers and most web drop zones read the file URL directly rather than
/// honoring file promises, so without this they ignore the drag.
final class FileURLPromiseProvider: NSFilePromiseProvider {
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        types.append(.fileURL)
        return types
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .fileURL, let url = userInfo as? URL {
            return (url as NSURL).pasteboardPropertyList(forType: .fileURL)
        }
        return super.pasteboardPropertyList(forType: type)
    }

    override func writingOptions(
        forType type: NSPasteboard.PasteboardType,
        pasteboard: NSPasteboard
    ) -> NSPasteboard.WritingOptions {
        if type == .fileURL { return [] }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }
}
