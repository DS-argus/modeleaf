# Modeleaf

A native, read-only macOS PDF **viewer** — keyboard-first, Vim-flavored, with real tabs and tmux-style panes. The page stays visually dominant, and the app never touches your file.

[한국어 README](docs/README.md) · [Configuration reference](CONFIG.md) · [설정 가이드](docs/CONFIG.md)

## Philosophy

- **Read-only, always.** No annotations, editing, or saving. The source PDF is never modified — even search highlights are transient chrome, never written back.
- **Viewer-first.** Restrained AppKit chrome surrounds the page; PDF pixels are never recolored, and the reading surface stays dominant.
- **Keyboard-first.** Short Vim-style key sequences drive everything. The idea is borrowed from [Sioyek](https://github.com/ahrm/sioyek) but kept deliberately minimal — just the reading loop, native tabs, and split panes.
- **Fully configurable, strictly declarative.** Every command and value is remappable in one TOML file. Configuration is data only — no scripts, macros, or plugins.

## Install

```sh
brew tap DS-argus/tap
brew trust DS-argus/tap        # Homebrew 6+ asks you to trust a third-party tap once
brew install --cask modeleaf
```

Already installed? Update with `brew upgrade --cask modeleaf` (Homebrew refreshes the tap on its own; run `brew update` first to force it).

Requires macOS 14 (Sonoma) or newer. `⌘O` opens a unified picker — your recent PDFs, filtered by fuzzy filename search, plus a Browse… row for the native file dialog. You can also open via Finder → *Open With* or by dropping a file on the app; `⌘N` opens a new window and `⌘Q` quits.

> This build is ad-hoc signed and not yet Apple-notarized, so macOS Gatekeeper blocks it on first launch — allow it once in **System Settings → Privacy & Security → Open Anyway**.

### Build from source

```sh
APP=$(Tools/build_release_app.sh | tail -n 1)   # local Release app, no Apple account needed
open "$APP"
```

For development, `swift run Modeleaf` also works but is an unoptimized build and slower to start.

## Using it

Documents live in tabs, the view can be split into panes, and everything is driven from the keyboard. A document opens on page 1, fit inside the visible area.

### Keys (defaults)

| Intent | Key |
|---|---|
| scroll | `h` `j` `k` `l` |
| large scroll | `d` / `u` |
| next / previous page | `n` / `p` |
| first / last page | `gg` / `G` |
| go to page 12 | `g12`, then `Enter` |
| fit width / page | `w` / `F` |
| zoom in / out | `=` / `-` |
| search | `/`, then `Enter` — `Esc` clears |
| new window | `⌘N` |
| open / close / quit | `⌘O` / `⌘W` / `⌘Q` |
| next / previous tab | `N` / `P` |
| select tab 1…9 | `⌘1` … `⌘9` |
| split right / down | `Ctrl-b \|` / `Ctrl-b -` |
| focus pane | `Ctrl-h` / `Ctrl-j` / `Ctrl-k` / `Ctrl-l` |
| close other panes | `Ctrl-b o` |
| theme picker | `Shift-t` |
| command palette | `:` or `⌘⇧P` |
| follow link (hints) | `f` |

`Enter` / `Esc` (commit / cancel a prompt) and `Enter` / `Shift-Enter` (next / previous search match) are fixed keys and always work.

In fit-page mode, `j`/`d` move to the next page and `k`/`u` to the previous one. After you zoom, scroll keys move only along an axis where the page overflows the viewport — Modeleaf never pans into blank space.

### Tabs & panes

Each tab holds one document; the `+` button or `⌘O` opens another. `Ctrl-b |` and `Ctrl-b -` split the focused pane in place, tmux-style — up to four panes, each with its own tabs and document. A split keeps your current page but fits it to the smaller pane. `Ctrl-b o` closes every pane except the focused one, and `Ctrl-h/j/k/l` move focus by direction.

### Links

Links are clickable: an in-document link jumps inside the viewer, and an external URL opens in your browser. The source PDF is never modified.

### Command palette

Press `:` or `⌘⇧P` to open a fuzzy command search. Type to filter every reader command by name, `↑`/`↓` (or `Ctrl-j`/`Ctrl-k`) to move, `Enter` to run, `Esc` to dismiss. Each row shows the command's current shortcut; commands that can't run in the current context (no document, single pane, etc.) are listed but greyed out. Press `?` any time you're just reading to open a keyboard-help overlay with every shortcut, grouped by section.

### Themes

Six built-in themes: dark **Tokyo Night**, **Gruvbox Dark**, **Solarized Dark**, **Dracula**, **Everforest**, and light **Catppuccin Latte**. Press `Shift-t` for a live-preview picker (`Enter` commits, `Esc` reverts); the choice is saved separately and reapplied on launch. Themes color the app chrome only — never the PDF page.

## Configuration

Modeleaf reads one optional file at launch and never creates or rewrites it:

```text
~/.config/modeleaf/config.toml
```

Start from the generated example, then edit the copy:

```sh
mkdir -p ~/.config/modeleaf
cp PDFReaderApp/Resources/DefaultConfig.toml ~/.config/modeleaf/config.toml
```

```toml
[keymap]
"scroll.down" = ["j", "<Down>"]
"page.next"   = ["n"]
"tab.next"    = ["N"]

[navigation]
small_scroll_points = 56.0
zoom_factor = 1.12

[input]
prefix_timeout_ms = 350
prefix = "<C-b>"        # pane prefix; <prefix> in any binding expands to it
```

Key notation: `D` = Command, `C` = Control, `A` = Option, `S` = Shift (so `<D-o>` = ⌘O, `<C-j>` = Ctrl+J). `<prefix>` expands to the pane prefix, so rebinding `prefix` once moves every pane binding at once. The theme is chosen in the app, not in TOML; a legacy `[theme]` section is ignored with a warning.

Configuration is validated as a whole: any unknown key, invalid binding, conflict, or out-of-range value rejects the entire file and the built-in defaults activate instead, with every error and warning shown in the status line. A missing file is normal. Restart to apply changes — there is no live reload.

See **[CONFIG.md](CONFIG.md)** for the complete action registry, key-token grammar, validation rules, and every default.

## Not in v1

No bookmarks, annotations, highlights, command palette, external commands, scripts, plugins, macros, OCR, print, export, session persistence, or thumbnail sidebar. These are deliberate product constraints, not half-built features — Modeleaf is a focused reader.

## Built with

macOS 14+ · Swift 6 with complete strict concurrency · AppKit + PDFKit · a Foundation-only core (`PDFReaderCore`) for actions, keys, config, tabs, and themes · one pinned dependency, `TOMLDecoder`. Theme palette attributions: [ThemeAttributions.md](PDFReaderApp/Theme/ThemeAttributions.md).
