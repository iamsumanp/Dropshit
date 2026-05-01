import XCTest
@testable import ShelfDemo

final class UniqueDestinationTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniqueDestTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_returns_input_when_no_collision() {
        let candidate = tempDir.appendingPathComponent("foo.jpg")
        XCTAssertEqual(
            UniqueDestination.url(preferred: candidate),
            candidate
        )
    }

    func test_appends_1_when_first_taken() throws {
        let taken = tempDir.appendingPathComponent("foo.jpg")
        try Data().write(to: taken)
        XCTAssertEqual(
            UniqueDestination.url(preferred: taken),
            tempDir.appendingPathComponent("foo (1).jpg")
        )
    }

    func test_increments_until_free() throws {
        for suffix in ["foo.jpg", "foo (1).jpg", "foo (2).jpg"] {
            try Data().write(to: tempDir.appendingPathComponent(suffix))
        }
        let preferred = tempDir.appendingPathComponent("foo.jpg")
        XCTAssertEqual(
            UniqueDestination.url(preferred: preferred),
            tempDir.appendingPathComponent("foo (3).jpg")
        )
    }

    func test_handles_files_with_no_extension() throws {
        let taken = tempDir.appendingPathComponent("README")
        try Data().write(to: taken)
        XCTAssertEqual(
            UniqueDestination.url(preferred: taken),
            tempDir.appendingPathComponent("README (1)")
        )
    }
}
