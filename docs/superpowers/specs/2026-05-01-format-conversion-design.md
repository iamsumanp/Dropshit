# Format Conversion (v1) — Design

**Date:** 2026-05-01
**Status:** Approved (pending implementation plan)
**Scope:** First sub-feature of a broader "tools on shelf items" track. Image/PDF editing are out of scope; they will be brainstormed separately.

## Goal

Let the user convert media files already on a shelf to a different format from a per-item right-click menu, without leaving the shelf UI. Specifically: HEIC/PNG/TIFF/WebP/JPEG image interop, and MOV/M4V/MKV/AVI → MP4 video.

## Non-Goals (v1)

- Audio conversion (e.g., m4a → mp3). MP3 encoding requires LAME, a third-party encoder, which we are not introducing.
- GIF (animated frames need a separate code path).
- Video trimming, cropping, frame extraction, codec selection, bitrate control.
- Image cropping, rotation, color adjustment, or any pixel-level edit.
- "Convert all" entry on the shelf action menu. Per-item context-menu only in v1.
- Parallel conversions inside a shelf.
- Any user-facing settings panel for conversion.

## User Flow

1. User right-clicks an item (or multi-selection) in a shelf.
2. The context menu shows a `Convert to ▶` submenu when at least one valid target exists for the selection.
3. User picks a target format. The submenu closes.
4. The source item card shows a spinner overlay while work is in flight. Long video conversions also show a thin linear progress bar under the card.
5. On completion, the converted file is added to the same shelf as a new item, using the existing insert animation. The original stays in place.
6. On failure, a toast appears with a short reason; the source item returns to its idle state.
7. Cancellation: a small ✕ on the overlay aborts the task; partial output is discarded.

## Conversion Matrix

| Source UTI / extension                | Targets offered            |
| ------------------------------------- | -------------------------- |
| `.heic` (HEIF)                        | JPEG, PNG                  |
| `.png`                                | JPEG                       |
| `.jpg` / `.jpeg`                      | PNG                        |
| `.tiff`                               | JPEG, PNG                  |
| `.webp`                               | JPEG, PNG                  |
| `.mov`, `.m4v`                        | MP4                        |
| `.mkv`, `.avi` (best-effort)          | MP4                        |
| Anything else                         | (not offered; submenu hidden) |

