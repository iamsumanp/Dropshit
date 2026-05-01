# PDF Text Replace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `Replace Text…` action to the right-click menu on PDF shelf items that opens a small editor window. Inside, the user selects text, types a replacement, and confirms; the result is rendered live as overlay annotations. **Save Edits** flattens every replacement into a sibling PDF (`<stem> (edited).pdf`) so the new text is selectable/searchable and the original is no longer present as text content.

**Architecture:** A new `PDFEdit/` module mirrors the shape of `Conversion/` and `OCR/`: pure data types (`PDFTextEdit`, `PDFEditDocument`), a flatten implementation (`PDFEditFlatten`) that reuses the rebuild pipeline from `PDFOCR.makeSearchable`, a `PDFEditService` (`@MainActor ObservableObject`) that runs the save off the main thread, and a single editor window (`PDFEditWindow` + `PDFEditView`) hosting `PDFView` with selection-to-popover wiring. The editor uses PDFKit's annotation API (`square` + `freeText`) for live preview; the actual save renders each page to JPEG-0.9 at 150 DPI and draws the replacement text via CoreText so it remains selectable in the output.

**Tech Stack:** Swift 5.9, AppKit, SwiftUI, PDFKit (`PDFDocument`, `PDFView`, `PDFSelection`, `PDFAnnotation`), CoreGraphics PDF context, CoreText, Combine. macOS 13+.

**Spec:** `docs/superpowers/specs/2026-05-01-pdf-text-replace-design.md`

---

## Environment caveat

This machine has Command Line Tools only — no full Xcode means no XCTest module is available, so `swift test` cannot run. `swift build` works and is the only verification command. Test target `.swift` files are NOT compiled by `swift build` either, so test code is unverified locally; write it carefully because it will run the moment anyone with Xcode tries `swift test`.

When the plan says "run tests to verify they fail / pass", **skip those steps**. The verification step is `swift build`.

---

## File Structure

**New (production):**
- `Sources/ShelfDemo/PDFEdit/PDFEditError.swift` — error enum.
- `Sources/ShelfDemo/PDFEdit/PDFEditModel.swift` — `struct PDFTextEdit`, `struct PDFEditDocument` (mutable container of edits).
- `Sources/ShelfDemo/PDFEdit/BackgroundSampler.swift` — pure helper for sampling the perimeter background color.
- `Sources/ShelfDemo/PDFEdit/PDFEditFlatten.swift` — flattens edits into a new PDF using the rebuild pipeline. Reuses `UniqueDestination` from `Conversion/`.
- `Sources/ShelfDemo/PDFEdit/PDFEditService.swift` — `@MainActor ObservableObject`, queues saves, exposes Combine publishers.
- `Sources/ShelfDemo/PDFEdit/PDFEditView.swift` — `NSViewRepresentable` wrapping `PDFView` with selection→popover and annotation overlay logic.
- `Sources/ShelfDemo/PDFEdit/PDFEditWindow.swift` — `NSWindowController` hosting the SwiftUI root.
- `Sources/ShelfDemo/PDFEdit/PDFEditRoot.swift` — top-level SwiftUI `View` (toolbar + PDFEditView + footer).

**New (tests):**
- `Tests/ShelfDemoTests/PDFEditModelTests.swift` — `PDFEditDocument` mutation tests.
- `Tests/ShelfDemoTests/BackgroundSamplerTests.swift` — sampler tests using synthesized CGImages.

**Modified:**
- `Sources/ShelfDemo/ShelfContextMenu.swift` — add `weak var pdfEditService: PDFEditService?` to `ShelfItemActions`, add `@objc func replaceText(_:)`, insert `Replace Text…` menu item in `makeAllActionsMenu` (only when the item is a PDF with selectable text).
- `Sources/ShelfDemo/ShelfContainerView.swift` — propagate `pdfEditService` env-object; pass it to both `ShelfContextMenu.make(...)` call sites.
- `Sources/ShelfDemo/App.swift` — instantiate `PDFEditService`, subscribe to `completed` / `failed`, inject env object, `cancelAll()` on terminate.

---

## Task 1: PDFEditError enum

**Files:**
- Create: `Sources/ShelfDemo/PDFEdit/PDFEditError.swift`

(No tests — pure data type.)

- [ ] **Step 1: Implement the error enum**

Create `Sources/ShelfDemo/PDFEdit/PDFEditError.swift`:

```swift
import Foundation

enum PDFEditError: Error, Equatable {
    case sourceMissing
    case sourceUnreadable
    case destinationUnwritable
    case flattenFailed(reason: String)
    case cancelled

    var displayMessage: String {
        switch self {
        case .sourceMissing:
            return "PDF edit failed: source file no longer exists."
        case .sourceUnreadable:
            return "PDF edit failed: could not read the source."
        case .destinationUnwritable:
            return "PDF edit failed: could not write to disk."
        case .flattenFailed(let reason):
            return "PDF edit failed: \(reason)"
        case .cancelled:
            return "PDF edit cancelled."
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add Sources/ShelfDemo/PDFEdit/PDFEditError.swift
git commit -m "Add PDFEditError enum"
```

