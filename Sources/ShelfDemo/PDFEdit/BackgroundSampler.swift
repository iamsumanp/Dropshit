import AppKit
import CoreGraphics

/// Returns the average color of a 2-pixel-wide perimeter around `rect` in
/// `image`. Used to pick a fill color for the rectangle that covers the
/// original text — the perimeter is what surrounds the text, so it's a good
/// approximation of the page's local background.
enum BackgroundSampler {
    private static let perimeterWidth: CGFloat = 2

    static func sample(from image: CGImage, inRect rect: CGRect) -> NSColor {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let outer = rect.insetBy(dx: -perimeterWidth, dy: -perimeterWidth)
            .intersection(imageBounds)
        guard !outer.isEmpty else { return .white }

        let cs = CGColorSpaceCreateDeviceRGB()
        let width = Int(outer.width)
        let height = Int(outer.height)
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .white }

        ctx.draw(image, in: CGRect(
            x: -outer.origin.x,
            y: -outer.origin.y,
            width: imageBounds.width,
            height: imageBounds.height
        ))

        let interior = rect.offsetBy(dx: -outer.origin.x, dy: -outer.origin.y)
        var rTotal: UInt64 = 0
        var gTotal: UInt64 = 0
        var bTotal: UInt64 = 0
        var count: UInt64 = 0
        for y in 0..<height {
            for x in 0..<width {
                let p = CGPoint(x: CGFloat(x), y: CGFloat(y))
                if interior.contains(p) { continue }
                let i = (y * bytesPerRow) + (x * 4)
                rTotal += UInt64(buffer[i])
                gTotal += UInt64(buffer[i + 1])
                bTotal += UInt64(buffer[i + 2])
                count += 1
            }
        }
        guard count > 0 else { return .white }
        let r = CGFloat(rTotal) / CGFloat(count) / 255.0
        let g = CGFloat(gTotal) / CGFloat(count) / 255.0
        let b = CGFloat(bTotal) / CGFloat(count) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
