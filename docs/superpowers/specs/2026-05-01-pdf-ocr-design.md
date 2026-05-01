# PDF OCR (v1) — Design

**Date:** 2026-05-01
**Status:** Approved (pending implementation plan)
**Scope:** Make scanned PDFs text-searchable, and extract recognized text from PDFs and images into shelf snippets. Engine is Apple's built-in **Vision** framework — no third-party libraries, no paid SDKs.

## Goal

Two right-click actions on the affected items in a shelf:

1. **Make Searchable** (PDFs only) — produces a sibling PDF with an invisible per-page text layer over the original page imagery. Cmd-F search in Preview, copy/paste in Preview, and Spotlight indexing all start working.
2. **Extract Text** (PDFs *and* images) — recognized text lands as a new shelf text snippet via the existing `ShelfManager.addText(_:to:)` path. Original is unchanged.

## Non-Goals (v1)

- Translation.
- Language picker UI (auto-detect only).
- OCR-quality presets / fast vs accurate toggle.
- Layout preservation in extracted text (output is plain text with newlines between recognized blocks; multi-page PDFs separate pages with a `--- Page N ---` marker).
- Detecting "this PDF is already searchable" and skipping/warning. v1 always runs OCR if the user asks for it. The output is a sibling file, so nothing is overwritten.
- Annotation-based searchability path (we use the rebuild approach — see Architecture trade-off below).
- Redaction with content removal.
- Editing existing PDF text.

## User Flow

1. User right-clicks an item (or multi-selection) in a shelf.
2. The **All Actions** submenu shows:
   - `Make Searchable` if every selected item is a PDF.
   - `Extract Text` if every selected item is a PDF *or* an image (intersection rule, like Convert to ▶).
3. User picks an action.
4. The source item card shows a spinner / progress overlay (same component the conversion path uses, generalized to read from either service). Per-page progress is reported.
5. On completion:
   - **Make Searchable**: a new PDF named `<stem> (searchable).pdf` lands next to the source on disk and is added to the same shelf as a sibling item.
   - **Extract Text**: a new shelf text snippet is created. The recognized text is written to a temp `.txt` file (same plumbing as the existing paste-text flow).
6. Cancellation: small ✕ on the overlay aborts the current task; partial output is discarded.
7. On failure, a toast appears (`"OCR failed: <reason>"`) and the card returns to idle.

## Engine

