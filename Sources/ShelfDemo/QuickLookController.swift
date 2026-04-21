import AppKit
import Quartz

final class QuickLookController: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    /// Supplies the list of URLs to preview at the moment Quick Look opens.
    var urlsProvider: (() -> [URL])?

    private var currentURLs: [URL] = []
    private var pendingStartIndex: Int?

    override init() { super.init() }
    required init?(coder: NSCoder) { nil }

    func show(startingAt index: Int? = nil) {
        guard let panel = QLPreviewPanel.shared() else { return }
        pendingStartIndex = index
        if panel.isVisible {
            reload(panel: panel, preferredStart: index)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func toggle(startingAt index: Int? = nil) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            show(startingAt: index)
        }
    }

    private func reload(panel: QLPreviewPanel, preferredStart: Int?) {
        currentURLs = (urlsProvider?() ?? []).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        panel.reloadData()
        if !currentURLs.isEmpty {
            let target = preferredStart ?? panel.currentPreviewItemIndex
            panel.currentPreviewItemIndex = max(0, min(target, currentURLs.count - 1))
        }
    }

    // MARK: - Space-bar handling

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 {
            let urls = urlsProvider?() ?? []
            let start = max(0, urls.count - 1)
            toggle(startingAt: start)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - QLPreviewPanelController

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        currentURLs = (urlsProvider?() ?? []).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        panel.delegate = self
        panel.dataSource = self
        if let start = pendingStartIndex, !currentURLs.isEmpty {
            panel.currentPreviewItemIndex = max(0, min(start, currentURLs.count - 1))
        }
        pendingStartIndex = nil
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.delegate = nil
        panel.dataSource = nil
        currentURLs = []
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        currentURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index >= 0 && index < currentURLs.count else { return nil }
        return currentURLs[index] as NSURL
    }
}
