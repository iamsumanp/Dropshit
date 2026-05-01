import XCTest
import AppKit
@testable import ShelfDemo

final class PDFEditModelTests: XCTestCase {
    private func makeEdit(replacement: String = "new") -> PDFTextEdit {
        return PDFTextEdit(
            id: UUID(),
            pageIndex: 0,
            lineRects: [CGRect(x: 10, y: 10, width: 80, height: 12)],
            replacement: replacement,
            font: NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12),
            color: .black,
            backgroundColor: .white
        )
    }

    func test_emptyDocument_has_no_edits() {
        let doc = PDFEditDocument()
        XCTAssertEqual(doc.edits.count, 0)
    }

    func test_addEdit_appends() {
        var doc = PDFEditDocument()
        doc.addEdit(makeEdit())
        XCTAssertEqual(doc.edits.count, 1)
    }

    func test_removeEdit_byID_removes_only_that_edit() {
        var doc = PDFEditDocument()
        let a = makeEdit(replacement: "A")
        let b = makeEdit(replacement: "B")
        doc.addEdit(a)
        doc.addEdit(b)
        doc.removeEdit(id: a.id)
        XCTAssertEqual(doc.edits.count, 1)
        XCTAssertEqual(doc.edits.first?.replacement, "B")
    }

    func test_removeEdit_unknownID_is_noop() {
        var doc = PDFEditDocument()
        doc.addEdit(makeEdit())
        doc.removeEdit(id: UUID())
        XCTAssertEqual(doc.edits.count, 1)
    }

    func test_isSavable_false_when_no_edits() {
        XCTAssertFalse(PDFEditDocument().isSavable)
    }

    func test_isSavable_true_when_at_least_one_edit() {
        var doc = PDFEditDocument()
        doc.addEdit(makeEdit())
        XCTAssertTrue(doc.isSavable)
    }
}
