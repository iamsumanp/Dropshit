import AppKit
import SwiftUI
import PDFKit

/// Wraps the SwiftUI PDFEditRoot in an NSWindow. Created lazily by
/// AppDelegate, brought to front on each invocation, never released
/// (closed-but-retained for re-use).
@MainActor
final class PDFEditWindow {
    private(set) var window: NSWindow?
    private weak var pdfEditService: PDFEditService?

    init(pdfEditService: PDFEditService) {
        self.pdfEditService = pdfEditService
    }

    /// Open the editor for `sourceURL`. If a window is already open, this
    /// brings it to front (regardless of which document it's showing —
    /// users must save/cancel that one first).
    func open(sourceURL: URL, shelfID: UUID) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let pdfDoc = PDFDocument(url: sourceURL) else { return }

        let root = PDFEditRoot(
            pdfDocument: pdfDoc,
            sourceURL: sourceURL,
            shelfID: shelfID,
            onClose: { [weak self] in
                self?.close()
            }
        )
        .environmentObject(pdfEditService ?? PDFEditService())

        let hosting = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Replace Text — \(sourceURL.lastPathComponent)"
        win.styleMask = [.titled, .closable, .resizable]
        win.setContentSize(NSSize(width: 900, height: 700))
        win.center()
        win.isReleasedWhenClosed = false

        self.window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}
