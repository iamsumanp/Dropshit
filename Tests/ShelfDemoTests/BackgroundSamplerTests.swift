import XCTest
import AppKit
import CoreGraphics
@testable import ShelfDemo

final class BackgroundSamplerTests: XCTestCase {
    private func makeSolidImage(color: NSColor) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: 100, height: 100,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        return ctx.makeImage()!
    }

    func test_solid_white_returns_white() {
        let image = makeSolidImage(color: .white)
        let sample = BackgroundSampler.sample(
            from: image,
            inRect: CGRect(x: 30, y: 30, width: 40, height: 40)
        )
        let rgb = sample.usingColorSpace(.sRGB)!
        XCTAssertEqual(rgb.redComponent, 1.0, accuracy: 0.02)
        XCTAssertEqual(rgb.greenComponent, 1.0, accuracy: 0.02)
        XCTAssertEqual(rgb.blueComponent, 1.0, accuracy: 0.02)
    }

    func test_solid_black_returns_black() {
        let image = makeSolidImage(color: .black)
        let sample = BackgroundSampler.sample(
            from: image,
            inRect: CGRect(x: 30, y: 30, width: 40, height: 40)
        )
        let rgb = sample.usingColorSpace(.sRGB)!
        XCTAssertEqual(rgb.redComponent, 0.0, accuracy: 0.02)
        XCTAssertEqual(rgb.greenComponent, 0.0, accuracy: 0.02)
        XCTAssertEqual(rgb.blueComponent, 0.0, accuracy: 0.02)
    }

    func test_perimeter_extends_slightly_beyond_rect() {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: 100, height: 100,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 45, y: 45, width: 10, height: 10))
        let image = ctx.makeImage()!

        let sample = BackgroundSampler.sample(
            from: image,
            inRect: CGRect(x: 45, y: 45, width: 10, height: 10)
        )
        let rgb = sample.usingColorSpace(.sRGB)!
        XCTAssertGreaterThan(rgb.whiteComponent, 0.95)
    }
}
