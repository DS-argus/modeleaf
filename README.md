<div align="center">
  <img src="Assets/AppIcon/AppIcon-1024.png" alt="Modeleaf app icon" width="160">
  <h1>Modeleaf</h1>
</div>

A native, read-only macOS PDF viewer — keyboard-first, Vim-flavored, with native tabs and a minimal interface.

[Korean](docs/README.md)

https://github.com/user-attachments/assets/1fd81fb3-b600-403c-bcfb-5365aa867503

## Philosophy

- **Read-only.** No annotations, editing, or saving. The source PDF is never modified.
- **Keyboard-first.** Inspired by [Sioyek](https://github.com/ahrm/sioyek), [SumatraPDF](https://github.com/sumatrapdfreader/sumatrapdf), [Vimium](https://github.com/philc/vimium), and the Markdown TUI [Leaf](https://github.com/RivoLink/leaf), while staying deliberately focused on reading.
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

## Command line

The Homebrew cask installs the `modeleaf` command alongside the app.

```sh
modeleaf                         # launch or activate Modeleaf
modeleaf document.pdf            # open a PDF in the existing app
modeleaf *.pdf                   # open multiple PDFs as tabs
modeleaf --new document.pdf      # open in a separate app instance
modeleaf update                  # update through Homebrew
modeleaf remove                  # uninstall without deleting configuration
modeleaf --version               # or: modeleaf -v
modeleaf --help
```

Shells expand globs before Modeleaf receives them. Use `modeleaf open -- <path>` when a path starts with a hyphen or matches a command name.

## Update

Use Modeleaf's update command so the installed CLI and cask stay in sync:

```sh
modeleaf update
```

If Homebrew reports that Modeleaf is already up to date while a newer release is listed on GitHub, refresh its metadata and retry:

```sh
brew update --force
modeleaf update
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

## Release preparation

For each release, maintainers add `release-notes/<version>.txt` (without the `v` tag prefix), for example `release-notes/0.13.0.txt`. Write 2-5 concise English, user-facing bullets based on the actual changes since the preceding release; each non-empty line must be a Markdown bullet beginning with `- `, and placeholders are not accepted.

Push only the matching `v<version>` tag, such as `v0.13.0`. The workflow verifies the tag, runs tests, packages the app, creates or updates a draft release with one `## Highlights` section plus GitHub's generated details, updates Homebrew, and then publishes. Rerunning a tag refreshes only its draft and keeps generated notes; an already-published release is never rewritten.

## License

Modeleaf is available under the [MIT License](LICENSE).

Theme palette attributions: [ThemeAttributions.md](PDFReaderApp/Theme/ThemeAttributions.md)