For multi-selection, the offered targets are the **intersection** of per-item targets. Example: 3 HEIC + 1 PNG selected → submenu shows "JPEG" only (PNG would be wrong for the source PNG, so it's excluded).

If the intersection is empty, the submenu is omitted from the context menu entirely.

## Output Behavior

- Default destination: same directory as the source. `~/Downloads/foo.heic` → `~/Downloads/foo.jpg`.
- Name collision: append a Finder-style suffix. `foo.jpg` exists → write `foo (1).jpg`. Probe sequentially until a free name is found.
- Source directory not writable (Photos library, sandboxed location, read-only volume) → fall back to `~/Library/Caches/Dropshit/Converted/`, creating the directory if needed. "Not writable" is determined empirically: attempt to create the temp output file; if it fails with `EACCES`, `EPERM`, or `EROFS`, switch to the fallback directory and try again.
- The converted file is added to the same shelf as the source item, alongside it. The source item is **not** removed.
- Writes are atomic: the encoder writes to a sibling temp file (e.g., `foo.jpg.part`) and renames into place on success. A crash, cancel, or failure leaves no partial output at the final path.

## Encoding Defaults (no UI)

- **JPEG**: quality `0.9`, sRGB color space, no EXIF orientation flattening surprises (preserve original orientation tags).
- **PNG**: lossless, default zlib compression.
- **Video → MP4** (note: MKV/AVI are best-effort — AVFoundation only reads the container if the codec inside is one it understands; e.g., H.264/H.265 inside MKV usually works, VP9/AV1 usually does not. When `AVURLAsset.isReadable` is `false`, the submenu entry is omitted for that file, and a runtime failure surfaces as a toast):
  - If source video codec is already H.264 and audio codec is AAC (or there is no audio track) → `AVAssetExportPresetPassthrough`. This is a fast, lossless remux into an MP4 container.
  - Otherwise → `AVAssetExportPresetHighestQuality`. Re-encodes to H.264 + AAC at the source's natural resolution.
  - `outputFileType = .mp4`.
  - `shouldOptimizeForNetworkUse = true` (cheap, makes the output friendlier to streaming).

## Async / Progress UI

- All conversion work runs off the main thread through a single `ConversionService` actor.
- Conversions run **sequentially** across the whole app — at most one task at a time. Reasoning: avoids CPU/disk thrash on long videos and keeps progress UI predictable. (If we ever want parallel, that's a follow-up.)
- Image conversions typically complete in well under 100 ms and the spinner may not be perceptible; that is acceptable.
- Video conversions show a thin linear progress bar under the card, driven by `AVAssetExportSession.progress` polled at ~10 Hz.
- A small ✕ on the overlay cancels the in-flight task. On cancel: invalidate the export session (or stop the ImageIO destination), delete the `.part` file, return the card to idle.
- App quitting (`applicationWillTerminate`) → cancel all in-flight tasks. No orphan `.part` files because of the atomic-write rule.

## Failure Handling

- Toast banner reusing the existing `showDuplicateToast` style: e.g., "Conversion failed: source file no longer exists" or "Conversion failed: codec unsupported".
- Underlying error logged via `NSLog`.
- No retry UI, no modal dialog.

## Edge Cases

- **Source trashed mid-task**: detected when the encoder reports a read failure, or up-front via `FileManager.fileExists`. Toast, abort.
- **Same-target-as-source** (e.g., user picks PNG for a `.png`): never offered in the submenu.
- **Item already converting**: the submenu entries for that item are disabled until the current task ends.
- **Multiple items in selection where one is invalid for the chosen target**: cannot happen because of the intersection rule above.
- **Concurrent right-clicks**: the conversion service queues new tasks; first-in, first-out.
- **Disk full**: surfaced as a toast.
- **Permission denied at fallback dir**: fall through to a one-shot toast and abort.

## Architecture

New folder: `Sources/ShelfDemo/Conversion/`.

| File                       | Purpose                                                                                       |
| -------------------------- | --------------------------------------------------------------------------------------------- |
| `Converter.swift`          | Public types: `enum ConversionTarget` (`jpeg`, `png`, `mp4`), `struct ConversionTask`, `actor ConversionService`. The service owns active tasks and exposes Combine publishers for progress and completion. |
| `ImageConverter.swift`     | ImageIO implementation. Internal to `Conversion`. Uses `CGImageSourceCreateWithURL` and `CGImageDestinationCreateWithURL`. |
| `VideoConverter.swift`     | AVFoundation implementation. Internal to `Conversion`. Uses `AVURLAsset` + `AVAssetExportSession`. Codec inspection picks pass-through vs re-encode. |
| `ConversionMenu.swift`     | Builds the `Convert to ▶` submenu given a `[ShelfItem]` selection. Handles target intersection and same-target-as-source filtering. |

Edits to existing code:

- `ShelfContextMenu.swift` — call into `ConversionMenu` and insert the resulting submenu after the existing actions when non-empty.
- `ShelfContainerView.swift` — overlay a spinner / progress bar on item cards based on per-item state from `ConversionService`. Reuses existing item-id state plumbing rather than introducing a new selection model.
- `ShelfManager.swift` — small extension to add a converted file to a specific shelf (mirrors how dropped files are added today).
- `App.swift` — wire `ConversionService` lifecycle: instantiate in `AppDelegate`, cancel all on `applicationWillTerminate`.

## Data Flow

```
User picks "Convert to JPEG"
        │
        ▼
ConversionMenu action → ConversionService.enqueue(task)
        │
        ▼
ConversionService runs ImageConverter or VideoConverter on a background queue
        │     emits progress updates via Combine
        ▼
ShelfContainerView observes published progress per item, draws spinner / bar
        │
        ▼
On success: ShelfManager.addItem(url:in:) → shelf publishes an updated items array → existing insert animation runs
On failure/cancel: toast + UI returns to idle
```

## Testing

- Unit-testable pieces:
  - `ConversionMenu.targets(for: [ShelfItem])` — pure function over UTIs and current-task state.
  - Name-collision resolver — pure function over `(URL, FileManager)`.
- Integration: a small set of fixture files (one HEIC, one short MOV) committed to the repo; a test harness can run real conversions through the service in a temp dir.
- Manual: ensure spinner appears for video and progress bar advances; ensure toast for missing source; ensure cancel leaves no `.part` file behind.

## Open Questions / Follow-ups (not blocking v1)

- "Convert all to ▶" entry on the shelf action menu, if used frequently.
- Audio formats (likely scoped to AAC/M4A only since LAME is off the table).
- GIF support, including animated → MP4.
- A future "edit" track (image rotation/crop, PDF page reorder/sign) — separate spec.
