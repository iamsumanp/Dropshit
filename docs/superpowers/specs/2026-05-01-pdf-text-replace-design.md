# PDF Text Replace (v1) — Design

**Date:** 2026-05-01
**Status:** Draft (pending user review and approval)
**Scope:** Free-tier "edit existing PDF text" via the overlay approach — cover the original text with a sampled-background rectangle and draw replacement text on top, then flatten via the same rebuild pipeline used by OCR Make Searchable. Apple frameworks only (PDFKit + CoreGraphics + CoreText). No paid SDKs, no AGPL libraries, no MIT-license change.

## Goal

Right-click a PDF in a shelf → **Replace Text…** opens a small editor window. Inside the window the user selects a range of text, types a replacement, and the result is rendered live as an overlay annotation. Multiple replacements may be made in one session. **Save Edits** writes a sibling PDF (`<stem> (edited).pdf`) where every replacement is flattened into the page imagery and only the new text remains selectable/searchable. The original PDF is untouched.

## Non-Goals (v1)

- Inserting brand-new text in an empty region of the page (every edit must replace an existing text range).
- Right-to-left scripts, complex layout (Devanagari, Arabic). Vision-and-PDFKit's font/selection model assumes left-to-right.
- Editing form fields. (Form fill-in is its own design — see open follow-ups.)
- Rotating, reordering, deleting, or merging pages. (Page-level editing is its own track.)
- Annotations beyond the implicit ones we use (highlight, free-text comment, signatures). Those are a future design.
- Editing scanned PDFs. We rely on PDFKit text selection to detect font/color/bounds; scanned PDFs have no selectable text and produce no usable selection. The menu entry is **disabled** for PDFs whose selectable text content is empty (we run a quick check at menu build time).
- Undo within the editor. The user discards changes by closing the window without saving.
- Multi-PDF batch edit.

## User Flow

1. User right-clicks a PDF item in a shelf → **All Actions** submenu shows **Replace Text…** (only when the PDF has selectable text).
2. The action opens a new window: a `PDFView` showing the source document, a slim toolbar (`Save Edits`, `Cancel`, edit count), and a status footer.
3. User scrolls / pages through the document. The cursor behaves like Preview's text-selection cursor.
4. User click-drags across a run of text. On mouseup, a small popover anchored under the selection appears with a single text field labeled `Replace with:` and an OK button. Pressing Enter or clicking OK confirms; Escape cancels.
5. The selected range is now hidden by a rectangle annotation filled with a sampled-background color, and the typed replacement is drawn on top via a free-text annotation matching the original font / size / color.
6. The user can repeat steps 4–5 across the document. Each pending edit is reflected live in the PDFView via PDFKit annotations.
7. Clicking an existing edit overlay puts it in "selected annotation" mode; pressing Delete removes that edit.
8. **Save Edits** produces a sibling `<stem> (edited).pdf` next to the source on disk and adds it as a new shelf item. Original stays put. The window closes.
9. **Cancel** (or closing the window) discards all pending edits.

## Output Behavior

- Output filename: `<source stem> (edited).pdf` written next to the source.
- Collision: append `(1)`, `(2)` via the existing `UniqueDestination` helper.
- Source dir not writable: fall back to `~/Library/Caches/Dropshit/Edits/`, same probe-write pattern as OCR / Conversion.
- Atomic write: render to a `.partXXXX.pdf` sibling, rename into place on success.
- The new PDF is added to the same shelf as a sibling item.
- The output is **flattened**: every page is a JPEG-0.9 image of the original page (with the rectangles and replacement text drawn into the bitmap), with the user's new text *additionally* rendered as visible CoreText so it remains selectable and searchable. The original glyphs are NOT preserved as text content — they exist only as residual pixels under the rectangle, fully covered.

## Engine

