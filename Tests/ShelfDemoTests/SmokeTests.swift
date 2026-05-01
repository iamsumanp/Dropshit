import XCTest
@testable import ShelfDemo

final class SmokeTests: XCTestCase {
    func test_smoke_canImportModule() {
        // If this compiles and runs, @testable import works against the
        // executable target. Concrete tests follow in later tasks.
        XCTAssertEqual(1 + 1, 2)
    }
}
