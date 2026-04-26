# Dropshit

A free, open-source macOS shelf for files. Drag stuff in, drop it out wherever you need it later.

It's an exact clone of [Dropover](https://dropoverapp.com/) — same shake-to-summon shelf, same drop-anywhere-to-collect workflow, same drag-out-to-deliver behavior — except free.

## Why

Dropover is a great paid app. Dropshit is the same idea, written from scratch as a single SwiftPM target, free under the MIT license. If Dropover does what you need and you want to support its author, buy Dropover. If you want a free tool that does the same thing without a license server, this is it.

## What it does

- **Shake a Finder drag** to summon a floating shelf at the cursor. Drop the files onto it.
- **Drop anywhere on screen** while a shelf is open to add files, images, or text.
- **Drag back out** to any app — Finder, browser upload zones, Mail, Slack, Messages, anywhere that accepts a file URL.
- **Dock to the screen edge** for ambient access; the shelf becomes a tab you can hover or drop onto.
- **Multiple shelves** at once, each with its own floating panel.
- **Auto-expiry** — shelves clean themselves up after a configurable retention window.

## Features

- Drag from Finder *or* drag back out to any drop target — including web upload widgets, since the pasteboard exposes both `NSFilePromiseProvider` and `public.file-url`.
- Drag preview matches the rendered card (image thumbnail, text preview, or doc card) instead of a generic file icon.
- Aspect-ratio-aware cards: a landscape photo shows wide-and-short, a portrait shows tall-and-narrow — both uncropped.
- File metadata in-line: dimensions for images (RAW/CR2/HEIC included), page count for PDFs, size for everything.
- Quick Look on space, batch rename, ZIP archive, Move to Trash, Show in Finder, AirDrop, Messages, Open With…
- Auto-pruning of items whose backing files were trashed from Finder while you weren't looking.
- Menubar status icon flips between resting (`[ ·]`) and "ready to receive" while a drop is in flight.
- Liquid-glass-ish floating panel (vibrant blur + subtle stroke) that approximates macOS Tahoe's `.glassEffect()` on macOS 13+.

## Install

### Pre-built DMG

1. Download `Dropshit.dmg` from the latest release (or build it yourself, see below).
2. Mount the DMG, drag `Dropshit.app` to `/Applications`.
3. First launch on a new machine (the DMG is ad-hoc signed, not notarized):

   ```sh
   xattr -dr com.apple.quarantine /Applications/Dropshit.app
   ```

4. Launch — Dropshit lives in your menubar. Click the icon to see options; shake any Finder drag to summon a shelf.

### Build from source

Requires macOS 13+ and the Swift toolchain that ships with Xcode 15+ (Swift 5.9).

```sh
git clone https://github.com/<your-username>/dropshit.git
cd dropshit

# Run for development:
swift run ShelfDemo

# Build a signed .app and .dmg for distribution:
bash scripts/build-dmg.sh
# → produces dist/Dropshit.app and Dropshit.dmg in the repo root
```

`scripts/build-dmg.sh` regenerates the app icon (`scripts/make-icon.swift`), builds in release mode, ad-hoc signs, and packages a DMG with an `/Applications` symlink for drag-install.

## Project layout

```
Sources/ShelfDemo/
  App.swift                 NSApplicationDelegate, status item, panel lifecycle
  ShelfManager.swift        @MainActor store: shelves, items, persistence
  ShelfStore.swift          On-disk format (security-scoped bookmarks)
  Shelf.swift, ShelfItem.swift   Models
  FloatingPanel.swift       Non-activating NSPanel + vibrant blur backdrop
  ShelfContainerView.swift  Top-level SwiftUI view (collapsed / expanded / docked)
  CollapsedShelfView.swift  Stacked-card preview, drop target, X close
  ShelfDragSource.swift     NSDraggingSource overlay; file-promise + file-URL drag
  ShelfActionMenu.swift     Right-click and chevron action menu
  ShakeDetector.swift       Global drag-shake recognizer
  QuickLookController.swift Space-to-preview routing for QLPreviewPanel
  …

scripts/
  build-dmg.sh              Build → sign → DMG
  make-icon.swift           Renders the .iconset (16→1024) for AppIcon.icns
```

## Permissions

Dropshit doesn't ask for any special permissions. It uses macOS's stock drag pasteboard, security-scoped bookmarks for files added across reboots, and `CGEvent`-based mouse monitoring for the shake gesture (no accessibility prompt needed for `.leftMouseDragged` global monitors).

## Status

Personal project. Works for me. PRs welcome but no guarantees about responsiveness.

## License

MIT. See `LICENSE`.

## Credits

- Inspired by, and functionally a clone of, [**Dropover**](https://dropoverapp.com/) — go buy it if this helps you.
- Built with SwiftUI + AppKit on top of `NSPanel`, `NSFilePromiseProvider`, `QLThumbnailGenerator`, and `CGImageSource`.
