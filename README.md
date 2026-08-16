<div align="center">
  <img src="Assets/AppIcon/AppIcon-1024.png" alt="Modeleaf app icon" width="160">
  <h1>Modeleaf</h1>
</div>

A native, read-only macOS PDF viewer — keyboard-first, Vim-flavored, with native tabs and a minimal interface.

[Korean](docs/README.md)

https://github.com/user-attachments/assets/1fd81fb3-b600-403c-bcfb-5365aa867503

## Philosophy

- **Read-only.** No annotations, editing, or saving. The source PDF is never modified.
- **Keyboard-first.** Inspired by [Sioyek](https://github.com/ahrm/sioyek), [SumatraPDF](https://github.com/sumatrapdfreader/sumatrapdf), and [Vimium](https://github.com/philc/vimium), but deliberately focused on reading.
- **Configurable.** Most commands and reader behavior can be remapped in one TOML file.

## Key features

- Keyboard-first navigation, search, link hints, and embedded-outline TOC
- Native tabs and a recent-file picker
- Command palette and seven built-in themes
- Fit, zoom, rotation, history, and system printing
- TOML-configurable commands and reader behavior

## Install

```sh
brew tap DS-argus/tap
brew trust DS-argus/tap
brew install --cask modeleaf
```

Requires macOS 14 (Sonoma) or newer.

> This build is ad-hoc signed and not yet Apple-notarized. On first launch, allow it in **System Settings → Privacy & Security → Open Anyway**.

## Update

```sh
brew upgrade --cask modeleaf
```

If Homebrew has stale metadata:

```sh
brew update --force
brew upgrade --cask modeleaf
```

Modeleaf checks [GitHub Releases](https://github.com/DS-argus/modeleaf/releases) at launch but never updates itself.

## Keys (defaults)

| Action                              | Key                           |
| ----------------------------------- | ----------------------------- |
| Scroll / large scroll               | `h` `j` `k` `l` / `d` `u`     |
| Previous / next page                | `p` / `n`                     |
| First / last page                   | `gg` / `G`                    |
| Go to page                          | `g`, number, `Enter`          |
| Back / forward                      | `Ctrl+o` / `Ctrl+i`           |
| TOC / move / jump                   | `t` / `J` `K` / number        |
| Search / next / previous result     | `/` / `Enter` / `Shift-Enter` |
| Link hints / indicator settings     | `f` / `I`                     |
| Fit width / page                    | `w` / `F`                     |
| Zoom / rotate                       | `=` `-` / `[` `]`             |
| Copy PDF path / reveal in Finder   | `yy` / `of`                   |
| Open / close / print / quit         | `⌘o` / `⌘w` / `⌘p` / `⌘q`     |
| Previous / next tab                 | `P` / `N`                     |
| Split / focus pane | `Ctrl-b \|` `Ctrl-b -` / `Ctrl-h/j/k/l` |
| Theme / palette / help              | `T` / `:` / `?`               |

## Configuration

Modeleaf reads an optional TOML config:

```text
~/.config/modeleaf/config.toml
```

Keys use `D` (Command), `C` (Control), `A` (Option), and `S` (Shift). Use **Write Default Config**, **Reload Config**, or **Reset Config** from the command palette. See [CONFIG.md](CONFIG.md) for every action, default, and validation rule.

## Build from source

```sh
APP=$(Tools/build_release_app.sh | tail -n 1)
open "$APP"
```

For development, use `swift run Modeleaf`. Run `Tools/verify.sh full` before opening a pull request.

## License

Modeleaf is available under the [MIT License](LICENSE).

Theme palette attributions: [ThemeAttributions.md](PDFReaderApp/Theme/ThemeAttributions.md)
