import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A transparent drop destination that returns `.generic` from the dragging
/// destination protocol so the system never paints the green "+" copy badge
/// on the cursor. SwiftUI's `.onDrop(...)` paints the badge unconditionally
/// (it routes drops as `.copy`), and `DropDelegate` only exposes
/// `.copy / .move / .cancel / .forbidden` — none of which suppress the
/// indicator while still accepting the drop. Going through AppKit directly
/// is the only path that keeps the cursor clean.
///
/// `hitTest:` returns nil so this overlay never claims mouse clicks: drag
/// destination dispatch in AppKit is driven by `registerForDraggedTypes` plus
/// frame containment, not by hit testing, so SwiftUI buttons underneath still
/// receive their clicks normally.
struct ShelfDropTarget: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let allowDrop: () -> Bool
    let onDrop: (NSPasteboard) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ShelfDropView {
        let view = ShelfDropView()
        let coordinator = context.coordinator
        view.allowDrop = { coordinator.parent.allowDrop() }
        view.onTargetedChange = { value in coordinator.setTargeted(value) }
        view.onPerformDrop = { pb in coordinator.parent.onDrop(pb) }
        return view
    }

    func updateNSView(_ nsView: ShelfDropView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator {
        var parent: ShelfDropTarget

        init(parent: ShelfDropTarget) {
            self.parent = parent
        }

        func setTargeted(_ value: Bool) {
            // Hop to the next runloop tick so we never write to a SwiftUI
            // binding mid-update.
            let binding = parent.$isTargeted
            DispatchQueue.main.async {
                if binding.wrappedValue != value {
                    binding.wrappedValue = value
                }
            }
        }
    }
}

final class ShelfDropView: NSView {
    var allowDrop: () -> Bool = { true }
    var onTargetedChange: ((Bool) -> Void)?
    var onPerformDrop: ((NSPasteboard) -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // File promises let apps like Mail / Photos vend an attachment without
        // it existing as a real file at drag-start time, so include their
        // readable types alongside the direct file/text/image identifiers.
        var types: [NSPasteboard.PasteboardType] = [
            .fileURL,
            .URL,
            .tiff,
            .png,
            .string,
        ]
        types.append(contentsOf:
            NSFilePromiseReceiver.readableDraggedTypes
                .map(NSPasteboard.PasteboardType.init(rawValue:))
        )
        registerForDraggedTypes(types)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    /// Drag destination dispatch goes through `registerForDraggedTypes` and
    /// frame containment, not `hitTest:` — so returning nil here keeps the
    /// overlay invisible to mouse clicks (they pass through to SwiftUI
    /// buttons below) while drag events still fire on us.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard allowDrop() else { return [] }
        onTargetedChange?(true)
        return .generic
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard allowDrop() else { return [] }
        return .generic
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetedChange?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargetedChange?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let result = onPerformDrop?(sender.draggingPasteboard) ?? false
        onTargetedChange?(false)
        return result
    }
}
