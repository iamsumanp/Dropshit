# UI Localization — Design

## Goal

Translate every user-facing string in Dropshit into 7 additional languages, with a Settings picker that lets the user override their system locale.

## Out of scope

- OCR recognition language (the `automaticallyDetectsLanguage` flag in `OCREngine.swift` stays as-is for now).
- Right-to-left layout polish. Arabic / Hebrew not in initial language set; we don't audit RTL mirroring.
- Plural/gender rules beyond what String Catalog auto-handles for our small set of plural strings.

## Languages

Default = the user's system language (macOS picks automatically). The Settings picker also lets the user override.

| Code      | Language              |
|-----------|-----------------------|
| en        | English (base)        |
| pl        | Polish                |
| de        | German                |
| fr        | French                |
| es        | Spanish               |
| it        | Italian               |
| zh-Hans   | Chinese (Simplified)  |
| ja        | Japanese              |

Adding more later is cheap once the catalog is in place.

## Infrastructure

**String Catalog (`Localizable.xcstrings`).** Apple's modern format (Xcode 15+, runtime works on macOS 13+). Single JSON-backed file, all 8 languages in one place, autogenerates plural variants.

Lives at `Sources/ShelfDemo/Resources/Localizable.xcstrings`. Declared in `Package.swift` via `.process("Resources")` so SwiftPM bundles it into `Bundle.module` — and additionally we write a tiny shim that resolves `Bundle.main` lookups to `Bundle.module` for AppKit code paths that don't accept an explicit bundle.

### Replacement patterns

- **SwiftUI**: `Text("Settings")` → `Text("Settings", bundle: .module)` (SwiftUI auto-localizes string literals via `LocalizedStringKey`).
- **AppKit / plain Swift**: `"Rename Shelf"` → `String(localized: "Rename Shelf", bundle: .module)`.
- **Format strings**: `"\(count) Files"` → `String(localized: "\(count) Files", bundle: .module)` (String Catalog supports interpolations, generates `%lld` placeholders, and keeps language-specific plural variants).
- **Dynamic strings built from data** (e.g. file names) stay as-is; only the surrounding chrome is localized.

### Override mechanism

Standard Cocoa pattern: write `AppleLanguages` to `UserDefaults.standard` at app launch *before* any localized lookup happens. macOS reads it once during `NSBundle` init.

```swift
// In App.swift's main entry, BEFORE anything else
LanguagePreference.applyAtLaunch()
```

`LanguagePreference` is a tiny enum-backed store:
- `.system` (default) → don't touch `AppleLanguages`, let macOS pick.
- `.explicit(code)` → write `["pl"]` (or whatever) into `AppleLanguages` *user-defaults key*.

Switching language requires a **relaunch** to take effect. The Settings picker shows an inline note and a "Quit & Reopen" button that re-execs the app via `NSWorkspace`.

## Settings UI

New section at the top of `SettingsView.swift`:

```
Language: [System Default ▾]   ← native picker
ⓘ Takes effect on next launch.   [Quit & Reopen]
```

The button only appears when the selection differs from the currently-applied language.

## String inventory (rough)

From a grep pass: ~100 strings, distributed roughly as:

- Settings (~15): titles, descriptions, toggles
- Status-bar / app menus (~25): "Recent Shelves", "Activate for", "Quit", etc.
- Shelf context menu (~30): "Rename…", "Resize…", "Compress…", "Open With", etc.
- Alerts (~20): titles + informative text + button labels
- Inline UI (~10): "Drop files here", "Loading…", "Empty folder", etc.

Plural strings spotted:
- `"\(count) edit\(count == 1 ? "" : "s")"` → catalog plural rule
- `"\(shelf.items.count) Files"` → catalog plural rule
- `"\(count) · \(subtitle)"` interpolation

## Translation source

I'll author the translations directly (Claude in this session). For our string set — short UI labels, settings descriptions, alert text — quality is high enough to ship. Suman can spot-check Polish; native-speaker review is a later polish pass, not a blocker.

I'll keep translations conservative: prefer literal accuracy over idiomatic flair, since UI strings have functional meaning. Where macOS has a standard convention (e.g. "Quit" in German is "Beenden"), I match it.

## File-by-file impact

| File                                       | Strings | Notes                                                 |
|--------------------------------------------|---------|-------------------------------------------------------|
| `App.swift`                                | ~10     | Status menu items, window title                       |
| `SettingsView.swift`                       | ~10     | All static labels + descriptions                      |
| `ShelfActionMenu.swift`                    | ~20     | Action menu titles, alerts                            |
| `ShelfContextMenu.swift`                   | ~25     | Context menu titles, image-action submenu, alerts     |
| `ShelfContainerView.swift`                 | ~5      | "Loading…", "Empty folder", "Reveal in Finder"        |
| `CollapsedShelfView.swift`                 | ~3      | "Drop files here", "Drop or shake here"               |
| `ImageActions.swift`                       | ~6      | Resize/Compress alerts                                |
| `PDFEdit/PDFEditRoot.swift`                | ~6      | (parked branch — defer until merged)                  |
| `OCR/OCRMenu.swift`                        | ~3      | "Make Searchable", "Extract Text", error strings      |
| `Conversion/ConversionMenu.swift`          | ~5      | "Convert to ▶", target labels                         |
| Service progress strings                   | ~5      | "OCR…", "Converting…", error messages                 |

## Testing

- `swift build` clean.
- `swift test` — existing tests must still pass. No new tests for translations themselves (low value).
- Manual smoke (mandatory):
  - Launch with default → verify English unchanged.
  - Switch to Polish via Settings → relaunch → status menu, context menu, settings all in Polish.
  - Switch to Japanese → verify Asian glyph rendering.
  - Switch back to System Default → relaunch → returns to system locale.

## Risks / open questions

- **AppKit menu titles set via `NSMenuItem(title:)` won't auto-localize.** Every site needs an explicit `String(localized:)` call. There are ~50 such sites — the inventory pass surfaces them.
- **String Catalog + SwiftPM**: works, but `.process("Resources")` puts strings in `Bundle.module`, not `Bundle.main`. SwiftUI's `Text("...")` defaults to `Bundle.main`. We pass `bundle: .module` explicitly everywhere. Boilerplate but mechanical.
- **Quit & Reopen via `NSWorkspace.shared.openApplication`**: fine for `.app` builds, awkward for raw SwiftPM debug builds. Acceptable tradeoff — dev users can quit/relaunch manually.
- **Shorter Asian-language strings can break layout.** Most of our UI is text-driven with `fixedSize` so it should grow naturally; spot-check during smoke test.

## Effort estimate

1-2 sessions:
- Session 1: scaffold + inventory + replace strings + author en/de/fr/es/it base translations.
- Session 2: pl/zh-Hans/ja translations + Settings picker + smoke test + commit.
