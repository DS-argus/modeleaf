# Modeleaf

A native, read-only macOS PDF viewer with a compact Vim-style command model, first-class tabs, and strict TOML customization.

## Documentation

- [한국어 README](docs/README.md)
- [Configuration reference (English)](CONFIG.md)
- [설정 가이드 (한국어)](docs/CONFIG.md)

The interaction design takes one focused idea from [Sioyek](https://github.com/ahrm/sioyek): configurable, keyboard-first navigation with short multi-key sequences. It is intentionally **not** a Sioyek clone. V1 keeps only the reading loop, adds native tabs, and uses restrained AppKit chrome so the PDF stays visually dominant.

## What it does

- opens local PDFs from the app, Finder/Open With, or the default `⌘O` binding;
- keeps multiple documents in independent tabs, with clickable tab controls and a `+` button that opens another PDF;
- splits the reading surface with tmux-style split-in-place on the active pane: either orientation may be first, both asymmetric three-pane shapes and both 2×2 orientations are reachable, and each pane owns its own tabs and active document;
- opens each document on page 1 fitted inside the visible canvas;
- scrolls, changes pages, jumps to a numbered page, zooms, and fits the view;
- searches embedded PDF text with per-tab result state and highlighting;
- routes every app-owned command through one stable action registry;
- lets every reader action and navigation value be changed in TOML;
- preserves the source file: the production boundary exposes no save or edit workflow.

The shipped bindings stay deliberately small:

| Intent | Default |
|---|---|
| small scroll | `h` `j` `k` `l` |
| large scroll | `d` / `u` |
| next / previous page | `n` / `p` |
| first / last page | `gg` / `G` |
| page 12 | `g12`, then `Enter` |
| next / previous tab | `N` / `P` |
| select tab 1…9 | `⌘1` … `⌘9` |
| split right / down | `Ctrl-b \|` / `Ctrl-b -` |
| focus left / down / up / right | `Ctrl-h` / `Ctrl-j` / `Ctrl-k` / `Ctrl-l` |
| unsplit | `Ctrl-b o` |
| search | `/`, then `Enter` |
| next / previous match | `Enter` / `Shift-Enter` |
| clear search | `Esc` |
| zoom in / out | `=` / `-` |
| theme picker | `Shift-t` (live preview; selection persists) |
| fit width / page | `w` / `f` |

In fit-page mode, `j`/`d` move to the next page and `k`/`u` to the previous page. After manual zoom, each scroll key moves only along an axis where the page exceeds the viewport; Modeleaf does not inflate the configured zoom or pan into blank space. Actual Size remains in the View menu and is configurable as `view.zoomReset`, but has no default key.

Tabs remain keyboard-first, but can also be selected and closed with the pointer. Their compact fixed-width labels omit `.pdf` and truncate at the end when necessary. The right-side `+` button dispatches the same read-only PDF open action as `⌘O`.


### Pane layout and focus

Pane layout is structurally limited to one through four panes at depth one. `Ctrl-b |` and `Ctrl-b -` split the active pane in place; either orientation can be the first split, and both asymmetric three-pane shapes plus both 2×2 orientations are reachable. A parallel request or a request against an already split band is a strict no-op. A new pane opens the active pane's current page fit-to-page in its own bounds — the reading position carries over but the zoom fits the new, smaller pane. `Ctrl-b o` is global close-others: it keeps the active pane and closes every other pane.

Focus crosses geometry in the same slot; only a full-span pane crossing into a split band uses that band's most recently focused slot, falling back to its first slot. Boundary movement is a no-op. The traffic-light inset belongs only to the top-left pane.
See [CONFIG.md](CONFIG.md) for the exhaustive 44-action registry, key-token grammar, validation rules, numeric bounds, and generated default file.

## Explicit v1 boundary
V1 has no bookmarks, user-authored annotations or highlights, marks, portals, smart jumps, command palette, external commands, scripts, plugins, macros, OCR, print, export, session persistence, thumbnail sidebar, or research-library workflow. Search highlighting is transient viewer state and is never written to the PDF.

These omissions are product constraints rather than half-implemented menu items. Any later expansion must preserve the stable action boundary, strict declarative configuration, per-tab session isolation, and read-only PDFKit adapter.

## Requirements and technology

- macOS 14 or newer;
- Swift 6 language mode with complete strict-concurrency checks;
- AppKit for the application shell and responder chain;
- PDFKit for native rendering and embedded-text search;
- Foundation-only `PDFReaderCore` for actions, keys, config, tabs, and themes;
- exact-pinned `TOMLDecoder` 0.4.5 at the app edge;
- Swift Testing, XCTest, and XCUITest targets.

The six bundled themes are the dark **Tokyo Night**, **Gruvbox Dark**, **Solarized Dark**, **Dracula**, and **Everforest** plus the light **Catppuccin Latte**. Pick one at runtime with the theme picker (`Shift-t`, live preview); the choice is saved in an app-managed state file, not `config.toml`. Themes affect app chrome, the surrounding PDF canvas, prompts, status, and transient search highlights; PDF page pixels are not recolored.

## Build and run

### Recommended local Release app

For normal reading and performance checks, build the signed Release app rather
than using the SwiftPM debug runner:

```sh
APP=$(Tools/build_release_app.sh | tail -n 1)
open "$APP"
```

The helper regenerates and validates the Xcode project, builds a local Release
bundle, applies an ad-hoc signature, and verifies that signature. It does not
need an Apple Developer account, Accessibility, Input Monitoring, Automation,
or Screen Recording permission.

### Xcode app

```sh
python3 Tools/generate_xcode_project.py
python3 Tools/validate_xcode_project.py
open Modeleaf.xcodeproj
```

Select the shared `Modeleaf` scheme and run it on **My Mac**. The generated project targets macOS 14+ and contains the app, core, support, unit, integration, and UI-test targets.

### SwiftPM development harness

```sh
swift package resolve
swift build -c debug
swift run Modeleaf
```

After `Build of product 'Modeleaf' complete!` appears, the terminal remains attached while the GUI app runs; this is normal. The **Modeleaf** window should open automatically. Use `⌘O` to choose a PDF, `⌘Q` to quit normally, or `Control-C` to stop the development process from the terminal.

The Swift package is retained as a deterministic command-line build/test harness for the same production sources. `Package.resolved` pins the only third-party dependency.
Because this path runs an unoptimized development build under SwiftPM, startup
and first-PDF rendering can feel slower than the Release app above.

## Configuration

The app reads configuration once at launch from:

```text
~/.config/modeleaf/config.toml
```

It does not create or rewrite that file. To start customizing it:

```sh
mkdir -p ~/.config/modeleaf
cp PDFReaderApp/Resources/DefaultConfig.toml ~/.config/modeleaf/config.toml
```

Example:

```toml
[keymap]
"scroll.down" = ["j", "<Down>"]
"scroll.up" = ["k", "<Up>"]
"page.next" = ["n"]
"page.previous" = ["p"]
"tab.next" = ["N"]
"tab.previous" = ["P"]
"tab.select.1" = ["<D-1>"]

[navigation]
small_scroll_points = 56.0
large_scroll_viewport_fraction = 0.85
zoom_factor = 1.12

[input]
prefix_timeout_ms = 350
```

The theme is not configured in TOML — choose it in-app with the theme picker (`Shift-t`). A legacy `[theme]` section in an existing config is ignored with a deprecation warning and does not invalidate the rest of the file.

Configuration is strictly declarative. Unknown keys, invalid action IDs, unsafe prompt bindings, conflicts, wrong types, or out-of-range values reject the **entire** user file. The complete built-in configuration then activates atomically. The status line summarizes every error and warning; its tooltip and accessibility help expose the full aggregated diagnostics. A missing file is normal and uses the built-ins without an error.

Restart the app after changing the file; live reload is outside v1.

## Architecture

```text
PDFReaderCore          Foundation-only policies and deterministic state machines
        ↑
PDFReaderApp           AppKit/PDFKit adapters and the composition root
        ↑
ReaderSessionStore     sole owner of one isolated session per tab
```

- Menu items, key bindings, prompt controls, and tests dispatch the same `ActionID` values.
- The window-scoped responder path owns key input; prompts keep native text, dead-key, and IME behavior.
- Each tab owns one `PDFDocument`, one `PDFView`, and one serialized search coordinator.
- Invalid config never partially activates.
- PDFKit mutation, print, link-action, and inherited editing capabilities are blocked at the app boundary and regression-tested.

The deterministic Xcode graph is generated by `Tools/generate_xcode_project.py`; do not hand-edit `Modeleaf.xcodeproj/project.pbxproj`.

## Verification

```sh
python3 Tools/generate_xcode_project.py
python3 Tools/validate_xcode_project.py
swift package resolve
swift build -c debug
swift build -c release
swift test
swift test -Xswiftc -warnings-as-errors
```

The crash-containment and Release-build checks can also be run without GUI
automation permissions:

```sh
Tools/evaluate_pdfkit_fast_open.sh \
  --manifest artifacts/verification/pdfkit-fast-open/reproducer-manifest.json \
  --implementation-only
```

To reproduce the original `hh` path manually against a signed Release build:

```sh
APP=artifacts/verification/pdfkit-fast-open/local/DerivedData/Build/Products/Release/Modeleaf.app
Tools/run_manual_pdfkit_stress.sh \
  --app "$APP" \
  --pdf "/path/to/Sample Document.pdf" \
  --runs 10
```

The script launches the app and records your pass/fail input; it never injects
keys or captures the screen. The original PDF, generated fixtures, and local
run evidence are excluded from Git.

The final verification workflow additionally performs source/interface scope audits, source-PDF hash checks, read-only form/annotation probes, 15 signed-GUI workflow definitions, and a deterministic visual matrix covering six UI states across the bundled themes (the retained 24-image `artifacts/verification/final` set predates the light preset; current theme rendering is covered by the acceptance-matrix and theme-picker evidence). The machine-readable summary is retained in [artifacts/verification/final/verification-summary.json](artifacts/verification/final/verification-summary.json).

## Target graph

- `PDFReaderCore` — action, key, config, tab, and theme state;
- `PDFReaderApp` — AppKit/PDFKit application and adapters;
- `PDFReaderTestSupport` — generated PDF fixtures used only by tests;
- `PDFReaderCoreTests` — pure Swift Testing suite;
- `PDFReaderAppTests` — AppKit/PDFKit integration and deterministic visual suite;
- `PDFReaderUITests` — signed GUI XCUITest suite.

Theme palette attribution is in [PDFReaderApp/Theme/ThemeAttributions.md](PDFReaderApp/Theme/ThemeAttributions.md).
