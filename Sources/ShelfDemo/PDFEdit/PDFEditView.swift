import AppKit
import SwiftUI
import PDFKit

/// SwiftUI wrapper around `PDFView` for the editor. Exposes:
///   - the current `PDFEditDocument` as a binding (single source of truth
///     in the parent SwiftUI hierarchy)
///   - a "selection" popover trigger that surfaces when the user drags-to-
///     select text
///
/// Keeps PDFKit annotations on the view in sync with `editDocument.edits`.
struct PDFEditView: NSViewRepresentable {
    let document: PDFDocument
    @Binding var editDocument: PDFEditDocument

    /// Called when the user has a non-empty selection that's confined to a
    /// single page. The closure returns true when an edit was created (so
    /// the view can clear the selection); false otherwise (the user
    /// dismissed the popover).
    var onSelection: (PDFSelection) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.delegate = context.coordinator

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.selectionChanged),
            name: .PDFViewSelectionChanged,
            object: pdfView
        )
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        // Reconcile annotations against `editDocument.edits`. We tag our
        // annotations with a marker in `userName` so we never touch
        // annotations belonging to the source document.
        guard let pdfDoc = pdfView.document else { return }

        // Collect known edit IDs.
        let liveIDs = Set(editDocument.edits.map(\.id.uuidString))

        for pageIndex in 0..<pdfDoc.pageCount {
            guard let page = pdfDoc.page(at: pageIndex) else { continue }

            // 1. Remove our annotations whose IDs aren't in the live set.
            for annotation in page.annotations {
                guard let marker = annotation.userName,
                      marker.hasPrefix("PDFTextEdit:") else { continue }
                let editID = String(marker.dropFirst("PDFTextEdit:".count)).components(separatedBy: ":").first ?? ""
                if !liveIDs.contains(editID) {
                    page.removeAnnotation(annotation)
                }
            }

            // 2. Add annotations for edits that belong to this page and
            //    aren't already drawn.
            let existingIDs = Set(
                page.annotations.compactMap { ann -> String? in
                    guard let marker = ann.userName,
                          marker.hasPrefix("PDFTextEdit:") else { return nil }
                    return marker.components(separatedBy: ":").dropFirst().first
                }
            )
            for edit in editDocument.edits where edit.pageIndex == pageIndex {
                if existingIDs.contains(edit.id.uuidString) { continue }
                addAnnotations(for: edit, on: page)
            }
        }
    }

    private func addAnnotations(for edit: PDFTextEdit, on page: PDFPage) {
        // One square cover per line.
        for (i, lineRect) in edit.lineRects.enumerated() {
            let cover = PDFAnnotation(
                bounds: lineRect,
                forType: .square,
                withProperties: nil
            )
            cover.color = edit.backgroundColor
            cover.interiorColor = edit.backgroundColor
            cover.border = nil
            cover.userName = "PDFTextEdit:\(edit.id.uuidString):\(i)"
            page.addAnnotation(cover)
        }

        // One free-text annotation spanning the union of line rects.
        let union = edit.lineRects.reduce(CGRect.null) { $0.union($1) }
        if !union.isNull, !edit.replacement.isEmpty {
            let textAnnotation = PDFAnnotation(
                bounds: union,
                forType: .freeText,
                withProperties: nil
            )
            textAnnotation.contents = edit.replacement
            textAnnotation.font = edit.font
            textAnnotation.fontColor = edit.color
            textAnnotation.color = .clear
            textAnnotation.userName = "PDFTextEdit:\(edit.id.uuidString):text"
            page.addAnnotation(textAnnotation)
        }
    }

    final class Coordinator: NSObject, PDFViewDelegate {
        let parent: PDFEditView
        init(parent: PDFEditView) { self.parent = parent }

        @objc func selectionChanged(_ note: Notification) {
            guard let pdfView = note.object as? PDFView,
                  let selection = pdfView.currentSelection,
                  let selStr = selection.string, !selStr.isEmpty else { return }
            // Only single-page selections are valid for replacement.
            guard selection.pages.count == 1 else { return }
            parent.onSelection(selection)
        }
    }
}
