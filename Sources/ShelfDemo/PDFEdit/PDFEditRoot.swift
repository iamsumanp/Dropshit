import AppKit
import SwiftUI
import PDFKit

/// Root view of the PDF editor window. Owns the in-progress
/// `PDFEditDocument` and drives the selection-to-popover flow.
struct PDFEditRoot: View {
    let pdfDocument: PDFDocument
    let sourceURL: URL
    let shelfID: UUID

    /// AppDelegate-injected service used to flatten on Save.
    @EnvironmentObject private var pdfEditService: PDFEditService

    /// Called when the editor should close (Cancel or Save-completed).
    var onClose: () -> Void = {}

    @State private var editDocument = PDFEditDocument()
    @State private var pendingSelection: PDFSelection?
    @State private var replacementText: String = ""
    @State private var saveInFlight = false
    @State private var lastSaveID: UUID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            PDFEditView(
                document: pdfDocument,
                editDocument: $editDocument,
                onSelection: { selection in
                    pendingSelection = selection
                }
            )
            Divider()
            footer
        }
        .sheet(isPresented: pendingSelectionBinding) {
            replacementPopover
        }
        .onReceive(pdfEditService.completed) { (url, _) in
            saveInFlight = false
            onClose()
        }
        .onReceive(pdfEditService.failed) { _ in
            saveInFlight = false
            // Toast is shown by AppDelegate; we just leave the editor open.
        }
    }

    private var pendingSelectionBinding: Binding<Bool> {
        Binding(
            get: { pendingSelection != nil },
            set: { newValue in
                if !newValue { pendingSelection = nil }
            }
        )
    }

    private var toolbar: some View {
        HStack {
            Button("Cancel") { onClose() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Text("\(editDocument.edits.count) edit\(editDocument.edits.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
                .font(.caption)
            Spacer()
            Button("Save Edits") {
                save()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!editDocument.isSavable || saveInFlight)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        Group {
            if saveInFlight {
                ProgressView(value: pdfEditService.progress[lastSaveID] ?? 0, total: 1)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            } else {
                Text("Drag-select text to replace it. Press Delete on an edit annotation to remove it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var replacementPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Replace selected text with:")
                .font(.headline)
            TextField("Replacement", text: $replacementText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
            HStack {
                Button("Cancel") {
                    pendingSelection = nil
                    replacementText = ""
                }
                Spacer()
                Button("Replace") {
                    commitPendingSelection()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func commitPendingSelection() {
        defer {
            pendingSelection = nil
            replacementText = ""
        }
        guard let selection = pendingSelection,
              let page = selection.pages.first,
              let pdf = pdfDocument.page(at: 0) != nil ? pdfDocument : nil
        else { return }
        let pageIndex = pdf.index(for: page)
        let lineRects = selection.selectionsByLine().compactMap { sub -> CGRect? in
            guard let p = sub.pages.first else { return nil }
            return sub.bounds(for: p)
        }
        guard !lineRects.isEmpty else { return }

        let attributed = selection.attributedString
        let attrs = attributed?.attributes(at: 0, effectiveRange: nil) ?? [:]
        let font = (attrs[NSAttributedString.Key.font] as? NSFont)
            ?? NSFont(name: "Helvetica", size: 12)
            ?? .systemFont(ofSize: 12)
        let color = (attrs[NSAttributedString.Key.foregroundColor] as? NSColor) ?? .black

        // Background sample: render the page to a CGImage at on-screen DPI
        // and sample the perimeter of the union rect.
        let union = lineRects.reduce(CGRect.null) { $0.union($1) }
        let backgroundColor = sampleBackground(page: page, union: union)

        let edit = PDFTextEdit(
            id: UUID(),
            pageIndex: pageIndex,
            lineRects: lineRects,
            replacement: replacementText,
            font: font,
            color: color,
            backgroundColor: backgroundColor
        )
        editDocument.addEdit(edit)
    }

    private func sampleBackground(page: PDFPage, union: CGRect) -> NSColor {
        let bounds = page.bounds(for: .mediaBox)
        let scale = PDFEditFlatten.renderScale
        let pixelWidth = Int(ceil(bounds.width * scale))
        let pixelHeight = Int(ceil(bounds.height * scale))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .white }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        guard let image = ctx.makeImage() else { return .white }

        let imageRect = CGRect(
            x: union.origin.x * scale,
            y: union.origin.y * scale,
            width: union.width * scale,
            height: union.height * scale
        )
        return BackgroundSampler.sample(from: image, inRect: imageRect)
    }

    private func save() {
        let id = UUID()
        lastSaveID = id
        saveInFlight = true
        pdfEditService.enqueueSave(
            saveID: id,
            shelfID: shelfID,
            source: sourceURL,
            edits: editDocument
        )
    }
}
