# PDF Reader

A native, read-only macOS PDF viewer with a compact Vim-style command model, first-class tabs, and strict TOML customization.

## Documentation

- [한국어 README](docs/README.md)
- [Configuration reference (English)](CONFIG.md)
- [설정 가이드 (한국어)](docs/CONFIG.md)

The interaction design takes one focused idea from [Sioyek](https://github.com/ahrm/sioyek): configurable, keyboard-first navigation with short multi-key sequences. It is intentionally **not** a Sioyek clone. V1 keeps only the reading loop, adds native tabs, and uses restrained AppKit chrome so the PDF stays visually dominant.

## What it does

- opens local PDFs from the app, Finder/Open With, or the default `⌘O` binding;
- keeps multiple documents in independent tabs;
- scrolls, changes pages, jumps to a numbered page, zooms, and fits the view;
- searches embedded PDF text with per-tab result state and highlighting;
- routes every app-owned command through one stable action registry;
- lets every reader action, navigation value, and chrome theme be changed in TOML;
- preserves the source file: the production boundary exposes no save or edit workflow.

The shipped bindings stay deliberately small:

| Intent | Default |
|---|---|
| small scroll | `h` `j` `k` `l` |
| large scroll | `d` / `u` |
| next / previous page | `n` / `p` |
| first / last page | `gg` / `G` |
| page 12 | `g12`, then `Enter` |
| next / previous tab | `gt` / `gT` |
| search | `/`, then `Enter` |
| next / previous match | `Enter` / `Shift-Enter` |
| clear search | `Esc` |
| zoom / reset | `+` / `-` / `=` |
| fit width / page | `w` / `f` |

See [CONFIG.md](CONFIG.md) for the exhaustive 27-action registry, key-token grammar, validation rules, numeric bounds, and generated default file.

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

The four bundled dark themes are **Catppuccin Mocha**, **Tokyo Night**, **Gruvbox Dark**, and **Nord**. Themes affect app chrome, the surrounding PDF canvas, prompts, status, and transient search highlights; PDF page pixels are not recolored.

## Build and run

### Xcode app

```sh
python3 Tools/generate_xcode_project.py
python3 Tools/validate_xcode_project.py
open PDFReader.xcodeproj
```

Select the shared `PDFReader` scheme and run it on **My Mac**. The generated project targets macOS 14+ and contains the app, core, support, unit, integration, and UI-test targets.

### SwiftPM development harness

```sh
swift package resolve
swift build -c debug
swift run PDFReader
```

After `Build of product 'PDFReader' complete!` appears, the terminal remains attached while the GUI app runs; this is normal. The **PDF Reader** window should open automatically. Use `⌘O` to choose a PDF, `⌘Q` to quit normally, or `Control-C` to stop the development process from the terminal.

The Swift package is retained as a deterministic command-line build/test harness for the same production sources. `Package.resolved` pins the only third-party dependency.

## Configuration

The app reads configuration once at launch from:

```text
~/.config/pdf-reader/config.toml
```

It does not create or rewrite that file. To start customizing it:

```sh
mkdir -p ~/.config/pdf-reader
cp PDFReaderApp/Resources/DefaultConfig.toml ~/.config/pdf-reader/config.toml
```

Example:

```toml
[keymap]
"scroll.down" = ["j", "<Down>"]
"scroll.up" = ["k", "<Up>"]
"page.next" = ["n"]
"page.previous" = ["p"]
"tab.next" = ["gt"]
"tab.previous" = ["gT"]

[navigation]
small_scroll_points = 56.0
large_scroll_viewport_fraction = 0.85
zoom_factor = 1.12

[input]
prefix_timeout_ms = 600

[theme]
built_in = "tokyo-night"

[theme.overrides]
accent = "#7DCFFF"
```

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

The deterministic Xcode graph is generated by `Tools/generate_xcode_project.py`; do not hand-edit `PDFReader.xcodeproj/project.pbxproj`.

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

The final verification workflow additionally performs source/interface scope audits, source-PDF hash checks, read-only form/annotation probes, 15 signed-GUI workflow definitions, and a deterministic 24-image visual matrix covering six UI states across all four themes. The machine-readable summary is retained in [artifacts/verification/final/verification-summary.json](artifacts/verification/final/verification-summary.json).

## Target graph

- `PDFReaderCore` — action, key, config, tab, and theme state;
- `PDFReaderApp` — AppKit/PDFKit application and adapters;
- `PDFReaderTestSupport` — generated PDF fixtures used only by tests;
- `PDFReaderCoreTests` — pure Swift Testing suite;
- `PDFReaderAppTests` — AppKit/PDFKit integration and deterministic visual suite;
- `PDFReaderUITests` — signed GUI XCUITest suite.

Theme palette attribution is in [PDFReaderApp/Theme/ThemeAttributions.md](PDFReaderApp/Theme/ThemeAttributions.md).