---

## Task 2: PDFEditModel — value types

**Files:**
- Create: `Sources/ShelfDemo/PDFEdit/PDFEditModel.swift`
- Create: `Tests/ShelfDemoTests/PDFEditModelTests.swift`

- [ ] **Step 1: Write the tests first**

Create `Tests/ShelfDemoTests/PDFEditModelTests.swift`:

```swift
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
```

- [ ] **Step 2: SKIP** (cannot run tests in this environment).

- [ ] **Step 3: Implement `PDFEditModel.swift`**

Create `Sources/ShelfDemo/PDFEdit/PDFEditModel.swift`:

```swift
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
```

- [ ] **Step 4: SKIP** (cannot run tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ShelfDemo/PDFEdit/PDFEditModel.swift Tests/ShelfDemoTests/PDFEditModelTests.swift
git commit -m "Add PDFEditModel — PDFTextEdit and PDFEditDocument value types"
```

---

## Task 3: BackgroundSampler

**Files:**
- Create: `Sources/ShelfDemo/PDFEdit/BackgroundSampler.swift`
- Create: `Tests/ShelfDemoTests/BackgroundSamplerTests.swift`

The sampler reads a small region of a rendered page image and returns the average color around the selection's perimeter — the assumption being that immediately around the text we're about to cover, the page's background color shows through.

- [ ] **Step 1: Write the tests first**

Create `Tests/ShelfDemoTests/BackgroundSamplerTests.swift`:

```swift
import XCTest
import AppKit
import CoreGraphics
@testable import ShelfDemo

final class BackgroundSamplerTests: XCTestCase {
    /// Build a 100×100 CGImage filled with a single color; sample inside it.
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
        // Allow some rounding slack on RGB.
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
        // Build a 100x100 image with a black 10x10 box in the middle and
        // white everywhere else. Sampling the rect of the black box must
        // see white because we sample the PERIMETER (outside the rect),
        // not the interior.
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
```

- [ ] **Step 2: SKIP** (cannot run tests).

- [ ] **Step 3: Implement `BackgroundSampler.swift`**

Create `Sources/ShelfDemo/PDFEdit/BackgroundSampler.swift`:

```swift
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

        // Build an RGBA buffer of `outer`. Average all pixels NOT inside
        // the original rect.
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

        // Draw the source image translated so that `outer.origin` aligns with (0,0).
        ctx.draw(image, in: CGRect(
            x: -outer.origin.x,
            y: -outer.origin.y,
            width: imageBounds.width,
            height: imageBounds.height
        ))

        // Loop over pixels, skipping interior of `rect` (translated into outer's frame).
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
```

- [ ] **Step 4: SKIP** (cannot run tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ShelfDemo/PDFEdit/BackgroundSampler.swift Tests/ShelfDemoTests/BackgroundSamplerTests.swift
git commit -m "Add BackgroundSampler — perimeter-average page background detection"
```

---

## Task 4: PDFEditFlatten — flattening to a new PDF

**Files:**
- Create: `Sources/ShelfDemo/PDFEdit/PDFEditFlatten.swift`

This is the heart of the save flow. Reuses the rebuild pipeline established by `PDFOCR.makeSearchable` — render each page to JPEG-0.9 at 150 DPI, draw rectangles + replacement text on top, write to a fresh `CGPDFContext`.

- [ ] **Step 1: Implement `PDFEditFlatten.swift`**

Create `Sources/ShelfDemo/PDFEdit/PDFEditFlatten.swift`:

```swift
import AppKit
import Foundation
import PDFKit
import CoreGraphics
import CoreText

enum PDFEditFlatten {
    static let renderDPI: CGFloat = 150
    static let renderScale: CGFloat = renderDPI / 72.0
    static let outputJPEGQuality: Double = 0.9

    /// Flatten `edits` into a new PDF beside `source`. Returns the URL of
    /// the new file. `progress(0...1)` is reported per page.
    static func flatten(
        source: URL,
        edits: PDFEditDocument,
        progress: @Sendable (Double) -> Void
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw PDFEditError.sourceMissing
        }
        guard let pdf = PDFDocument(url: source), pdf.pageCount > 0 else {
            throw PDFEditError.sourceUnreadable
        }

        let finalDest = try resolveDestination(for: source)
        let tempURL = finalDest
            .deletingPathExtension()
            .appendingPathExtension("part\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("pdf")

        guard let consumer = CGDataConsumer(url: tempURL as CFURL) else {
            throw PDFEditError.destinationUnwritable
        }
        var emptyBox = CGRect.zero
        guard let writeContext = CGContext(consumer: consumer, mediaBox: &emptyBox, nil) else {
            throw PDFEditError.destinationUnwritable
        }

        // Group edits by page so we don't re-iterate the full list per page.
        let editsByPage: [Int: [PDFTextEdit]] = Dictionary(
            grouping: edits.edits, by: \.pageIndex
        )

        let pageCount = pdf.pageCount
        for i in 0..<pageCount {
            do {
                try Task.checkCancellation()
            } catch {
                writeContext.closePDF()
                try? FileManager.default.removeItem(at: tempURL)
                throw PDFEditError.cancelled
            }
            guard let page = pdf.page(at: i) else {
                progress(Double(i + 1) / Double(pageCount))
                continue
            }
            let pageBounds = page.bounds(for: .mediaBox)
            try drawPage(
                into: writeContext,
                page: page,
                pageBounds: pageBounds,
                edits: editsByPage[i] ?? []
            )
            progress(Double(i + 1) / Double(pageCount))
        }

        writeContext.closePDF()

        do {
            try FileManager.default.moveItem(at: tempURL, to: finalDest)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw PDFEditError.destinationUnwritable
        }
        return finalDest
    }

    private static func drawPage(
        into ctx: CGContext,
        page: PDFPage,
        pageBounds: CGRect,
        edits: [PDFTextEdit]
    ) throws {
        // Render the page as a CGImage (white background, then page draw).
        let pixelWidth = Int(ceil(pageBounds.width * renderScale))
        let pixelHeight = Int(ceil(pageBounds.height * renderScale))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let renderCtx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PDFEditError.flattenFailed(reason: "couldn't allocate render context")
        }
        renderCtx.setFillColor(NSColor.white.cgColor)
        renderCtx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        renderCtx.scaleBy(x: renderScale, y: renderScale)
        page.draw(with: .mediaBox, to: renderCtx)
        guard let pageImage = renderCtx.makeImage() else {
            throw PDFEditError.flattenFailed(reason: "couldn't render page image")
        }

        // Re-encode as JPEG quality 0.9 so CGPDFContext embeds verbatim.
        let jpegData = NSMutableData()
        guard let imageDest = CGImageDestinationCreateWithData(
            jpegData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            throw PDFEditError.flattenFailed(reason: "image encoder unavailable")
        }
        let imageProps: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: outputJPEGQuality
        ]
        CGImageDestinationAddImage(imageDest, pageImage, imageProps as CFDictionary)
        guard CGImageDestinationFinalize(imageDest) else {
            throw PDFEditError.flattenFailed(reason: "image encode failed")
        }
        guard let jpegSource = CGImageSourceCreateWithData(jpegData, nil),
              let embeddable = CGImageSourceCreateImageAtIndex(jpegSource, 0, nil) else {
            throw PDFEditError.flattenFailed(reason: "JPEG read-back failed")
        }

        // Begin a new PDF page with the source's exact mediaBox.
        var rect = pageBounds
        let mediaData = NSData(bytes: &rect, length: MemoryLayout<CGRect>.size)
        let pageInfo: [String: Any] = [
            kCGPDFContextMediaBox as String: mediaData
        ]
        ctx.beginPDFPage(pageInfo as CFDictionary)
        ctx.draw(embeddable, in: pageBounds)

        // Apply each edit: cover rectangle(s), then draw replacement text.
        for edit in edits {
            // Cover rectangles (one per line).
            ctx.saveGState()
            ctx.setFillColor(edit.backgroundColor.cgColor)
            for lineRect in edit.lineRects {
                ctx.fill(lineRect)
            }
            ctx.restoreGState()

            // Draw replacement text spanning the union rect.
            let union = edit.lineRects.reduce(CGRect.null) { $0.union($1) }
            guard !union.isNull, !edit.replacement.isEmpty else { continue }

            let attrs: [NSAttributedString.Key: Any] = [
                .font: edit.font,
                .foregroundColor: edit.color
            ]
            let attr = NSAttributedString(string: edit.replacement, attributes: attrs)
            let frameSetter = CTFramesetterCreateWithAttributedString(attr)
            let path = CGPath(rect: union, transform: nil)
            let frame = CTFramesetterCreateFrame(
                frameSetter,
                CFRange(location: 0, length: 0),
                path,
                nil
            )
            ctx.saveGState()
            ctx.setTextDrawingMode(.fill)
            CTFrameDraw(frame, ctx)
            ctx.restoreGState()
        }

        ctx.endPDFPage()
    }

    private static func resolveDestination(for source: URL) throws -> URL {
        let stem = source.deletingPathExtension().lastPathComponent + " (edited)"
        let preferred = source
            .deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension("pdf")
        let candidate = UniqueDestination.url(preferred: preferred)

        let probe = candidate
            .deletingPathExtension()
            .appendingPathExtension("probe\(UUID().uuidString.prefix(6))")
        do {
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return candidate
        } catch {
            let cache = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Dropshit/Edits", isDirectory: true)
            try FileManager.default.createDirectory(
                at: cache, withIntermediateDirectories: true
            )
            let p = cache.appendingPathComponent(stem).appendingPathExtension("pdf")
            return UniqueDestination.url(preferred: p)
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -10`
Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add Sources/ShelfDemo/PDFEdit/PDFEditFlatten.swift
git commit -m "Add PDFEditFlatten — rebuild PDF with cover rects + replacement text"
```

---

## Task 5: PDFEditService — queue + observable progress

**Files:**
- Create: `Sources/ShelfDemo/PDFEdit/PDFEditService.swift`

- [ ] **Step 1: Implement `PDFEditService.swift`**

Create `Sources/ShelfDemo/PDFEdit/PDFEditService.swift`:

```swift
import Foundation
import Combine

/// Queues PDF flatten/save tasks. One in flight at a time. Mirrors
/// `OCRService` / `ConversionService`.
@MainActor
final class PDFEditService: ObservableObject {
    @Published private(set) var progress: [UUID: Double] = [:]

    let completed = PassthroughSubject<(URL, UUID /* shelfID */), Never>()
    let failed = PassthroughSubject<PDFEditError, Never>()

    private struct QueuedSave {
        let saveID: UUID
        let shelfID: UUID
        let source: URL
        let edits: PDFEditDocument
    }

    private var queue: [QueuedSave] = []
    private var inFlight: QueuedSave?
    private var inFlightTask: Task<Void, Never>?

    func enqueueSave(
        saveID: UUID = UUID(),
        shelfID: UUID,
        source: URL,
        edits: PDFEditDocument
    ) {
        let task = QueuedSave(
            saveID: saveID, shelfID: shelfID, source: source, edits: edits
        )
        queue.append(task)
        progress[saveID] = 0
        runNextIfIdle()
    }

    func cancel(itemID: UUID) {
        queue.removeAll { $0.saveID == itemID }
        if inFlight?.saveID == itemID {
            inFlightTask?.cancel()
        }
        progress.removeValue(forKey: itemID)
    }

    func cancelAll() {
        queue.removeAll()
        inFlightTask?.cancel()
        progress.removeAll()
    }

    // MARK: - Internals

    private func runNextIfIdle() {
        guard inFlight == nil, !queue.isEmpty else { return }
        let task = queue.removeFirst()
        inFlight = task
        inFlightTask = Task { [weak self] in
            await self?.run(task)
        }
    }

    private func run(_ task: QueuedSave) async {
        let progressClosure: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor [weak self] in
                self?.progress[task.saveID] = p
            }
        }

        let result: Result<URL, PDFEditError>
        do {
            let url = try await PDFEditFlatten.flatten(
                source: task.source,
                edits: task.edits,
                progress: progressClosure
            )
            result = .success(url)
        } catch is CancellationError {
            result = .failure(.cancelled)
        } catch let e as PDFEditError {
            result = .failure(e)
        } catch {
            result = .failure(.flattenFailed(reason: error.localizedDescription))
        }
        finish(task: task, result: result)
    }

    private func finish(task: QueuedSave, result: Result<URL, PDFEditError>) {
        progress.removeValue(forKey: task.saveID)
        inFlight = nil
        inFlightTask = nil

        switch result {
        case .success(let url):
            completed.send((url, task.shelfID))
        case .failure(let err):
            failed.send(err)
        }
        runNextIfIdle()
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -10`
Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add Sources/ShelfDemo/PDFEdit/PDFEditService.swift
git commit -m "Add PDFEditService — sequential save queue with observable progress"
```

---

## Task 6: PDFEditView — PDFView wrapper with selection→popover and annotation overlay

**Files:**
- Create: `Sources/ShelfDemo/PDFEdit/PDFEditView.swift`

This is the largest UI piece. It hosts a PDFView, observes selection changes, and displays a popover when the user finishes a click-drag. It also keeps `PDFAnnotation`s on the PDFView in sync with the `PDFEditDocument` model so existing edits show up live.

- [ ] **Step 1: Implement `PDFEditView.swift`**

Create `Sources/ShelfDemo/PDFEdit/PDFEditView.swift`:

```swift
import AppKit
import SwiftUI
import PDFKit

/// SwiftUI wrapper around `PDFView` for the editor. Exposes:
///   - the current `PDFEditDocument` as a binding (single source of truth
///     in the parent SwiftUI hierarchy)
///   - a "selection" popover trigger that surfaces when the user drags-to-
///     select text
///
/// Keeps PDFKit annotations on the view in sync with `editDocument.edits`.
struct PDFEditView: NSViewRepresentable {
    let document: PDFDocument
    @Binding var editDocument: PDFEditDocument

    /// Called when the user has a non-empty selection that's confined to a
    /// single page. The closure returns true when an edit was created (so
    /// the view can clear the selection); false otherwise (the user
    /// dismissed the popover).
    var onSelection: (PDFSelection) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.delegate = context.coordinator

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.selectionChanged),
            name: .PDFViewSelectionChanged,
            object: pdfView
        )
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        // Reconcile annotations against `editDocument.edits`. We tag our
        // annotations with a marker in `userName` so we never touch
        // annotations belonging to the source document.
        guard let pdfDoc = pdfView.document else { return }

        // Collect known edit IDs.
        let liveIDs = Set(editDocument.edits.map(\.id.uuidString))

        for pageIndex in 0..<pdfDoc.pageCount {
            guard let page = pdfDoc.page(at: pageIndex) else { continue }

            // 1. Remove our annotations whose IDs aren't in the live set.
            for annotation in page.annotations {
                guard let marker = annotation.userName,
                      marker.hasPrefix("PDFTextEdit:") else { continue }
                let editID = String(marker.dropFirst("PDFTextEdit:".count))
                if !liveIDs.contains(editID) {
                    page.removeAnnotation(annotation)
                }
            }

            // 2. Add annotations for edits that belong to this page and
            //    aren't already drawn.
            let existingIDs = Set(
                page.annotations.compactMap { $0.userName?
                    .components(separatedBy: ":").last }
            )
            for edit in editDocument.edits where edit.pageIndex == pageIndex {
                if existingIDs.contains(edit.id.uuidString) { continue }
                addAnnotations(for: edit, on: page)
            }
        }
    }

    private func addAnnotations(for edit: PDFTextEdit, on page: PDFPage) {
        // One square cover per line.
        for (i, lineRect) in edit.lineRects.enumerated() {
            let cover = PDFAnnotation(
                bounds: lineRect,
                forType: .square,
                withProperties: nil
            )
            cover.color = edit.backgroundColor
            cover.interiorColor = edit.backgroundColor
            cover.border = nil
            cover.userName = "PDFTextEdit:\(edit.id.uuidString):\(i)"
            page.addAnnotation(cover)
        }

        // One free-text annotation spanning the union of line rects.
        let union = edit.lineRects.reduce(CGRect.null) { $0.union($1) }
        if !union.isNull, !edit.replacement.isEmpty {
            let textAnnotation = PDFAnnotation(
                bounds: union,
                forType: .freeText,
                withProperties: nil
            )
            textAnnotation.contents = edit.replacement
            textAnnotation.font = edit.font
            textAnnotation.fontColor = edit.color
            textAnnotation.color = .clear   // no border
            textAnnotation.userName = "PDFTextEdit:\(edit.id.uuidString):text"
            page.addAnnotation(textAnnotation)
        }
    }

    final class Coordinator: NSObject, PDFViewDelegate {
        let parent: PDFEditView
        init(parent: PDFEditView) { self.parent = parent }

        @objc func selectionChanged(_ note: Notification) {
            guard let pdfView = note.object as? PDFView,
                  let selection = pdfView.currentSelection,
                  !selection.string!.isEmpty else { return }
            // Only single-page selections are valid for replacement.
            guard selection.pages.count == 1 else { return }
            // Surface the selection to the parent so it can present a
            // popover. We pass the selection as-is; the parent reads
            // bounds, font, color from it.
            parent.onSelection(selection)
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -10`
Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add Sources/ShelfDemo/PDFEdit/PDFEditView.swift
git commit -m "Add PDFEditView — PDFView wrapper with annotation reconciliation"
```

---

## Task 7: PDFEditRoot — top-level SwiftUI editor view

**Files:**
- Create: `Sources/ShelfDemo/PDFEdit/PDFEditRoot.swift`

The toolbar + PDFEditView + footer + selection-popover state live here.

- [ ] **Step 1: Implement `PDFEditRoot.swift`**

Create `Sources/ShelfDemo/PDFEdit/PDFEditRoot.swift`:

```swift
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
        let attrs = attributed.attributes(at: 0, effectiveRange: nil)
        let font = (attrs[.font] as? NSFont)
            ?? NSFont(name: "Helvetica", size: 12)
            ?? .systemFont(ofSize: 12)
        let color = (attrs[.foregroundColor] as? NSColor) ?? .black

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
        // Render at PDFEditFlatten.renderDPI so the union rect translates
        // 1:1 into image-space pixels via renderScale.
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
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -15`
Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add Sources/ShelfDemo/PDFEdit/PDFEditRoot.swift
git commit -m "Add PDFEditRoot — toolbar + PDFEditView + replacement popover"
```

---

## Task 8: PDFEditWindow — NSWindowController host

**Files:**
- Create: `Sources/ShelfDemo/PDFEdit/PDFEditWindow.swift`

- [ ] **Step 1: Implement `PDFEditWindow.swift`**

Create `Sources/ShelfDemo/PDFEdit/PDFEditWindow.swift`:

```swift
import AppKit
import SwiftUI
import PDFKit

/// Wraps the SwiftUI PDFEditRoot in an NSWindow. Created lazily by
/// AppDelegate, brought to front on each invocation, never released
/// (closed-but-retained for re-use).
@MainActor
final class PDFEditWindow {
    private(set) var window: NSWindow?
    private weak var pdfEditService: PDFEditService?

    init(pdfEditService: PDFEditService) {
        self.pdfEditService = pdfEditService
    }

    /// Open the editor for `sourceURL`. If a window is already open, this
    /// brings it to front (regardless of which document it's showing —
    /// users must save/cancel that one first).
    func open(sourceURL: URL, shelfID: UUID) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let pdfDoc = PDFDocument(url: sourceURL) else { return }

        let root = PDFEditRoot(
            pdfDocument: pdfDoc,
            sourceURL: sourceURL,
            shelfID: shelfID,
            onClose: { [weak self] in
                self?.close()
            }
        )
        .environmentObject(pdfEditService ?? PDFEditService())

        let hosting = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Replace Text — \(sourceURL.lastPathComponent)"
        win.styleMask = [.titled, .closable, .resizable]
        win.setContentSize(NSSize(width: 900, height: 700))
        win.center()
        win.isReleasedWhenClosed = false

        self.window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -10`
Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add Sources/ShelfDemo/PDFEdit/PDFEditWindow.swift
git commit -m "Add PDFEditWindow — NSWindow host for PDFEditRoot"
```

---

## Task 9: Wire `Replace Text…` into ShelfContextMenu

**Files:**
- Modify: `Sources/ShelfDemo/ShelfContextMenu.swift`

This task adds a `pdfEditService` reference to `ShelfItemActions`, a `replaceText(_:)` selector, and a menu item in `makeAllActionsMenu` (gated on PDF + selectable text).

- [ ] **Step 1: Add `pdfEditService` to `ShelfItemActions`**

Update `ShelfItemActions` in `Sources/ShelfDemo/ShelfContextMenu.swift` — add the property, init parameter, and a stored handle to the editor window:

```swift
@MainActor
final class ShelfItemActions: NSObject {
    let item: ShelfItem
    let selectedItems: [ShelfItem]
    let shelfID: UUID
    weak var manager: ShelfManager?
    weak var conversionService: ConversionService?
    weak var ocrService: OCRService?
    weak var pdfEditService: PDFEditService?
    /// Editor window owned by the controller; injected via init so we
    /// don't create a fresh one per right-click.
    weak var pdfEditWindow: PDFEditWindow?

    init(
        item: ShelfItem,
        selectedItems: [ShelfItem],
        shelfID: UUID,
        manager: ShelfManager?,
        conversionService: ConversionService?,
        ocrService: OCRService?,
        pdfEditService: PDFEditService?,
        pdfEditWindow: PDFEditWindow?
    ) {
        self.item = item
        self.selectedItems = selectedItems
        self.shelfID = shelfID
        self.manager = manager
        self.conversionService = conversionService
        self.ocrService = ocrService
        self.pdfEditService = pdfEditService
        self.pdfEditWindow = pdfEditWindow
    }
    // ... existing methods ...
}
```

- [ ] **Step 2: Add the `replaceText` selector**

Insert near the existing `extractText(_:)` selector in `ShelfItemActions`:

```swift
@objc func replaceText(_ sender: NSMenuItem) {
    guard let url = item.fileURL else { return }
    pdfEditWindow?.open(sourceURL: url, shelfID: shelfID)
}
```

- [ ] **Step 3: Update `ShelfContextMenu.make(...)` signature**

```swift
@MainActor
static func make(
    for item: ShelfItem,
    selectedItems: [ShelfItem],
    shelfID: UUID,
    manager: ShelfManager?,
    conversionService: ConversionService?,
    ocrService: OCRService?,
    pdfEditService: PDFEditService?,
    pdfEditWindow: PDFEditWindow?
) -> NSMenu {
    let menu = ShelfMenu()
    let actions = ShelfItemActions(
        item: item,
        selectedItems: selectedItems,
        shelfID: shelfID,
        manager: manager,
        conversionService: conversionService,
        ocrService: ocrService,
        pdfEditService: pdfEditService,
        pdfEditWindow: pdfEditWindow
    )
    menu.actions = actions
    // ... existing body ...
}
```

- [ ] **Step 4: Insert the menu item in `makeAllActionsMenu`**

In `makeAllActionsMenu`, after the OCR `appendItems` block (added in the OCR plan's Task 8), add:

```swift
// Replace Text… is single-item only; multi-select is out of scope for v1.
if actions.selectedItems.count == 1,
   let url = actions.item.fileURL,
   url.pathExtension.lowercased() == "pdf",
   pdfHasSelectableText(url: url) {
    let mi = NSMenuItem(
        title: "Replace Text…",
        action: #selector(ShelfItemActions.replaceText(_:)),
        keyEquivalent: ""
    )
    mi.target = actions
    mi.image = NSImage(
        systemSymbolName: "character.cursor.ibeam",
        accessibilityDescription: nil
    )
    menu.addItem(mi)
}
```

And add this private helper inside the `ShelfContextMenu` enum:

```swift
private static func pdfHasSelectableText(url: URL) -> Bool {
    guard let pdf = PDFDocument(url: url) else { return false }
    let s = pdf.string ?? ""
    return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
```

If `import PDFKit` isn't already at the top of `ShelfContextMenu.swift`, add it.

- [ ] **Step 5: Update the call sites in `ShelfContainerView.swift`**

Both `ShelfContextMenu.make(...)` call sites need two new arguments. For Task 9 we pass `nil` so the file compiles; Task 11 will inject the real instances:

```swift
ShelfContextMenu.make(
    for: item,
    selectedItems: selectedShelfItems,
    shelfID: shelfID,
    manager: manager,
    conversionService: conversionService,
    ocrService: ocrService,
    pdfEditService: nil,
    pdfEditWindow: nil
)
```

- [ ] **Step 6: Verify build**

Run: `swift build 2>&1 | tail -10`
Expected: `Build complete!`.

- [ ] **Step 7: Commit**

```bash
git add Sources/ShelfDemo/ShelfContextMenu.swift Sources/ShelfDemo/ShelfContainerView.swift
git commit -m "Wire Replace Text into ShelfContextMenu (service injection in Task 11)"
```

---

## Task 10: Inject `pdfEditService` env-object into ShelfContainerView

**Files:**
- Modify: `Sources/ShelfDemo/ShelfContainerView.swift`

The PDFEditService env object is already used by `PDFEditRoot` (via `@EnvironmentObject`) inside the editor window. The shelf views don't draw progress for it — the editor window draws its own footer progress bar — so we only need to add the env-object property where appropriate (`PDFEditRoot` reads it via the window's hostingController environment) and propagate the service via `.environmentObject(pdfEditService)` so the editor window inherits it.

- [ ] **Step 1: Add a parameter on `ShelfContainerView`**

Match the pattern used by `conversionService` and `ocrService`. In `ShelfContainerView.swift`:

```swift
struct ShelfContainerView: View {
    // existing
    let manager: ShelfManager
    let shelfID: UUID
    var conversionService: ConversionService
    var ocrService: OCRService
    var pdfEditService: PDFEditService     // new
    // ...
}
```

Propagate downward in the body via `.environmentObject(pdfEditService)`:

```swift
body
    .environmentObject(conversionService)
    .environmentObject(ocrService)
    .environmentObject(pdfEditService)
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -10`
Expected: build will FAIL until Task 11 wires AppDelegate's instance through. That's expected. Reading the error tail should mention only that `pdfEditService` is missing from the call site in `App.swift` — fixing it is Task 11's job.

If the only error is in `App.swift`, proceed to Task 11. Otherwise, fix the additional issues here.

- [ ] **Step 3: Commit (only if build passes; otherwise commit alongside Task 11)**

If `swift build` passes (i.e., there are no callers of `ShelfContainerView` outside `App.swift`):

```bash
git add Sources/ShelfDemo/ShelfContainerView.swift
git commit -m "Add pdfEditService parameter to ShelfContainerView"
```

If it fails because `App.swift` doesn't pass the new arg, **leave it uncommitted** — Task 11 commits both files together.

---

## Task 11: AppDelegate wiring

**Files:**
- Modify: `Sources/ShelfDemo/App.swift`
- Modify: `Sources/ShelfDemo/ShelfContainerView.swift` (replace the `pdfEditService: nil` and `pdfEditWindow: nil` placeholders with real instances).

- [ ] **Step 1: Hold a `PDFEditService` and `PDFEditWindow` in AppDelegate**

In `Sources/ShelfDemo/App.swift`, near the existing `ocrService` line, add:

```swift
private let pdfEditService = PDFEditService()
private lazy var pdfEditWindow = PDFEditWindow(pdfEditService: pdfEditService)
private var pdfEditCompletedCancellable: AnyCancellable?
private var pdfEditFailedCancellable: AnyCancellable?
```

- [ ] **Step 2: Subscribe in `applicationDidFinishLaunching`**

Beside the OCR subscriptions, add:

```swift
pdfEditCompletedCancellable = pdfEditService.completed
    .sink { [weak self] (url, shelfID) in
        self?.manager.addFile(url: url, to: shelfID)
    }

pdfEditFailedCancellable = pdfEditService.failed
    .sink { [weak self] error in
        guard error != .cancelled else { return }
        self?.showConversionFailureToast(message: error.displayMessage)
    }
```

- [ ] **Step 3: Pass into `ShelfContainerView` in `makePanel(for:)`**

Where the existing `ocrService:` argument is passed, add:

```swift
.environmentObject(pdfEditService)   // if the env-object pattern is used
```

OR (matching whatever the v1.3 wiring did for ocrService) pass `pdfEditService: pdfEditService` to the initializer.

- [ ] **Step 4: Replace placeholders in `ShelfContainerView.swift`**

Both call sites of `ShelfContextMenu.make(...)` that pass `pdfEditService: nil, pdfEditWindow: nil` — replace with:

```swift
pdfEditService: pdfEditService,
pdfEditWindow: appDelegate.pdfEditWindow
```

The `appDelegate` reference may need plumbing depending on how the v1.3 wiring exposes services. The simplest fix is to inject `pdfEditWindow` as a parameter on `ShelfContainerView` alongside `pdfEditService`, then pass it into the call site:

```swift
struct ShelfContainerView: View {
    // ...
    var pdfEditWindow: PDFEditWindow
    // ...
}
```

And in `App.swift` `makePanel(for:)`:

```swift
ShelfContainerView(
    // ... existing args ...
    pdfEditService: pdfEditService,
    pdfEditWindow: pdfEditWindow
)
```

- [ ] **Step 5: Cancel-on-quit**

In `applicationWillTerminate(_:)`, alongside `ocrService.cancelAll()`:

```swift
pdfEditService.cancelAll()
pdfEditWindow.close()
```

- [ ] **Step 6: Verify build**

Run: `swift build 2>&1 | tail -15`
Expected: `Build complete!`.

- [ ] **Step 7: Commit**

```bash
git add Sources/ShelfDemo/App.swift Sources/ShelfDemo/ShelfContainerView.swift
git commit -m "Wire PDFEditService and PDFEditWindow into AppDelegate"
```

---

## Task 12: Manual verification

- [ ] **Step 1: Launch the new build**

Run:
```sh
pkill -f .build/debug/ShelfDemo 2>/dev/null
swift build && /Users/boski/Desktop/desk/shelf-demo/.build/debug/ShelfDemo &
```

- [ ] **Step 2: Verify the menu entry shows for digital PDFs only**

1. Drag a digital PDF (an invoice, a receipt, anything with selectable text) onto a shelf.
2. Right-click → All Actions. Expect to see **Replace Text…**.
3. Drag a scanned PDF (no selectable text — make one by using `cgPdfContext` + an image, or use any photographed PDF). Right-click → All Actions. Expect **Replace Text…** is **absent**.

- [ ] **Step 3: Single-edit flow**

1. From the digital PDF, right-click → Replace Text…
2. The editor window opens.
3. Drag-select a word in the PDF. The replacement popover appears.
4. Type a new word, click Replace.
5. The selected text is now visually replaced in the PDFView (rectangle covers, new text appears).
6. Click Save Edits.
7. Expected: the editor window closes; a `<stem> (edited).pdf` lands next to the source on disk and as a new shelf item.
8. Open the saved PDF in Preview. Cmd-F the new word — expect a hit. Cmd-F the original word — expect zero hits in the page area you edited.

- [ ] **Step 4: Multi-edit flow**

1. Open the same digital PDF in Replace Text…
2. Make 3 different replacements across the document.
3. Click an existing edit annotation and press Delete — it should disappear.
4. Click Save Edits — expect 2 edits flattened in the output.

- [ ] **Step 5: Cancel flow**

1. Open Replace Text…
2. Make an edit.
3. Close the window without saving.
4. Expected: no `(edited).pdf` is created. No orphan `.partXXXX.pdf` in `~/Downloads` or wherever the source lives.

- [ ] **Step 6: Failure toast**

1. Drag a PDF onto a shelf, open Replace Text…, make an edit.
2. In another Finder window, trash the original PDF.
3. Click Save Edits.
4. Expected: a toast saying "PDF edit failed: source file no longer exists." The editor stays open with edits intact.

- [ ] **Step 7: Cancel on quit**

1. Open Replace Text…, make an edit, click Save.
2. While the progress bar is moving, Quit the app.
3. Expected: no orphan `.partXXXX.pdf` files in the source directory or in `~/Library/Caches/Dropshit/Edits/`.

---

## Task 13: Final sweep

- [ ] **Step 1: Release build**

Run: `swift build -c release 2>&1 | tail -10`
Expected: `Build complete!` with no new errors.

- [ ] **Step 2: Spec coverage check**

Open `docs/superpowers/specs/2026-05-01-pdf-text-replace-design.md` and confirm:
- Output filename `<stem> (edited).pdf` ✓ Task 4.
- Atomic write (`.partXXXX.pdf`) ✓ Task 4.
- Fallback to `~/Library/Caches/Dropshit/Edits/` ✓ Task 4.
- Background sampling ✓ Task 3, used in Task 7.
- Font/color detection from PDFSelection ✓ Task 7.
- Multi-line selection (one rect per line) ✓ Task 7 (`selectionsByLine`).
- Multi-page selection disallowed ✓ Task 6.
- "Replace Text…" only for PDFs with selectable text ✓ Task 9.
- Editor closes on Save success ✓ Task 7.
- Single-instance editor ✓ Task 8.
- App-quit cancels saves ✓ Task 11.
- Toast on failure ✓ Task 11.

- [ ] **Step 3: Smoke-test pre-existing flows**

Drag/drop, paste, rename, move to trash, Cmd-Z undo, Convert to ▶, OCR Make Searchable / Extract Text — verify nothing regressed.

- [ ] **Step 4: Confirm no orphan files**

Run: `ls ~/Downloads | grep -E '\.part[0-9a-f]+\.pdf$'`
Expected: no output.

If gaps were found, file follow-up tasks. Otherwise the feature is ready to merge.
