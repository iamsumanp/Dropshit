#!/usr/bin/env swift
// Generates an `.iconset` directory of PNGs for the Dropshit app.
// Pipe into `iconutil -c icns -o AppIcon.icns AppIcon.iconset/` to produce
// the final .icns. Each rendition is drawn fresh at the exact pixel size
// (rather than scaled from a master PNG) so strokes stay crisp at 16px.

import AppKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    print("usage: make-icon.swift <output-iconset-dir>")
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// macOS icon size table. Each entry is (filename, pixel size).
let renditions: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func drawIcon(into ctx: CGContext, pixels: Int) {
    let p = CGFloat(pixels)
    let rect = CGRect(x: 0, y: 0, width: p, height: p)

    // ── Squircle background (the rounded-rect "tile" macOS icons sit in).
    // 22% corner radius is the canonical macOS app-icon shape.
    let cornerRadius = p * 0.22
    let bg = CGPath(roundedRect: rect, cornerWidth: cornerRadius,
                    cornerHeight: cornerRadius, transform: nil)
    ctx.saveGState()
    ctx.addPath(bg)
    ctx.clip()

    // Vertical gradient: charcoal at top → near-black at bottom.
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        CGColor(srgbRed: 0.18, green: 0.20, blue: 0.24, alpha: 1.0),
        CGColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1.0),
    ] as CFArray
    let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors,
                                locations: [0, 1])!
    ctx.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: 0, y: p),
        end: CGPoint(x: 0, y: 0),
        options: []
    )

    // Subtle inner highlight at the top — gives a hint of depth without
    // looking glassy. Kept faint so the icon reads as flat from a distance.
    let highlightColors = [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray
    let highlight = CGGradient(colorsSpace: colorSpace, colors: highlightColors,
                               locations: [0, 1])!
    ctx.drawLinearGradient(
        highlight,
        start: CGPoint(x: 0, y: p),
        end: CGPoint(x: 0, y: p * 0.55),
        options: []
    )
    ctx.restoreGState()

    // ── Outline + dot motif (echoes the menubar glyph).
    let glyphInset = p * 0.22
    let glyphRect = rect.insetBy(dx: glyphInset, dy: glyphInset)
    let glyphCorner = p * 0.085
    let strokeWidth = max(p * 0.022, 1.5)

    let glyphPath = CGPath(roundedRect: glyphRect, cornerWidth: glyphCorner,
                           cornerHeight: glyphCorner, transform: nil)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))
    ctx.setLineWidth(strokeWidth)
    ctx.addPath(glyphPath)
    ctx.strokePath()

    // Accent dot — sits fully inside the rounded square, top-right.
    let dotInset = p * 0.045
    let dotSize = p * 0.105
    let dotRect = CGRect(
        x: glyphRect.maxX - dotInset - dotSize,
        y: glyphRect.maxY - dotInset - dotSize,
        width: dotSize, height: dotSize
    )
    ctx.setFillColor(CGColor(srgbRed: 0.30, green: 0.62, blue: 1.0, alpha: 1.0))
    ctx.fillEllipse(in: dotRect)
}

func writePNG(pixels: Int, to url: URL) {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        FileHandle.standardError.write("Failed to make context for \(pixels)\n".data(using: .utf8)!)
        return
    }
    drawIcon(into: ctx, pixels: pixels)
    guard let cgImage = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: pixels, height: pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
}

for (name, pixels) in renditions {
    writePNG(pixels: pixels, to: outDir.appendingPathComponent(name))
    print("• wrote \(name) (\(pixels)px)")
}
