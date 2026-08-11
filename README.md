<div align="center">
  <img src="Assets/AppIcon/AppIcon-1024.png" alt="Modeleaf app icon" width="160">
  <h1>Modeleaf</h1>
</div>

A native, read-only macOS PDF **viewer** — keyboard-first, Vim-flavored, with real tabs and tmux-style panes. The page stays visually dominant, and the app never touches your file.

[Korean](docs/README.md)

## Philosophy

- **Read-only, always.** No annotations, editing, or saving. The source PDF is never modified — even search highlights are transient chrome, never written back. Printing is an explicit system output operation and never writes to the source.
- **Viewer-first.** Restrained AppKit chrome surrounds the page; PDF pixels are never recolored, and the reading surface stays dominant.
- **Keyboard-first.** Short Vim-style key sequences drive everything. The idea is borrowed from [Sioyek](https://github.com/ahrm/sioyek) but kept deliberately minimal — just the reading loop, native tabs, and split panes.
- **Fully configurable, strictly declarative.** Every command and value is remappable in one TOML file. Configuration is data only — no scripts, macros, or plugins.

## Install

```sh
brew tap DS-argus/tap
brew trust DS-argus/tap        # Homebrew 6+ asks you to trust a third-party tap once
brew install --cask modeleaf
```

Requires macOS 14 (Sonoma) or newer.

> This build is ad-hoc signed and not yet Apple-notarized, so macOS Gatekeeper blocks it on first launch — allow it once in **System Settings → Privacy & Security → Open Anyway**.

### Build from source

```sh
APP=$(Tools/build_release_app.sh | tail -n 1)   # local Release app, no Apple account needed
open "$APP"
```

For development, `swift run Modeleaf` also works but is an unoptimized build and slower to start.

## Update

```sh
brew upgrade --cask modeleaf
```

Homebrew refreshes the tap on its own; run `brew update` first to force it. Modeleaf also checks GitHub Releases at launch: when a newer version exists, the status bar shows an update notice — for a Homebrew install it names the upgrade command, otherwise clicking it opens the Releases page. The check is silent when offline, and the app never updates itself.

## Using it

Documents live in tabs, the view can be split into panes, and everything is driven from the keyboard. A document opens on page 1 in a vertically continuous, fit-width layout.

`⌘o` opens a unified picker — your recent PDFs, filtered by fuzzy filename search, plus a Browse… row for the native file dialog. You can also open via Finder → *Open With* or by dropping a file on the app; `⌘n` opens a new window and `⌘q` quits.


`⌘p` opens the standard macOS Print panel for the PDF in the active pane. Printing is an explicit system output operation; it does not modify or save over the source PDF.

`Ctrl+o` and `Ctrl+i` provide Vim-like Back and Forward history, kept only in memory for each tab and pane. They record meaningful jumps — page prompts, first/last page commands, internal GoTo links or hints, and distinct displayed search landings — while one uninterrupted search epoch continues across query replacement and coalesces its result navigation. Ordinary scrolling, next/previous page, zoom, fit, and rotation do not enter history. Restoring returns to the saved page and in-page anchor while keeping the current zoom, fit, rotation, and search presentation; a new jump after Back clears Forward. When unavailable, the command palette explains why. Feature implementation never packages or publishes a release; release remains a separate, explicit operation.

### Keys (defaults)

| Intent | Key |
|---|---|
| scroll | `h` `j` `k` `l` or `←` `↓` `↑` `→` |
| large scroll | `d` / `u` |
| next / previous page | `n` / `p` |
| first / last page | `gg` / `G` |
| go to page 12 | `g12`, then `Enter` |
| back / forward | `Ctrl+o` / `Ctrl+i` |
| link hints | `f` |
| link destination indicator settings | `I` |
| fit width / page | `w` / `F` |
| zoom in / out | `=` / `-` |
| rotate left / right | `[` / `]` |
| search | `/`, then `Enter` — `Esc` clears |
| new window | `⌘n` |
| print active PDF | `⌘p` |
| open / close / quit | `⌘o` / `⌘w` / `⌘q` |
| next / previous tab | `N` / `P` |
| select tab 1…9 | `⌘1` … `⌘9` |
| split right / down | `Ctrl-b \|` / `Ctrl-b -` |
| focus pane | `Ctrl-h` / `Ctrl-j` / `Ctrl-k` / `Ctrl-l` |
| close other panes | `Ctrl-b o` |
| theme picker | `T` |
| command palette | `:` or `⌘⇧P` |
| reload config | `Ctrl-b r` |
| keyboard help | `?` |

`Enter` / `Esc` (commit / cancel a prompt) and `Enter` / `Shift-Enter` (next / previous search match) are fixed keys and always work. Press `?` any time you're just reading for a keyboard-help overlay with every shortcut, grouped by section — the status bar's `? help` hint opens it too.

In fit-page mode, `j`/`↓`/`d` move to the next page and `k`/`↑`/`u` to the previous one. Pressing `=` or `-` exits fit-page into vertically continuous manual zoom while preserving the current reading anchor; `w` exits to continuous fit-width. The status bar shows `FIT PAGE` and `SEARCH` pills while those modes are active. `[` and `]` rotate the view in 90° steps; rotation is view-only, per pane, and never written to the file.

### Tabs & panes

Each tab holds one document; the `+` button or `⌘o` opens another. `Ctrl-b |` and `Ctrl-b -` split the focused pane in place, tmux-style — up to four panes, each with its own tabs and document. A split keeps your current page but fits it to the smaller pane. `Ctrl-b o` closes every pane except the focused one, and `Ctrl-h/j/k/l` move focus by direction.

### Links

Links are clickable: an in-document link jumps inside the viewer, and an external URL opens in your browser. Press `f` to show labels for annotation links, then type a label to follow it; `Esc` cancels. A link that wraps onto another line has one hint; only annotated links are eligible, so URLs printed as text cannot be clicked or hinted — select and copy them instead. Scrolling or resizing dismisses hints.

After a verified in-document GoTo landing with an exact destination point, Modeleaf briefly marks the target with a configurable indicator. Press `I` to open the keyboard-first four-column picker for style, color, size, and duration; `Tab`/`Shift-Tab` or `h`/`l` move between columns, `j`/`k` adjust values, `Enter` applies, and `Esc` cancels. Mouse selection and dragging are supported too. URL links, failed or same-location jumps, and destinations without complete coordinates do not show an indicator.

### Command palette

Press `:` or `⌘⇧P` to open a fuzzy command search. Type to filter every reader command by name, `↑`/`↓` (or `Ctrl-j`/`Ctrl-k`) to move, `Enter` to run, `Esc` to dismiss. Each row shows the command's current shortcut; commands that can't run in the current context (no document, single pane, etc.) are listed but greyed out.

### Themes

Seven built-in themes: dark **Tokyo Night**, **Gruvbox Dark**, **Solarized Dark**, **Dracula**, **Everforest**, **Nord**, and light **Catppuccin Latte**. Press `T` for a live-preview picker (`Enter` commits, `Esc` reverts); the choice is saved separately and reapplied on launch. Themes color the app chrome only — never the PDF page.

## Configuration

Modeleaf reads one optional file at launch and never creates or rewrites it automatically; only the explicit **Write Default Config** and **Reset Config** command-palette commands write it:

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

Key notation: `D` = Command, `C` = Control, `A` = Option, `S` = Shift (so `<D-o>` = ⌘o, `<C-j>` = Ctrl+j). Uppercase letters are bare literals (`O`); `<S-o>` is the same token, while modified Shift chords use `<D-S-o>`. `<prefix>` expands to the pane prefix, so rebinding `prefix` once moves every pane binding at once. The theme is chosen in the app, not in TOML; a legacy `[theme]` section is ignored with a warning.

Configuration is validated as a whole: at launch, any unknown key, invalid binding, conflict, or out-of-range value rejects the entire file and activates the built-in defaults, with every error and warning shown in the status line. A missing file is normal. Use **Reload Config** to apply a valid edited file without restarting; its default `Ctrl-b r` binding follows any `prefix` rebinding. A broken runtime reload is not applied: the previous configuration stays active and a pinned error appears in the status line. The command palette also offers **Write Default Config** when no file exists, and **Reset Config**, which saves the existing file as `config.toml.bak` before restoring the defaults.

See **[CONFIG.md](CONFIG.md)** for the complete action registry, key-token grammar, validation rules, and every default.

---

## License

Modeleaf is available under the [MIT License](LICENSE).

Theme palette attributions: [ThemeAttributions.md](PDFReaderApp/Theme/ThemeAttributions.md)