- **Selection / font detection:** `PDFView.currentSelection`. From the selection's `attributedString`, read `NSAttributedString.Key.font` and `.foregroundColor` for the first character. Use these to render the replacement.
- **Bounds:** `PDFSelection.bounds(for:)` per page gives the rectangle to cover.
- **Background sampling:** render a small region of the page (the union of the selection rect plus a few-pixel margin) at the on-screen DPI, average the perimeter pixels, use that as the rectangle's fill color. Falls back to white when the perimeter sample is empty (selection touches the page edge).
- **Live preview in the editor:** add two `PDFAnnotation`s per edit — a `square` annotation as the cover, a `freeText` annotation as the replacement text. PDFKit renders both inline. Edits are kept in an in-memory model; the source `PDFDocument` shown in `PDFView` is loaded from a copy so the original on disk is never mutated.
- **Save flatten:** the same rebuild pipeline as OCR `makeSearchable` — render each page to JPEG quality 0.9 at 150 DPI, draw the rectangles + replacement text on top via `CGContext` with regular (visible) text drawing. Atomic `.partXXXX.pdf` rename.

## Encoding Defaults (no UI)

- Output JPEG quality: **0.9** (matches OCR rebuild).
- Render DPI for rebuild: **150 DPI**.
- Background sample: **2-pixel-wide perimeter** of the union rect, mean pixel.
- Replacement text uses the original font name & size when the font resolves on the system; otherwise falls back to **Helvetica** at the original size with a one-shot toast (`"Original font '<name>' not installed; using Helvetica."`) the first time per session.
- Replacement text color: detected foreground color, or `NSColor.black` when missing.

## Async / Progress UI

- Editor window is interactive — the live overlays are immediate (no progress UI needed).
- Save flatten runs through `PDFEditService` (a third `@MainActor ObservableObject`, mirroring `ConversionService` / `OCRService`). The save runs synchronously on a background queue and reports per-page progress to the editor window's footer.
- Save UI: the toolbar's `Save Edits` button transitions to a thin progress bar while flattening; on completion the window closes and the new shelf item appears with the standard insert animation.
- Cancellation during save: a small ✕ on the progress bar invalidates the in-flight save, deletes the `.part` file. (User stays in the editor window; pending edits persist.)

## Failure Handling

`enum PDFEditError: Error, Equatable`:

- `.sourceMissing`
- `.sourceUnreadable` (corrupt, encrypted, or no selectable text — handled before the editor opens)
- `.destinationUnwritable`
- `.flattenFailed(reason: String)`
- `.cancelled`

Surfaces as a toast via the existing `showToast(_:near:)` helper. `.cancelled` is silent.

The "no selectable text" check happens at menu build time (PDFKit `PDFDocument.string` returns nil-or-empty); when it fails the **Replace Text…** menu entry is omitted entirely. We don't open an empty editor.

## Edge Cases

- **Multi-line selection** — `PDFSelection` reports an array of bounds, one per line. We add one rectangle annotation per line bound, plus a single free-text annotation across the union.
- **Selection spans multiple pages** — disallowed; the OK button stays disabled until the selection is single-page.
- **User selects a range with mixed fonts/sizes** — we sample the first character's font for the replacement. The toast warns when this happens (`"Selection has mixed formatting; using first character's font."`) so the user isn't surprised when the result looks slightly off.
- **Replacement text wider than the original bounds** — the free-text annotation autosizes; if the result extends past the page edge it wraps. Wrapping into surrounding content is the user's problem to manage; we don't reflow the rest of the page (impossible without full-document layout).
- **Replacement text empty** — the rectangle still goes down (effectively a redaction). This is a feature.
- **PDF is encrypted** — `PDFDocument(url:)` returns nil → toast, no editor.
- **PDF has selectable text on some pages and not others** — editor opens; pages without text simply have nothing for the user to select. No special handling needed.
- **App quits while save is in progress** — `applicationWillTerminate` calls `pdfEditService.cancelAll()`; atomic write rule means no orphan `.partXXXX.pdf`.
- **User makes 0 edits and clicks Save** — `Save` is disabled until `editCount > 0`.

## Architecture

New folder: `Sources/ShelfDemo/PDFEdit/`.

