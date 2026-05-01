import XCTest
import UniformTypeIdentifiers
@testable import ShelfDemo

final class ConversionTargetTests: XCTestCase {
    func test_heic_offers_jpeg_and_png() {
        XCTAssertEqual(
            ConversionTarget.supportedImageTargets(for: UTType.heic),
            [.jpeg, .png]
        )
    }

    func test_png_offers_jpeg_only() {
        XCTAssertEqual(
            ConversionTarget.supportedImageTargets(for: UTType.png),
            [.jpeg]
        )
    }

    func test_jpeg_offers_png_only() {
        XCTAssertEqual(
            ConversionTarget.supportedImageTargets(for: UTType.jpeg),
            [.png]
        )
    }

    func test_tiff_offers_jpeg_and_png() {
        XCTAssertEqual(
            ConversionTarget.supportedImageTargets(for: UTType.tiff),
            [.jpeg, .png]
        )
    }

    func test_webp_offers_jpeg_and_png() {
        XCTAssertEqual(
            ConversionTarget.supportedImageTargets(for: UTType.webP),
            [.jpeg, .png]
        )
    }

    func test_unknown_uti_offers_nothing() {
        XCTAssertEqual(
            ConversionTarget.supportedImageTargets(for: UTType.plainText),
            []
        )
    }

    func test_video_uti_offers_mp4_via_video_helper() {
        XCTAssertTrue(ConversionTarget.isVideoSourceUTI(UTType.quickTimeMovie))
        XCTAssertTrue(ConversionTarget.isVideoSourceUTI(UTType.mpeg4Movie))
        XCTAssertFalse(ConversionTarget.isVideoSourceUTI(UTType.png))
    }

    func test_intersection_of_targets_across_selection() {
        // 3 HEICs + 1 PNG → only JPEG is in everyone's target list.
        let utis: [UTType] = [.heic, .heic, .heic, .png]
        XCTAssertEqual(
            ConversionTarget.commonImageTargets(forSourceUTIs: utis),
            [.jpeg]
        )
    }

    func test_intersection_empty_when_no_overlap() {
        // PNG offers JPEG; JPEG offers PNG. Intersection is empty.
        XCTAssertEqual(
            ConversionTarget.commonImageTargets(forSourceUTIs: [.png, .jpeg]),
            []
        )
    }

    func test_displayName() {
        XCTAssertEqual(ConversionTarget.jpeg.displayName, "JPEG")
        XCTAssertEqual(ConversionTarget.png.displayName, "PNG")
        XCTAssertEqual(ConversionTarget.mp4.displayName, "MP4")
    }

    func test_fileExtension() {
        XCTAssertEqual(ConversionTarget.jpeg.fileExtension, "jpg")
        XCTAssertEqual(ConversionTarget.png.fileExtension, "png")
        XCTAssertEqual(ConversionTarget.mp4.fileExtension, "mp4")
    }
}
