# Format Conversion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-item "Convert to ▶" submenu in the shelf context menu that converts images (HEIC/PNG/TIFF/WebP/JPEG interop) via ImageIO and videos (MOV/M4V/MKV/AVI → MP4) via AVFoundation, with async progress UI and toast errors.

**Architecture:** A new `Conversion/` module exposes a `ConversionService` (a `@MainActor ObservableObject` so SwiftUI views can observe per-item progress) that queues `ConversionTask`s and runs them sequentially on background work. Per-format implementations (`ImageConverter`, `VideoConverter`) write to a sibling `.part` file and rename atomically. The submenu builder is a pure function over the selection's UTIs, so it's trivial to unit-test. The existing modal-popup `Convert Format…` action and its `ImageActions.convert(url:to:)` helper are removed.

**Tech Stack:** Swift 5.9+, AppKit, SwiftUI, ImageIO, AVFoundation, Combine, XCTest. macOS 13+.

**Spec:** `docs/superpowers/specs/2026-05-01-format-conversion-design.md`

---

## File Structure

**New (production):**
- `Sources/ShelfDemo/Conversion/ConversionTarget.swift` — `enum ConversionTarget` + `supportedTargets(for:)` pure function (image extensions only — video targets are handled separately because video target eligibility requires runtime `AVURLAsset.isReadable`).
- `Sources/ShelfDemo/Conversion/UniqueDestination.swift` — Finder-style collision resolver (pure).
- `Sources/ShelfDemo/Conversion/ConversionError.swift` — error enum + display strings.
- `Sources/ShelfDemo/Conversion/ImageConverter.swift` — ImageIO path. Sync (called from background queue).
- `Sources/ShelfDemo/Conversion/VideoConverter.swift` — AVFoundation path. Async with progress.
- `Sources/ShelfDemo/Conversion/ConversionService.swift` — `@MainActor` `ObservableObject`. Queues tasks, exposes `@Published` progress per item id, dispatches to ImageConverter/VideoConverter.
- `Sources/ShelfDemo/Conversion/ConversionMenu.swift` — builds the `Convert to ▶` submenu given a `[ShelfItem]` selection.

**New (tests):**
- `Tests/ShelfDemoTests/ConversionTargetTests.swift`
- `Tests/ShelfDemoTests/UniqueDestinationTests.swift`
- `Tests/ShelfDemoTests/ImageConverterTests.swift`

**Modified:**
- `Package.swift` — add `testTarget`.
- `Sources/ShelfDemo/ShelfContextMenu.swift` — replace the existing modal "Convert Format…" entry in `makeAllActionsMenu` with the new `Convert to ▶` submenu; add the same entry for video items.
- `Sources/ShelfDemo/ImageActions.swift` — delete `convert(url:to:)`, `ImageActionFormat`, and `ImageActionPrompts.format()` (now superseded).
- `Sources/ShelfDemo/ShelfContainerView.swift` — overlay a spinner / progress bar over item cards based on `ConversionService.progress[item.id]`.
- `Sources/ShelfDemo/App.swift` — instantiate `ConversionService`, hand it to the manager / views, cancel all on `applicationWillTerminate`, surface failures via the existing duplicate-toast mechanism.

---

## Task 1: Add test target to Package.swift

**Files:**
- Modify: `Package.swift`
- Create: `Tests/ShelfDemoTests/SmokeTests.swift`

- [ ] **Step 1: Add test target to Package.swift**

Replace `Package.swift` with:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShelfDemo",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ShelfDemo",
            path: "Sources/ShelfDemo",
            // The .icns is consumed only by the packaged .app bundle (copied
            // by scripts/build-dmg.sh). Excluding it here keeps SwiftPM
            // quiet and avoids embedding it in the SPM module's bundle.
            exclude: ["Resources/AppIcon.icns"]
        ),
        .testTarget(
            name: "ShelfDemoTests",
            dependencies: ["ShelfDemo"],
            path: "Tests/ShelfDemoTests"
        ),
    ]
)
```

- [ ] **Step 2: Write a smoke test that proves the test target builds**

Create `Tests/ShelfDemoTests/SmokeTests.swift`:

```swift
import XCTest
@testable import ShelfDemo

final class SmokeTests: XCTestCase {
    func test_smoke_canImportModule() {
        // If this compiles and runs, @testable import works against the
        // executable target. Concrete tests follow in later tasks.
        XCTAssertEqual(1 + 1, 2)
    }
}
```

- [ ] **Step 3: Run tests to verify infrastructure works**

Run: `swift test`
Expected: `Test Suite 'All tests' passed`. One test run, zero failures.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Tests/ShelfDemoTests/SmokeTests.swift
git commit -m "Add SwiftPM test target with smoke test"
```

---

## Task 2: ConversionTarget enum + supportedTargets pure function

**Files:**
- Create: `Sources/ShelfDemo/Conversion/ConversionTarget.swift`
- Create: `Tests/ShelfDemoTests/ConversionTargetTests.swift`

- [ ] **Step 1: Write the failing tests first**

Create `Tests/ShelfDemoTests/ConversionTargetTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail with "module not found / type not defined"**

Run: `swift test --filter ConversionTargetTests`
Expected: build error — `ConversionTarget` undefined.

- [ ] **Step 3: Implement `ConversionTarget.swift`**

Create `Sources/ShelfDemo/Conversion/ConversionTarget.swift`:

```swift
import Foundation
import UniformTypeIdentifiers

/// The format we're converting *to*. Sources are described by their UTI; the
/// per-source target list is encoded in `supportedImageTargets(for:)`.
enum ConversionTarget: String, CaseIterable, Equatable {
    case jpeg
    case png
    case mp4