`VNRecognizeTextRequest`:
- `recognitionLevel = .accurate`
- `usesLanguageCorrection = true`
- `automaticallyDetectsLanguage = true` (the project's deployment target is already macOS 13+, where this property is available).
- Operates on `CGImage` derived from each PDF page rendered at 150 DPI, or directly from the source for image inputs.

## Output Behavior

### Make Searchable (PDFs only)

- Default destination: same directory as the source. `~/Downloads/foo.pdf` → `~/Downloads/foo (searchable).pdf`.
- Name collision: append `(1)`, `(2)`. (Reuses the same `UniqueDestination.url(preferred:fileManager:)` helper from the conversion module.)
- Source directory not writable → fall back to `~/Library/Caches/Dropshit/OCR/`. Same empirical-write-probe approach as the converter (try a placeholder write; on `EACCES`/`EPERM`/`EROFS` redirect).
- Atomic write: encode to a `.partXXXX.pdf` sibling, rename into place on success.
- The new PDF is added to the same shelf as a sibling item; original stays put.
- The new PDF is structurally a **rebuild**, not a mutated original (see Architecture trade-off).

### Extract Text (PDFs and images)

- Output is a shelf text snippet via `ShelfManager.addText(text, to: shelfID)`.
- Multi-page PDFs concatenate pages with `\n\n--- Page N ---\n\n` between them.
- No on-disk artifact next to the source; the existing addText path writes a `.txt` to the system temp dir for openability.
- If recognition returns no text at all → toast `"OCR found no text"` and no snippet is created.

## Architecture trade-off

PDFKit offers two paths for embedding searchable text in a PDF:

### A. Annotation-based

Add an invisible `PDFAnnotation` of type `freeText` per recognized line on each page, then write the document. **Pros:** preserves original PDF byte-for-byte under the annotations layer; small file size. **Cons:** Spotlight indexing of annotation streams is inconsistent across macOS versions, and some PDF readers don't surface annotation text in their text-extraction APIs.

### B. Rebuild

Render each source page to a high-quality JPEG (0.9 quality, 150 DPI), draw that into a fresh `CGContext`-backed PDF page, then draw the recognized strings on top in invisible-text rendering mode (`kCGTextRenderingModeInvisible`, value `3`). **Pros:** Spotlight reliably indexes, every PDF reader can extract the text, output is a clean self-contained file. **Cons:** original page imagery is re-encoded — file size grows, and very high-DPI archival scans get slightly soft.

**Decision:** v1 uses **Path B (rebuild)**. Reliability of search/extract beats byte-perfect preservation for this use case (target is scanned receipts, contracts, and similar — none of which need archival-grade fidelity).

## Encoding Defaults (no UI)

- Page render DPI for OCR input: **150 DPI**.
- Rebuild output JPEG quality: **0.9**.
- Recognition level: **`.accurate`**.
- Language correction: **on**.
- Recognition languages: **auto-detect**.

## Async / Progress UI

- New `OCRService`: `@MainActor final class OCRService: ObservableObject`. Same shape as the existing `ConversionService`:
  - `@Published private(set) var progress: [UUID: Double]`
  - `let completedSearchable = PassthroughSubject<(URL, UUID /* shelfID */), Never>()`
  - `let completedExtracted = PassthroughSubject<(String, UUID /* shelfID */), Never>()`
  - `let failed = PassthroughSubject<OCRError, Never>()`
  - `func enqueueMakeSearchable(sourceItemID:shelfID:source:)`
  - `func enqueueExtractText(sourceItemID:shelfID:source:isPDF:)`
  - `func cancel(itemID:)`
  - `func cancelAll()`
- Sequential — at most one OCR task in flight globally. (Both services are independent queues; OCR and conversion can theoretically run in parallel since they touch different items, but to keep CPU pressure low we'll cap to one OCR at a time.)
- Per-page progress: `progress[itemID] = pagesDone / totalPages` for PDFs. For images, value flips 0 → 1 in one shot at the end of recognition.
- The progress overlay component (`ConversionOverlay` introduced for v1.2) is generalized: it stops reading from a specific service and instead takes a `progress: Double?` plus an `onCancel: () -> Void`. The card view picks the higher-priority active progress between the two services (only one will ever be non-nil for the same item at any moment).

## Failure Handling

`enum OCRError: Error, Equatable`:

- `.sourceMissing`
- `.sourceUnreadable` (corrupt PDF, encrypted PDF, unsupported image)
- `.destinationUnwritable`
- `.recognitionFailed(reason: String)`
- `.noTextFound` (only for `Extract Text` — `Make Searchable` will still produce a valid output PDF even if no text was recognized; "no text found" is a soft outcome there)
- `.cancelled`

`displayMessage` mirrors `ConversionError.displayMessage`. Surfaces as a toast via the existing `showToast(_:near:)` helper. `.cancelled` is silent.

## Edge Cases

- **Source trashed mid-task** → `.sourceMissing` toast.
- **PDF with zero pages** → submenu entries omitted (preflight check on `PDFDocument.pageCount`).
- **Encrypted/locked PDF** → `.sourceUnreadable` toast.
- **Item already OCR'ing** → both submenu entries disabled while in flight (read from `OCRService.progress[item.id]`, mirroring the existing in-flight guard for conversion).
- **Multi-select with mixed PDF + image** → "Make Searchable" hidden, "Extract Text" still offered.
- **Same-target-as-source** is not applicable here — output is always a different shape than input.
- **Disk full during rebuild** → surfaced via `FileManager` write failure → `.destinationUnwritable` toast.
- **App quitting while tasks run** → `applicationWillTerminate` calls `OCRService.cancelAll()`. Atomic write rule means no orphan `.partXXXX.pdf` files.
- **PDF with image-only pages mixed with text-rich pages** (rare in scans, but possible) — we treat all pages uniformly: recognize on every page, embed text on every page in the rebuilt output. The text-rich pages get redundant invisible text layers, which is harmless.

## Architecture

New folder: `Sources/ShelfDemo/OCR/`.

| File                  | Purpose |
| --------------------- | ------- |
| `OCREngine.swift`     | Pure Vision wrapper. `static func recognize(image: CGImage) async throws -> [RecognizedLine]`. `RecognizedLine` is a small struct of `text: String` plus a `boundingBox: CGRect` in normalized image coordinates (Vision's native unit). The bounding box is what the rebuild path needs to position the invisible text. |
| `PDFOCR.swift`        | Multi-page orchestrator. `static func makeSearchable(source: URL, progress: @escaping (Double) -> Void) async throws -> URL`. Loops pages, calls `OCREngine.recognize`, builds an output PDF via `CGContext` + `kCGTextRenderingModeInvisible`. Also `static func extractText(source: URL, progress: @escaping (Double) -> Void) async throws -> String`. |
| `ImageOCR.swift`      | Single-image text extraction. `static func extractText(source: URL) async throws -> String`. Loads the image via `CGImageSourceCreateWithURL`, hands the `CGImage` to `OCREngine`. |
| `OCRError.swift`      | Error enum + display strings. |
| `OCRService.swift`    | `@MainActor ObservableObject` queue + dispatch, mirrors `ConversionService`. |
| `OCRMenu.swift`       | Submenu / menu-item builder. Returns the two `NSMenuItem`s (`Make Searchable`, `Extract Text`) when applicable, or nothing. Handles intersection across multi-select. |

Edits to existing code:

- `ShelfContextMenu.swift` — call into `OCRMenu` from `makeAllActionsMenu`. Adds the menu items below the existing `Convert to ▶` entry. Adds `weak var ocrService: OCRService?` to `ShelfItemActions`, plus `@objc func makeSearchable(_:)` and `@objc func extractText(_:)` selectors that read from `selectedItems` and `service.progress[id]` (skip-already-running guard, same shape as `convertTo`).
- `ShelfContainerView.swift` — adds `@EnvironmentObject private var ocrService: OCRService` to the views that already have `conversionService`. Generalizes the progress overlay to take `progress: Double?` and `onCancel: () -> Void` directly, then computes `progress = ocrService.progress[item.id] ?? conversionService.progress[item.id]` at the call site. Both call sites of `ShelfContextMenu.make(...)` pass the new service.
- `App.swift` — instantiate `private let ocrService = OCRService()`, subscribe to its `completedSearchable` (→ `manager.addFile(url:to:)`), `completedExtracted` (→ `manager.addText(_:to:)`), and `failed` (→ `showToast`). Inject via the existing `ShelfContainerView` env-object plumbing. `applicationWillTerminate` calls `ocrService.cancelAll()` alongside `conversionService.cancelAll()`.

## Data Flow

```
User picks "Make Searchable" or "Extract Text"
        │
        ▼
ShelfItemActions selector → OCRService.enqueueMakeSearchable(...)  /  enqueueExtractText(...)
        │
        ▼
OCRService runs PDFOCR.makeSearchable / .extractText / ImageOCR.extractText
        │  reports per-page progress via Combine-backed @Published
        ▼
ShelfContainerView observes published progress; draws spinner / progress bar on the source card
        │
        ▼
On success:
  Make Searchable → completedSearchable → ShelfManager.addFile(url:to:) → existing insert animation
  Extract Text    → completedExtracted  → ShelfManager.addText(_:to:)   → text snippet appears in shelf
On failure/cancel: toast + UI returns to idle
```

## Testing

- Unit-testable pieces:
  - `OCRMenu.targets(for: [ShelfItem])` analog — pure function over UTIs and current-task state.
  - `RecognizedLine` data shape and merging logic for multi-page text concatenation.
- Integration testable on Apple Silicon dev machines:
  - A single synthetic PDF generated via `CGContext` from a known string of text (drawn as a real font, then rasterized via the rebuild path so it looks like a scanned page) → `extractText` should return the original string with high recall.
- Vision is opaque to unit tests — recognition quality on real images is not something we'll assert in tests. Manual verification covers that.

## Open Questions / Follow-ups (not blocking v1)

- Detect "PDF appears searchable already" and prefix the toast / disable the menu entry.
- Language picker (when auto-detect picks the wrong language).
- Annotation-based path as an option for users who want to preserve byte-perfect original imagery.
- Re-OCR specific page ranges instead of the whole document.
- Bulk export: "Extract text from all items in this shelf to a single text file."
