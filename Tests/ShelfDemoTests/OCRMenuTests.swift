import XCTest
import UniformTypeIdentifiers
@testable import ShelfDemo

final class OCRMenuTests: XCTestCase {
    func test_makeSearchable_offered_for_pdfs_only() {
        XCTAssertTrue(OCRMenu.shouldOfferMakeSearchable(forSourceUTIs: [UTType.pdf]))
        XCTAssertTrue(OCRMenu.shouldOfferMakeSearchable(forSourceUTIs: [.pdf, .pdf]))
    }

    func test_makeSearchable_not_offered_for_images() {
        XCTAssertFalse(OCRMenu.shouldOfferMakeSearchable(forSourceUTIs: [.png]))
        XCTAssertFalse(OCRMenu.shouldOfferMakeSearchable(forSourceUTIs: [.heic]))
    }

    func test_makeSearchable_not_offered_for_mixed() {
        XCTAssertFalse(
            OCRMenu.shouldOfferMakeSearchable(forSourceUTIs: [.pdf, .png])
        )
    }

    func test_makeSearchable_not_offered_for_empty() {
        XCTAssertFalse(OCRMenu.shouldOfferMakeSearchable(forSourceUTIs: []))
    }

    func test_extractText_offered_for_pdfs() {
        XCTAssertTrue(OCRMenu.shouldOfferExtractText(forSourceUTIs: [.pdf]))
    }

    func test_extractText_offered_for_images() {
        XCTAssertTrue(OCRMenu.shouldOfferExtractText(forSourceUTIs: [.png]))
        XCTAssertTrue(OCRMenu.shouldOfferExtractText(forSourceUTIs: [.heic, .jpeg]))
    }

    func test_extractText_offered_for_mixed_pdf_image() {
        // Both PDFs and images are valid for Extract Text, so any mix works.
        XCTAssertTrue(
            OCRMenu.shouldOfferExtractText(forSourceUTIs: [.pdf, .png, .heic])
        )
    }

    func test_extractText_not_offered_for_unsupported_uti() {
        XCTAssertFalse(OCRMenu.shouldOfferExtractText(forSourceUTIs: [.plainText]))
    }

    func test_extractText_not_offered_for_mixed_with_unsupported() {
        XCTAssertFalse(
            OCRMenu.shouldOfferExtractText(forSourceUTIs: [.pdf, .plainText])
        )
    }

    func test_extractText_not_offered_for_empty() {
        XCTAssertFalse(OCRMenu.shouldOfferExtractText(forSourceUTIs: []))
    }
}
