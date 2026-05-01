import AppKit
import Foundation

/// One pending text replacement on a PDF page. `lineRects` is one rect per
/// line of the original selection (a single-line selection has one rect; a
/// selection that spans line wraps has multiple). All rects are in the
/// page's PDF user space (origin bottom-left, units = points).
struct PDFTextEdit: Identifiable, Equatable {
    let id: UUID
    let pageIndex: Int
    let lineRects: [CGRect]
    let replacement: String
    let font: NSFont
    let color: NSColor
    let backgroundColor: NSColor
}

/// Container of pending edits. Value type — view models hold a copy and
/// pass it to the flatten step on save.
struct PDFEditDocument: Equatable {
    private(set) var edits: [PDFTextEdit] = []

    var isSavable: Bool { !edits.isEmpty }

    mutating func addEdit(_ edit: PDFTextEdit) {
        edits.append(edit)
    }

    mutating func removeEdit(id: UUID) {
        edits.removeAll { $0.id == id }
    }
}
