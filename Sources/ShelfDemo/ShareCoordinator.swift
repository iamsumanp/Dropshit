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
        sharingServicesForItems items: [Any],
        proposedSharingServices proposedServices: [NSSharingService]
    ) -> [NSSharingService] {
        var services = proposedServices

        let icon = NSImage(systemSymbolName: "link", accessibilityDescription: "Share link")
            ?? NSImage()
        let copyLink = NSSharingService(
            title: "Copy Shareable Link",
            image: icon,
            alternateImage: nil,
            handler: {
                let token = UUID().uuidString.prefix(10).lowercased()
                let link = "https://shelf.local/s/\(token)"
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([link as NSString])
            }
        )
        services.insert(copyLink, at: 0)
        return services
    }

    nonisolated func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        Task { @MainActor in
            self.activePicker = nil
        }
    }
}
