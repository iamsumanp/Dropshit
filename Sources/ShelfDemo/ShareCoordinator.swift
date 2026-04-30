import AppKit

/// Hosts the NSSharingServicePicker so its delegate outlives the menu invocation.
@MainActor
final class ShareCoordinator: NSObject, NSSharingServicePickerDelegate {
    static let shared = ShareCoordinator()

    private var activePicker: NSSharingServicePicker?

    func share(item: ShelfItem) {
        var shareItems: [Any] = []
        if let url = item.fileURL, FileManager.default.fileExists(atPath: url.path) {
            shareItems.append(url)
        }
        if let text = item.textContent, !text.isEmpty {
            shareItems.append(text)
        }
        guard !shareItems.isEmpty else { return }

        let picker = NSSharingServicePicker(items: shareItems)
        picker.delegate = self
        self.activePicker = picker

        // Anchor to the shelf panel's content view (the currently key window).
        if let window = NSApp.keyWindow ?? NSApp.orderedWindows.first(where: { $0.isVisible }),
           let view = window.contentView {
            let anchor = NSRect(x: view.bounds.midX, y: 0, width: 1, height: 1)
            picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        }
    }

    // MARK: - NSSharingServicePickerDelegate

    nonisolated func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        Task { @MainActor in
            self.activePicker = nil
        }
    }
}