| File                       | Purpose |
| -------------------------- | ------- |
| `PDFEditError.swift`       | Error enum + display strings. |
| `PDFEditModel.swift`       | Pure data types: `struct PDFTextEdit { id, pageIndex, lineRects: [CGRect], replacement: String, font: NSFont, color: NSColor, backgroundColor: NSColor }`, plus a `PDFEditDocument` value type holding `var edits: [PDFTextEdit]`. |
| `PDFEditView.swift`        | The `NSViewRepresentable`-wrapped `PDFView` with annotation overlay logic, selection-to-popover wiring. |
| `PDFEditWindow.swift`      | `NSWindowController` hosting a SwiftUI root that contains the `PDFView` plus toolbar + footer. Handles open/close lifecycle. |
| `PDFEditFlatten.swift`     | Page rendering + annotation flattening. Reuses the rebuild approach from `PDFOCR.makeSearchable` — a `CGPDFContext` consumes per-page JPEG-0.9 imagery overlaid with rectangles and visible CoreText. |
| `BackgroundSampler.swift`  | Pure helper. `static func sampleColor(in bounds:CGRect, of page:PDFPage) -> NSColor`. |
| `PDFEditService.swift`     | `@MainActor ObservableObject` with `progress: [UUID: Double]`, `completed`/`failed` Combine subjects, `func enqueueSave(...)`, `func cancel(itemID:)`, `func cancelAll()`. Mirrors `OCRService` / `ConversionService`. |

Edits to existing code:

- `Sources/ShelfDemo/ShelfContextMenu.swift` — add **Replace Text…** menu item to `makeAllActionsMenu` for PDFs that have selectable text. Adds `weak var pdfEditService: PDFEditService?` and `@objc func replaceText(_:)` selector that opens a `PDFEditWindow`.
- `Sources/ShelfDemo/ShelfContainerView.swift` — propagate `pdfEditService` env-object alongside the existing `conversionService` / `ocrService`. Both call sites of `ShelfContextMenu.make(...)` pass it.
- `Sources/ShelfDemo/App.swift` — instantiate `PDFEditService`, subscribe to its `completed` (→ `manager.addFile(url:to:)`) and `failed` (→ existing toast). Inject as env object. `applicationWillTerminate` calls `pdfEditService.cancelAll()`.

The `PDFEditWindow` deliberately runs as a separate, full-app window (not a panel). Editing PDF text is a focused activity; the floating non-activating shelf panel doesn't have the right interaction model for typing. The window is created lazily on first **Replace Text…** invocation, retained on the AppDelegate, and closes (without releasing) on `Save` or `Cancel`. Multiple instances are not allowed in v1 — opening Replace Text on a different PDF while one is already open simply brings the existing window to front showing the originally-opened document. (User must save or cancel that one first.)

## Data Flow

```
User → "Replace Text…"
  → PDFEditWindow opens with a copy of the PDFDocument
    → user makes edits (each = one entry in PDFEditDocument.edits)
       → preview shows via PDFAnnotations on the live PDFView
  → user clicks Save Edits
    → PDFEditService.enqueueSave(edits, source, shelfID)
       → background queue runs PDFEditFlatten.flatten(...)
          → per-page progress published
       → on completion → completed.send((url, shelfID))
          → AppDelegate adds to shelf → window closes
       → on failure → failed.send(error)
          → AppDelegate shows toast → window stays open with edits intact
```

## Testing

- Unit-testable pieces:
  - `BackgroundSampler.sampleColor(...)` — deterministic; can test with synthesized CGImage fixtures.
  - `PDFEditDocument` mutations (add edit, delete edit by id) — pure value-type tests.
  - `PDFEditFlatten.outputDestinationURL(for:)` — same UniqueDestination pattern.
- Integration-testable on Apple Silicon dev machines:
  - A small synthetic PDF with known text, programmatically render with `CGContext` from a known string. Open it, make a known edit, flatten, re-extract text via `PDFDocument.string` of the output, assert it contains the replacement and not the original.
- Manual verification covers the editor UX (selection-to-popover, multi-line bounds, font matching, background sampling).

## Open Questions / Follow-ups (not blocking v1)

- Insert new text at a clicked point (no selection required).
- Annotations track: highlight, strikethrough, sticky note, freehand drawing, trackpad signature.
- Form fill-in (different code path; uses PDFKit form-field annotations).
- Per-edit re-edit (click an existing edit, change the replacement text without deleting first).
- Find-and-replace across the document.
- Color-mode awareness: the editor today behaves the same in light/dark; replacement-text color tracks original text color, so it usually does the right thing.
- Remember the last replace-text input width preference.