    var displayName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png:  return "PNG"
        case .mp4:  return "MP4"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png:  return "png"
        case .mp4:  return "mp4"
        }
    }

    /// CFString UTI used by `CGImageDestinationCreateWithURL`. Not meaningful
    /// for `.mp4` (callers should not reach here for video).
    var imageDestinationUTI: CFString {
        switch self {
        case .jpeg: return UTType.jpeg.identifier as CFString
        case .png:  return UTType.png.identifier as CFString
        case .mp4:  preconditionFailure("mp4 is not an image target")
        }
    }

    // MARK: Source eligibility

    /// Image targets offered for a given source UTI. The matrix mirrors the
    /// design spec table; we keep it as a switch (not data) so the rules are
    /// audited at the type level.
    static func supportedImageTargets(for source: UTType) -> [ConversionTarget] {
        if source.conforms(to: .heic) { return [.jpeg, .png] }
        if source.conforms(to: .png)  { return [.jpeg] }
        if source.conforms(to: .jpeg) { return [.png] }
        if source.conforms(to: .tiff) { return [.jpeg, .png] }
        if source.conforms(to: .webP) { return [.jpeg, .png] }
        return []
    }

    /// Intersection of `supportedImageTargets(for:)` across a selection.
    /// Used by the menu builder to offer only targets valid for *every*
    /// selected item.
    static func commonImageTargets(forSourceUTIs utis: [UTType]) -> [ConversionTarget] {
        guard let first = utis.first else { return [] }
        let initial = Set(supportedImageTargets(for: first))
        let intersected = utis.dropFirst().reduce(initial) { acc, uti in
            acc.intersection(supportedImageTargets(for: uti))
        }
        // Preserve canonical order (jpeg before png) for stable menus.
        return ConversionTarget.allCases.filter { intersected.contains($0) }
    }

    /// True if the UTI is a video container we *might* be able to read
    /// (final eligibility is decided by `AVURLAsset.isReadable` at runtime,
    /// because MKV/AVI only work when the inner codec is supported).
    static func isVideoSourceUTI(_ uti: UTType) -> Bool {
        // movie covers QuickTime, MPEG-4, AVI, MKV-as-Matroska when registered.
        return uti.conforms(to: .movie) || uti.conforms(to: .video)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConversionTargetTests`
Expected: 10 tests, all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ShelfDemo/Conversion/ConversionTarget.swift Tests/ShelfDemoTests/ConversionTargetTests.swift
git commit -m "Add ConversionTarget enum with per-UTI eligibility matrix"
```

---

## Task 3: Unique destination URL (collision resolver)

**Files:**
- Create: `Sources/ShelfDemo/Conversion/UniqueDestination.swift`
- Create: `Tests/ShelfDemoTests/UniqueDestinationTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ShelfDemoTests/UniqueDestinationTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter UniqueDestinationTests`
Expected: build error — `UniqueDestination` undefined.

- [ ] **Step 3: Implement `UniqueDestination.swift`**

Create `Sources/ShelfDemo/Conversion/UniqueDestination.swift`:

```swift
import Foundation

/// Finder-style "(1), (2), ..." suffix resolver. Stateless; only reads
/// the filesystem to test for existence.
enum UniqueDestination {
    static func url(preferred: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: preferred.path) else { return preferred }
        let dir = preferred.deletingLastPathComponent()
        let ext = preferred.pathExtension
        let stem = preferred.deletingPathExtension().lastPathComponent
        var i = 1
        while true {
            let withSuffix = "\(stem) (\(i))"
            var candidate = dir.appendingPathComponent(withSuffix)
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter UniqueDestinationTests`
Expected: 4 tests, all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ShelfDemo/Conversion/UniqueDestination.swift Tests/ShelfDemoTests/UniqueDestinationTests.swift
git commit -m "Add UniqueDestination collision resolver"
```

---

## Task 4: ConversionError enum

**Files:**
- Create: `Sources/ShelfDemo/Conversion/ConversionError.swift`

(No tests — pure data type.)

- [ ] **Step 1: Implement the error enum**

Create `Sources/ShelfDemo/Conversion/ConversionError.swift`:

```swift
import Foundation

enum ConversionError: Error, Equatable {
    case sourceMissing
    case sourceUnreadable
    case destinationUnwritable
    case encodingFailed(reason: String)
    case cancelled

    /// User-facing string for the toast banner.
    var displayMessage: String {
        switch self {
        case .sourceMissing:
            return "Conversion failed: source file no longer exists."
        case .sourceUnreadable:
            return "Conversion failed: could not read the source."
        case .destinationUnwritable:
            return "Conversion failed: could not write to disk."
        case .encodingFailed(let reason):
            return "Conversion failed: \(reason)"
        case .cancelled:
            return "Conversion cancelled."
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add Sources/ShelfDemo/Conversion/ConversionError.swift
git commit -m "Add ConversionError enum"
```

---

## Task 5: ImageConverter (TDD with synthesized fixtures)

**Files:**
- Create: `Sources/ShelfDemo/Conversion/ImageConverter.swift`
- Create: `Tests/ShelfDemoTests/ImageConverterTests.swift`

- [ ] **Step 1: Write the failing tests using a programmatically-generated PNG fixture**

Create `Tests/ShelfDemoTests/ImageConverterTests.swift`:

```swift
import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShelfDemo

final class ImageConverterTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageConvTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Writes a 10x10 solid-red PNG to `tempDir/<name>.png` and returns its URL.
    private func makeSyntheticPNG(named name: String) throws -> URL {
        let url = tempDir.appendingPathComponent("\(name).png")
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: 10, height: 10,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw NSError(domain: "test", code: -1) }
        ctx.setFillColor(NSColor.red.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        guard let cg = ctx.makeImage() else { throw NSError(domain: "test", code: -2) }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw NSError(domain: "test", code: -3) }
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func test_png_to_jpeg_writes_sibling_file() throws {
        let src = try makeSyntheticPNG(named: "input")
        let result = try ImageConverter.convert(source: src, target: .jpeg)
        XCTAssertEqual(result.lastPathComponent, "input.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        // Verify the output is a real JPEG.
        let outSrc = CGImageSourceCreateWithURL(result as CFURL, nil)
        XCTAssertNotNil(outSrc)
        let type = outSrc.flatMap { CGImageSourceGetType($0) } as String?
        XCTAssertEqual(type, UTType.jpeg.identifier)
    }

    func test_png_to_jpeg_collision_appends_suffix() throws {
        let src = try makeSyntheticPNG(named: "input")
        // Pre-occupy "input.jpg".
        try Data().write(to: tempDir.appendingPathComponent("input.jpg"))

        let result = try ImageConverter.convert(source: src, target: .jpeg)

        XCTAssertEqual(result.lastPathComponent, "input (1).jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
    }

    func test_throws_sourceMissing_when_file_absent() {
        let bogus = tempDir.appendingPathComponent("nope.png")
        XCTAssertThrowsError(
            try ImageConverter.convert(source: bogus, target: .jpeg)
        ) { error in
            XCTAssertEqual(error as? ConversionError, .sourceMissing)
        }
    }

    func test_destination_falls_back_to_cache_when_dir_unwritable() throws {
        // Make the parent dir read-only so the sibling write fails with EACCES.
        let lockedDir = tempDir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(
            at: lockedDir, withIntermediateDirectories: true
        )
        let src = lockedDir.appendingPathComponent("input.png")
        try Data().write(to: src)
        // Now make src writable but the parent dir read-only.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: lockedDir.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: lockedDir.path
            )
        }
        // Re-write src as a real PNG (the empty data above isn't decodable).
        let realPNG = try makeSyntheticPNG(named: "real")
        try? FileManager.default.removeItem(at: src)
        // We can't write into the locked dir — but can put the source there
        // by relaxing permissions briefly:
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: lockedDir.path
        )
        try FileManager.default.copyItem(at: realPNG, to: src)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: lockedDir.path
        )

        let result = try ImageConverter.convert(source: src, target: .jpeg)
        XCTAssertTrue(
            result.path.contains("Caches/Dropshit/Converted"),
            "Expected fallback dir, got \(result.path)"
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail with "ImageConverter not defined"**

Run: `swift test --filter ImageConverterTests`
Expected: build error.

- [ ] **Step 3: Implement `ImageConverter.swift`**

Create `Sources/ShelfDemo/Conversion/ImageConverter.swift`:

```swift
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Synchronous ImageIO-backed converter. Designed to be called from a
/// background queue (the service handles dispatch).
enum ImageConverter {
    /// JPEG quality from the spec (0.9, sRGB).
    private static let jpegQuality: CGFloat = 0.9

    /// Convert `source` to `target`. Writes next to the source; falls back
    /// to `~/Library/Caches/Dropshit/Converted` if the source dir refuses
    /// writes. Atomic: writes to a sibling `<name>.partXXXX.<ext>` and
    /// renames into place on success.
    @discardableResult
    static func convert(
        source: URL,
        target: ConversionTarget,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard target != .mp4 else {
            preconditionFailure("ImageConverter cannot produce mp4")
        }
        guard fileManager.fileExists(atPath: source.path) else {
            throw ConversionError.sourceMissing
        }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw ConversionError.sourceUnreadable
        }

        let finalDestination = try resolveDestination(
            for: source, target: target, fileManager: fileManager
        )

        // Atomic write: encode to a temp sibling, then rename.
        let tempURL = finalDestination
            .deletingPathExtension()
            .appendingPathExtension("part\(UUID().uuidString.prefix(8))")
            .appendingPathExtension(target.fileExtension)

        let properties = makeProperties(for: target)

        guard let dest = CGImageDestinationCreateWithURL(
            tempURL as CFURL, target.imageDestinationUTI, 1, nil
        ) else {
            throw ConversionError.destinationUnwritable
        }
        CGImageDestinationAddImage(dest, cgImage, properties)
        guard CGImageDestinationFinalize(dest) else {
            try? fileManager.removeItem(at: tempURL)
            throw ConversionError.encodingFailed(reason: "image encoder failed")
        }

        do {
            try fileManager.moveItem(at: tempURL, to: finalDestination)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw ConversionError.destinationUnwritable
        }
        return finalDestination
    }

    // MARK: - Internals

    private static func makeProperties(for target: ConversionTarget) -> CFDictionary? {
        switch target {
        case .jpeg:
            let dict: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: jpegQuality
            ]
            return dict as CFDictionary
        case .png, .mp4:
            return nil
        }
    }

    private static func resolveDestination(
        for source: URL,
        target: ConversionTarget,
        fileManager: FileManager
    ) throws -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let preferred = source
            .deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension(target.fileExtension)
        let candidate = UniqueDestination.url(preferred: preferred, fileManager: fileManager)

        // Probe writability empirically: try to create an empty placeholder.
        // If that fails with a permission-class error, redirect to the
        // fallback cache dir.
        if canCreateFile(at: candidate, fileManager: fileManager) {
            return candidate
        }
        return try fallbackDestination(stem: stem, target: target, fileManager: fileManager)
    }

    private static func canCreateFile(at url: URL, fileManager: FileManager) -> Bool {
        let probe = url
            .deletingPathExtension()
            .appendingPathExtension("probe\(UUID().uuidString.prefix(6))")
        do {
            try Data().write(to: probe)
            try? fileManager.removeItem(at: probe)
            return true
        } catch let error as NSError {
            // EACCES (13), EPERM (1), EROFS (30) → not writable.
            let writeFailures: Set<Int> = [1, 13, 30]
            if writeFailures.contains(error.code) { return false }
            // Some other failure (e.g., parent dir doesn't exist) — also bail.
            return false
        }
    }

    private static func fallbackDestination(
        stem: String,
        target: ConversionTarget,
        fileManager: FileManager
    ) throws -> URL {
        let cache = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Dropshit/Converted", isDirectory: true)

        try fileManager.createDirectory(
            at: cache, withIntermediateDirectories: true
        )

        let preferred = cache
            .appendingPathComponent(stem)
            .appendingPathExtension(target.fileExtension)
        return UniqueDestination.url(preferred: preferred, fileManager: fileManager)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ImageConverterTests`
Expected: 4 tests, all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ShelfDemo/Conversion/ImageConverter.swift Tests/ShelfDemoTests/ImageConverterTests.swift
git commit -m "Add ImageConverter with atomic write and cache-dir fallback"
```

---

## Task 6: VideoConverter (manual verification)

**Files:**
- Create: `Sources/ShelfDemo/Conversion/VideoConverter.swift`

(No automated tests — synthesizing a real video fixture programmatically is heavy. Manual verification with a real `.mov` is in Task 11.)

- [ ] **Step 1: Implement `VideoConverter.swift`**

Create `Sources/ShelfDemo/Conversion/VideoConverter.swift`:

```swift
import Foundation
import AVFoundation

/// AVFoundation-backed video conversion. Async; reports progress via the
/// `progress` closure. Cancellation is cooperative: call `cancel()` on the
/// returned `Handle` and the export session is invalidated.
enum VideoConverter {
    final class Handle {
        fileprivate let session: AVAssetExportSession
        fileprivate let timer: DispatchSourceTimer
        init(session: AVAssetExportSession, timer: DispatchSourceTimer) {
            self.session = session
            self.timer = timer
        }
        func cancel() {
            timer.cancel()
            session.cancelExport()
        }
    }

    /// Returns the destination URL on success.
    /// `progress` is called on the main queue with values in 0...1.
    static func convertToMP4(
        source: URL,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, ConversionError>) -> Void
    ) -> Handle? {
        guard FileManager.default.fileExists(atPath: source.path) else {
            completion(.failure(.sourceMissing))
            return nil
        }

        let asset = AVURLAsset(url: source)
        guard asset.isReadable else {
            completion(.failure(.sourceUnreadable))
            return nil
        }

        // Pass-through when source is already H.264/AAC (or audio-less); we
        // detect this by inspecting tracks' format descriptions.
        let preset = canPassthrough(asset: asset)
            ? AVAssetExportPresetPassthrough
            : AVAssetExportPresetHighestQuality

        let finalDest: URL
        do {
            finalDest = try resolveDestination(for: source)
        } catch {
            completion(.failure(.destinationUnwritable))
            return nil
        }

        let tempURL = finalDest
            .deletingPathExtension()
            .appendingPathExtension("part\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("mp4")

        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
            completion(.failure(.encodingFailed(reason: "export session unavailable")))
            return nil
        }
        export.outputURL = tempURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

        // Poll progress at ~10 Hz (AVAssetExportSession has no KVO-friendly
        // progress prior to iOS 18 / macOS 15; polling is the documented path).
        let queue = DispatchQueue(label: "shelfdemo.video.progress")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak export] in
            guard let export else { return }
            let p = Double(export.progress)
            DispatchQueue.main.async { progress(p) }
        }
        timer.resume()

        let handle = Handle(session: export, timer: timer)

        export.exportAsynchronously {
            timer.cancel()
            DispatchQueue.main.async {
                switch export.status {
                case .completed:
                    do {
                        try FileManager.default.moveItem(at: tempURL, to: finalDest)
                        progress(1.0)
                        completion(.success(finalDest))
                    } catch {
                        try? FileManager.default.removeItem(at: tempURL)
                        completion(.failure(.destinationUnwritable))
                    }
                case .cancelled:
                    try? FileManager.default.removeItem(at: tempURL)
                    completion(.failure(.cancelled))
                case .failed:
                    try? FileManager.default.removeItem(at: tempURL)
                    let reason = export.error?.localizedDescription ?? "unknown error"
                    completion(.failure(.encodingFailed(reason: reason)))
                default:
                    try? FileManager.default.removeItem(at: tempURL)
                    completion(.failure(.encodingFailed(reason: "unexpected status")))
                }
            }
        }
        return handle
    }

    // MARK: - Internals

    private static func canPassthrough(asset: AVAsset) -> Bool {
        // Pass-through is safe when every video track is H.264 and every
        // audio track is AAC. (No tracks → also safe; just a remux.)
        let videoTracks = asset.tracks(withMediaType: .video)
        let audioTracks = asset.tracks(withMediaType: .audio)
        let videoOK = videoTracks.allSatisfy { trackHasFormat($0, fourCC: "avc1") }
        let audioOK = audioTracks.allSatisfy { trackHasFormat($0, fourCC: "mp4a") }
        return videoOK && audioOK
    }

    private static func trackHasFormat(_ track: AVAssetTrack, fourCC: String) -> Bool {
        guard let descs = track.formatDescriptions as? [CMFormatDescription] else {
            return false
        }
        return descs.allSatisfy { desc in
            let code = CMFormatDescriptionGetMediaSubType(desc)
            // Convert the FourCC string to a UInt32.
            let bytes = Array(fourCC.utf8)
            guard bytes.count == 4 else { return false }
            let expected = (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                |  UInt32(bytes[3])
            return code == expected
        }
    }

    private static func resolveDestination(for source: URL) throws -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let preferred = source
            .deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension("mp4")
        let candidate = UniqueDestination.url(preferred: preferred)

        // Empirically probe writability (mirrors ImageConverter logic).
        let probe = candidate
            .deletingPathExtension()
            .appendingPathExtension("probe\(UUID().uuidString.prefix(6))")
        do {
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return candidate
        } catch {
            let cache = try FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("Dropshit/Converted", isDirectory: true)
            try FileManager.default.createDirectory(
                at: cache, withIntermediateDirectories: true
            )
            let p = cache.appendingPathComponent(stem).appendingPathExtension("mp4")
            return UniqueDestination.url(preferred: p)
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add Sources/ShelfDemo/Conversion/VideoConverter.swift
git commit -m "Add VideoConverter with passthrough remux when source is H.264/AAC"
```

---

## Task 7: ConversionService (queue + observable progress)

**Files:**
- Create: `Sources/ShelfDemo/Conversion/ConversionService.swift`

(No unit tests; service is heavily UI-coupled. Verified end-to-end in Tasks 9–11.)

- [ ] **Step 1: Implement `ConversionService.swift`**

Create `Sources/ShelfDemo/Conversion/ConversionService.swift`:

```swift
import Foundation
import Combine

/// Queues conversion tasks and runs them sequentially. UI observes
/// `progress` (per source-item id) and `failures` (a passthrough subject).
///
/// Note: this is a `@MainActor ObservableObject` rather than an actor so
/// SwiftUI views can `@ObservedObject` it. Heavy work runs on a background
/// queue inside the per-task implementation.
@MainActor
final class ConversionService: ObservableObject {
    /// 0...1 progress per source ShelfItem.id while a task is in flight.
    /// Absent → idle. 1.0 is set briefly on completion before the entry is
    /// removed.
    @Published private(set) var progress: [UUID: Double] = [:]

    /// Fires when a converted file is ready, with the shelf to receive it.
    let completed = PassthroughSubject<(URL, UUID /* shelfID */), Never>()

    /// Fires when a task fails (already cancelled tasks emit `.cancelled`).
    let failed = PassthroughSubject<ConversionError, Never>()

    private struct QueuedTask {
        let itemID: UUID
        let shelfID: UUID
        let source: URL
        let target: ConversionTarget
    }

    private var queue: [QueuedTask] = []
    private var inFlight: QueuedTask?
    private var inFlightVideoHandle: VideoConverter.Handle?
    private let workQueue = DispatchQueue(
        label: "shelfdemo.conversion.work", qos: .userInitiated
    )

    func enqueue(
        sourceItemID: UUID,
        shelfID: UUID,
        source: URL,
        target: ConversionTarget
    ) {
        queue.append(QueuedTask(
            itemID: sourceItemID, shelfID: shelfID,
            source: source, target: target
        ))
        progress[sourceItemID] = 0
        runNextIfIdle()
    }

    /// Cancels the in-flight task for `itemID` (if any) and removes any
    /// queued tasks for the same item. No-op otherwise.
    func cancel(itemID: UUID) {
        queue.removeAll { $0.itemID == itemID }
        if inFlight?.itemID == itemID {
            inFlightVideoHandle?.cancel()
            // Image tasks are synchronous and cannot be interrupted; they
            // complete and just emit a noop result.
        }
        progress.removeValue(forKey: itemID)
    }

    /// Cancels everything. Used at app quit.
    func cancelAll() {
        queue.removeAll()
        inFlightVideoHandle?.cancel()
        progress.removeAll()
    }

    // MARK: - Internals

    private func runNextIfIdle() {
        guard inFlight == nil, !queue.isEmpty else { return }
        let task = queue.removeFirst()
        inFlight = task

        if task.target == .mp4 {
            inFlightVideoHandle = VideoConverter.convertToMP4(
                source: task.source,
                progress: { [weak self] p in
                    guard let self else { return }
                    self.progress[task.itemID] = p
                },
                completion: { [weak self] result in
                    self?.finish(task: task, result: result)
                }
            )
            if inFlightVideoHandle == nil {
                // VideoConverter already invoked completion synchronously.
                // Nothing else to do.
            }
        } else {
            workQueue.async { [weak self] in
                let result: Result<URL, ConversionError>
                do {
                    let url = try ImageConverter.convert(
                        source: task.source, target: task.target
                    )
                    result = .success(url)
                } catch let e as ConversionError {
                    result = .failure(e)
                } catch {
                    result = .failure(.encodingFailed(
                        reason: error.localizedDescription
                    ))
                }
                Task { @MainActor [weak self] in
                    self?.finish(task: task, result: result)
                }
            }
        }
    }

    private func finish(
        task: QueuedTask,
        result: Result<URL, ConversionError>
    ) {
        progress.removeValue(forKey: task.itemID)
        inFlight = nil
        inFlightVideoHandle = nil

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

Run: `swift build`
Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add Sources/ShelfDemo/Conversion/ConversionService.swift
git commit -m "Add ConversionService — sequential queue with observable progress"
```

---

## Task 8: ConversionMenu builder

**Files:**
- Create: `Sources/ShelfDemo/Conversion/ConversionMenu.swift`

- [ ] **Step 1: Implement `ConversionMenu.swift`**

Create `Sources/ShelfDemo/Conversion/ConversionMenu.swift`:

```swift
import AppKit
import UniformTypeIdentifiers

/// Builds the "Convert to ▶" submenu given a shelf-item selection. The
/// submenu is `nil` when the selection has no valid conversion target.
@MainActor
enum ConversionMenu {
    /// Selector handler signature: target action object owns a method that
    /// reads `representedObject as? ConversionTarget` and dispatches into
    /// the service.
    static func makeSubmenu(
        items: [ShelfItem],
        target: AnyObject,
        action: Selector
    ) -> NSMenu? {
        let urls = items.compactMap(\.fileURL)
        guard !urls.isEmpty, urls.count == items.count else { return nil }

        let utis = urls.compactMap(uti(for:))
        guard utis.count == urls.count else { return nil }

        // Image case: at least one image UTI in the selection. Take the
        // intersection of supported targets across selection.
        let imageTargets: [ConversionTarget]
        if utis.allSatisfy({ !ConversionTarget.supportedImageTargets(for: $0).isEmpty }) {
            imageTargets = ConversionTarget.commonImageTargets(forSourceUTIs: utis)
        } else {
            imageTargets = []
        }

        // Video case: every selected file is a readable video container.
        let isAllVideo = utis.allSatisfy(ConversionTarget.isVideoSourceUTI)
        let allReadable = isAllVideo && urls.allSatisfy { url in
            AVAssetReadabilityCache.isReadable(url)
        }

        var options: [ConversionTarget] = imageTargets
        if isAllVideo, allReadable { options.append(.mp4) }

        guard !options.isEmpty else { return nil }

        let menu = NSMenu()
        for option in options {
            let item = NSMenuItem(
                title: option.displayName,
                action: action,
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = option
            menu.addItem(item)
        }
        return menu
    }

    private static func uti(for url: URL) -> UTType? {
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let t = values.contentType { return t }
        return UTType(filenameExtension: url.pathExtension)
    }
}

// AVURLAsset.isReadable is expensive (opens the file). Cache one lookup per
// URL string for the lifetime of the menu — context menus rebuild on every
// open so this cache is effectively per-open.
import AVFoundation

@MainActor
private enum AVAssetReadabilityCache {
    private static var cache: [String: Bool] = [:]
    static func isReadable(_ url: URL) -> Bool {
        let key = url.path
        if let cached = cache[key] { return cached }
        let result = AVURLAsset(url: url).isReadable
        cache[key] = result
        return result
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add Sources/ShelfDemo/Conversion/ConversionMenu.swift
git commit -m "Add ConversionMenu submenu builder"
```

---

## Task 9: Wire submenu into ShelfContextMenu, drop the modal popup path

**Files:**
- Modify: `Sources/ShelfDemo/ShelfContextMenu.swift`
- Modify: `Sources/ShelfDemo/ImageActions.swift`

This task replaces the existing modal "Convert Format…" entry with the new submenu. Reading `ShelfContextMenu.swift` first is essential — the change touches `ShelfItemActions` (the menu target) and `makeAllActionsMenu` (the menu builder).

- [ ] **Step 1: Read `ShelfContextMenu.swift` and `ImageActions.swift` to understand current shape**

Run: `wc -l Sources/ShelfDemo/ShelfContextMenu.swift Sources/ShelfDemo/ImageActions.swift`
Read both files. Locate:
- `ShelfItemActions.convertFormat()` (around line 167)
- The "Convert Format…" entry in `makeAllActionsMenu` (around line 377)
- `ImageActionFormat` enum and `ImageActionPrompts.format()` in ImageActions.swift

- [ ] **Step 2: Inject a `ConversionService` reference into `ShelfItemActions`**

The actions object currently takes `(item, shelfID, manager)`. Add a service. In `Sources/ShelfDemo/ShelfContextMenu.swift`, modify `ShelfItemActions`:

```swift
@MainActor
final class ShelfItemActions: NSObject {
    let item: ShelfItem
    let shelfID: UUID
    weak var manager: ShelfManager?
    weak var conversionService: ConversionService?

    init(
        item: ShelfItem,
        shelfID: UUID,
        manager: ShelfManager?,
        conversionService: ConversionService?
    ) {
        self.item = item
        self.shelfID = shelfID
        self.manager = manager
        self.conversionService = conversionService
    }
    // ... existing methods ...
}
```

- [ ] **Step 3: Replace the `convertFormat` selector with a representedObject-driven `convertTo:` selector**

In `Sources/ShelfDemo/ShelfContextMenu.swift`, replace the `convertFormat` method with:

```swift
@objc func convertTo(_ sender: NSMenuItem) {
    guard let target = sender.representedObject as? ConversionTarget else { return }
    guard let url = item.fileURL else { return }
    conversionService?.enqueue(
        sourceItemID: item.id,
        shelfID: shelfID,
        source: url,
        target: target
    )
}
```

- [ ] **Step 4: Update the menu factory to take and forward a service**

In `Sources/ShelfDemo/ShelfContextMenu.swift`, update `make(for:shelfID:manager:)`:

```swift
@MainActor
static func make(
    for item: ShelfItem,
    shelfID: UUID,
    manager: ShelfManager?,
    conversionService: ConversionService?
) -> NSMenu {
    let menu = ShelfMenu()
    let actions = ShelfItemActions(
        item: item,
        shelfID: shelfID,
        manager: manager,
        conversionService: conversionService
    )
    menu.actions = actions
    // ... existing body ...
}
```

And update `makeAllActionsMenu` signature to receive `actions` (already does) and to insert the new submenu — replace the existing line:

```swift
addItem(to: menu, title: "Convert Format…",
        selector: #selector(ShelfItemActions.convertFormat),
        symbol: "arrow.triangle.2.circlepath",
        target: actions)
```

with:

```swift
if let submenu = ConversionMenu.makeSubmenu(
    items: [actions.item],
    target: actions,
    action: #selector(ShelfItemActions.convertTo(_:))
) {
    let entry = NSMenuItem(
        title: "Convert to",
        action: nil,
        keyEquivalent: ""
    )
    entry.image = NSImage(
        systemSymbolName: "arrow.triangle.2.circlepath",
        accessibilityDescription: nil
    )
    entry.submenu = submenu
    menu.addItem(entry)
}
```

Note: The "Convert to ▶" entry now appears for **any** item with a valid target (including videos), so move this block out of the `if isImage` block — insert it just before the image-actions section header, gated only on the submenu being non-nil. The image-actions section continues to gate on `isImage`.

- [ ] **Step 5: Update the call site in `ShelfContainerView.swift` (search for `ShelfContextMenu.make(`)**

Run: `grep -rn "ShelfContextMenu.make" Sources/ShelfDemo/`. Expect one or two call sites. At each, pass the new `conversionService:` argument. The service comes from `@EnvironmentObject` or an explicit property — add the plumbing in Task 11.

For now, pass `conversionService: nil` so the file compiles. Submenu will simply not appear until Task 11.

- [ ] **Step 6: Delete the dead code in `ImageActions.swift`**

Remove `ImageActionFormat` enum (lines 6-29) and `ImageActionPrompts.format()` (around lines 169-185). These are unreachable now.

Then remove `ImageActions.convert(url:to:)` (around lines 47-60) — no callers remain.

- [ ] **Step 7: Verify build**

Run: `swift build`
Expected: Build complete with no warnings about unused symbols.

- [ ] **Step 8: Commit**

```bash
git add Sources/ShelfDemo/ShelfContextMenu.swift Sources/ShelfDemo/ImageActions.swift
git commit -m "Replace modal Convert Format popup with Convert to submenu"
```

---

## Task 10: Spinner / progress overlay on item cards

**Files:**
- Modify: `Sources/ShelfDemo/ShelfContainerView.swift`

The card-level rendering of items lives in `ShelfContainerView.swift` (`DocumentGridItem` / list row, depending on view mode). The overlay reads `ConversionService.progress[item.id]`.

- [ ] **Step 1: Locate the item card view used by both grid and list views**

Run: `grep -n "DocumentGridItem\|item.thumbnail\|struct.*Card\|RowItemView" Sources/ShelfDemo/ShelfContainerView.swift | head -20`

Identify the smallest view that draws a single item — the overlay attaches there.

- [ ] **Step 2: Add a `ConversionService` environment object and a progress overlay**

At the top of `ShelfContainerView.swift`, after the existing imports, add a new view:

```swift
private struct ConversionOverlay: View {
    let progress: Double?
    let onCancel: () -> Void

    var body: some View {
        if let progress {
            ZStack {
                Color.black.opacity(0.45)
                    .allowsHitTesting(false)
                VStack(spacing: 6) {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(width: 76)
                        .tint(.white)
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .transition(.opacity)
        }
    }
}
```

- [ ] **Step 3: Wire the overlay into the item card**

At the smallest item-card view identified in Step 1, add an `@EnvironmentObject var conversionService: ConversionService` property and overlay:

```swift
.overlay {
    ConversionOverlay(
        progress: conversionService.progress[item.id],
        onCancel: { conversionService.cancel(itemID: item.id) }
    )
}
```

If the card view doesn't already participate in the SwiftUI environment, also propagate the env object from `ShelfContainerView`'s body via the standard `.environmentObject(conversionService)` chain.

- [ ] **Step 4: Verify build**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 5: Commit**

```bash
git add Sources/ShelfDemo/ShelfContainerView.swift
git commit -m "Show conversion progress overlay on item cards"
```

---

## Task 11: App-level wiring (instantiate service, pass through, handle results)

**Files:**
- Modify: `Sources/ShelfDemo/App.swift`
- Modify: `Sources/ShelfDemo/ShelfContainerView.swift` (call site for ShelfContextMenu.make)

- [ ] **Step 1: Instantiate `ConversionService` in `AppDelegate`**

In `Sources/ShelfDemo/App.swift`, add to `AppDelegate` (near the `manager` property):

```swift
private let conversionService = ConversionService()
private var conversionCompletedCancellable: AnyCancellable?
private var conversionFailedCancellable: AnyCancellable?
```

- [ ] **Step 2: Subscribe to service outputs in `applicationDidFinishLaunching`**

Add inside `applicationDidFinishLaunching`:

```swift
conversionCompletedCancellable = conversionService.completed
    .sink { [weak self] (url, shelfID) in
        guard let self else { return }
        self.manager.addFile(url: url, to: shelfID)
    }

conversionFailedCancellable = conversionService.failed
    .sink { [weak self] error in
        // .cancelled is silent — the user initiated it, no toast needed.
        guard error != .cancelled else { return }
        self?.showConversionFailureToast(message: error.displayMessage)
    }
```

- [ ] **Step 3: Add a generic toast that reuses the duplicate-toast plumbing**

Find `showDuplicateToast(for:)` in `App.swift`. Add a new method beside it:

```swift
private func showConversionFailureToast(message: String) {
    // Reuse the toast panel infrastructure with custom text. If no shelf
    // panel is currently visible, fall back to a banner attached to the
    // first available shelf, or no-op (we'd rather drop the toast than
    // pop a modal).
    guard let firstVisible = panels.first(where: { $0.value.isVisible }) else {
        NSLog("Shelf: \(message) (no visible panel for toast)")
        return
    }
    showToast(message, near: firstVisible.value)
}
```

If there isn't already a generic `showToast(_:near:)`, refactor `showDuplicateToast(for:)` to extract one. The conversion path then calls `showToast(error.displayMessage, near: panel)`. Keep the existing duplicate-toast caller working.

- [ ] **Step 4: Hand the service down through the view tree and the context menu**

In `Sources/ShelfDemo/App.swift`, where `ShelfContainerView` is created (search for `ShelfContainerView(`), add `.environmentObject(conversionService)` on the resulting view, or inject as an explicit property if the view already takes manager-like dependencies that way.

In `Sources/ShelfDemo/ShelfContainerView.swift`, the call site for `ShelfContextMenu.make(...)` (added in Task 9 step 5 with `conversionService: nil`) — replace with the real `@EnvironmentObject` reference:

```swift
@EnvironmentObject private var conversionService: ConversionService

// ... at the call site:
ShelfContextMenu.make(
    for: item,
    shelfID: shelfID,
    manager: manager,
    conversionService: conversionService
)
```

- [ ] **Step 5: Cancel-on-quit**

In `Sources/ShelfDemo/App.swift`, add to `AppDelegate`:

```swift
func applicationWillTerminate(_ notification: Notification) {
    conversionService.cancelAll()
}
```

- [ ] **Step 6: Manual verification — image conversion**

Run: `swift build && /Users/boski/Desktop/desk/shelf-demo/.build/debug/ShelfDemo`

In the running app:
1. Drag a `.heic` file onto the menubar shelf.
2. Right-click the item → **All Actions → Convert to ▶ → JPEG**.
3. Expected: a `<name>.jpg` file appears beside the original on disk; a new item shows up in the shelf with the converted file. No modal alert.

- [ ] **Step 7: Manual verification — video conversion**

In the running app:
1. Drag a small `.mov` (10–30 seconds) onto a shelf.
2. Right-click → **All Actions → Convert to ▶ → MP4**.
3. Expected: a thin progress bar appears under the source card, advances to 100%, then a sibling `.mp4` lands on disk and as a new shelf item.
4. Repeat with a longer video, click the ✕ on the overlay mid-conversion.
5. Expected: progress bar disappears, no `.part` file left in the source dir, no `.mp4` final file written.

- [ ] **Step 8: Manual verification — failure toast**

In the running app:
1. Add an item to a shelf, then trash the underlying file from Finder.
2. Right-click in the shelf → Convert to ▶ → JPEG.
3. Expected: a toast appears reading "Conversion failed: source file no longer exists." No modal alert.

- [ ] **Step 9: Commit**

```bash
git add Sources/ShelfDemo/App.swift Sources/ShelfDemo/ShelfContainerView.swift
git commit -m "Wire ConversionService into AppDelegate and views; cancel on quit"
```

---

## Task 12: Multi-select wiring + currently-converting guard

The single-item path is working after Task 11. This task adds (a) bulk conversion when the right-clicked item is part of an active multi-selection, mirroring Finder behavior, and (b) skips re-enqueueing an item that is currently converting.

**Files:**
- Modify: `Sources/ShelfDemo/ShelfContextMenu.swift`
- Modify: `Sources/ShelfDemo/ShelfContainerView.swift`

- [ ] **Step 1: Add `selectedItems: [ShelfItem]` to `ShelfItemActions`**

In `Sources/ShelfDemo/ShelfContextMenu.swift`, extend `ShelfItemActions`:

```swift
@MainActor
final class ShelfItemActions: NSObject {
    let item: ShelfItem
    let selectedItems: [ShelfItem]   // includes `item` when present in selection;
                                     // [item] for non-selection right-clicks
    let shelfID: UUID
    weak var manager: ShelfManager?
    weak var conversionService: ConversionService?

    init(
        item: ShelfItem,
        selectedItems: [ShelfItem],
        shelfID: UUID,
        manager: ShelfManager?,
        conversionService: ConversionService?
    ) {
        self.item = item
        self.selectedItems = selectedItems
        self.shelfID = shelfID
        self.manager = manager
        self.conversionService = conversionService
    }
    // ...
}
```

- [ ] **Step 2: Update `ShelfContextMenu.make(...)` to accept and forward selection**

```swift
static func make(
    for item: ShelfItem,
    selectedItems: [ShelfItem],
    shelfID: UUID,
    manager: ShelfManager?,
    conversionService: ConversionService?
) -> NSMenu {
    let menu = ShelfMenu()
    let actions = ShelfItemActions(
        item: item,
        selectedItems: selectedItems,
        shelfID: shelfID,
        manager: manager,
        conversionService: conversionService
    )
    menu.actions = actions
    // ... rest unchanged ...
}
```

In the body, where `ConversionMenu.makeSubmenu` was called with `[actions.item]`, change to `actions.selectedItems`. Also rename the entry to reflect bulk:

```swift
let title = actions.selectedItems.count > 1
    ? "Convert \(actions.selectedItems.count) Items to"
    : "Convert to"
let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
```

- [ ] **Step 3: Update `convertTo(_:)` to iterate and skip in-flight items**

```swift
@objc func convertTo(_ sender: NSMenuItem) {
    guard let target = sender.representedObject as? ConversionTarget else { return }
    guard let service = conversionService else { return }
    for it in selectedItems {
        guard let url = it.fileURL else { continue }
        // Skip items already converting — re-enqueue would just queue
        // a redundant task at the back of the line.
        guard service.progress[it.id] == nil else { continue }
        service.enqueue(
            sourceItemID: it.id,
            shelfID: shelfID,
            source: url,
            target: target
        )
    }
}
```

- [ ] **Step 4: Compute selection at the call site in `ShelfContainerView.swift`**

Locate the call to `ShelfContextMenu.make(...)`. The grid/list views already maintain `@State var selection: Set<UUID>`. Replace the call with:

```swift
let selectedShelfItems: [ShelfItem]
if selection.contains(item.id), selection.count > 1 {
    // Right-clicked item is part of an active multi-selection — operate
    // on all of them. Otherwise fall through to single-item mode.
    selectedShelfItems = items.filter { selection.contains($0.id) }
} else {
    selectedShelfItems = [item]
}
return ShelfContextMenu.make(
    for: item,
    selectedItems: selectedShelfItems,
    shelfID: shelfID,
    manager: manager,
    conversionService: conversionService
)
```

(The exact local variable names — `items`, `manager`, `conversionService` — should match what the surrounding view already has in scope.)

- [ ] **Step 5: Verify build**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 6: Manual verification — multi-select bulk convert**

1. Drop 3 HEIC files onto a shelf.
2. Multi-select all 3 (cmd-click or shift-click — uses the existing selection model).
3. Right-click on one of them → **All Actions → Convert 3 Items to ▶ → JPEG**.
4. Expected: progress overlays appear on each card sequentially; three sibling `.jpg` files land on disk; three new shelf items appear.
5. Multi-select 2 HEIC + 1 PNG; right-click. Expected: submenu offers JPEG only (intersection), not PNG.

- [ ] **Step 7: Manual verification — already-converting guard**

1. Drop a long `.mov` (1+ minute).
2. Right-click → Convert to ▶ → MP4.
3. While conversion is running, right-click again on the same item → Convert to ▶ → MP4.
4. Expected: the second invocation is a no-op (no second toast, no second progress bar — the first conversion continues uninterrupted).

- [ ] **Step 8: Commit**

```bash
git add Sources/ShelfDemo/ShelfContextMenu.swift Sources/ShelfDemo/ShelfContainerView.swift
git commit -m "Multi-select bulk conversion + skip already-converting items"
```

---

## Task 13: Final sweep

- [ ] **Step 1: Run all tests**

Run: `swift test`
Expected: All tests pass.

- [ ] **Step 2: Run a release build to catch any optimization-only warnings**

Run: `swift build -c release`
Expected: Build complete with no warnings.

- [ ] **Step 3: Re-read the spec, check for missed requirements**

Open `docs/superpowers/specs/2026-05-01-format-conversion-design.md` and skim the Conversion Matrix, Output Behavior, Encoding Defaults, Async/Progress UI, Failure Handling, and Edge Cases sections. For each bullet, confirm a corresponding code path exists. Note any gap and file a follow-up task. (Expected: zero gaps.)

- [ ] **Step 4: Smoke-test the existing app flows are still intact**

Drag/drop, paste from clipboard, rename, move to trash, undo (Cmd-Z) — verify nothing regressed. Quit the app and confirm no `.part` files remain in `~/Downloads` or other test directories.

- [ ] **Step 5: Commit any follow-up notes if needed**

If gaps were found, capture them as a `docs/superpowers/plans/<followup>.md` and commit. Otherwise, no commit.
