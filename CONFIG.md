# Modeleaf configuration

The optional user configuration lives at `~/.config/modeleaf/config.toml`. A missing file uses the complete built-in configuration. Configuration is declarative data only: it cannot define actions, macros, scripts, shell commands, or plugins.

## Loading and activation

- The app never creates the configuration file automatically. Only the explicit `Write Default Config` and `Reset Config` palette commands write it; `Write Default Config` is available only when the file is absent, while `Reset Config` first saves the existing file as `config.toml.bak` and then restores the built-in defaults.
- Input must be UTF-8 and no larger than 256 KiB. The size gate runs before TOML parsing.
- The adapter recursively visits the complete parsed TOML tree. Unknown sections, keys, nested leaves, array elements, and empty unknown nodes are errors.
- Present values decode into a sparse model, validate, overlay the typed built-ins, and then the complete effective value validates again.
- Launch activation is atomic. If any error exists, every user value is discarded and the complete typed built-ins activate; diagnostics are aggregated when parsing permits. Warnings do not force fallback.
- `Reload Config` applies a valid file at runtime without restarting. Its default binding is `<prefix>r` (`Ctrl-b r` by default), so it follows any `[input] prefix` rebinding. A reload error does not activate the built-ins: the last good configuration remains active and a pinned diagnostic reports the error.
- `PDFReaderCore.BuiltInDefaults` is the only runtime default source. The bundled `DefaultConfig.toml` and this document are generated examples, never fallback input.

## TOML schema

Only the following sections and value shapes are accepted. Every field is optional, and an omitted field keeps its typed default.

```toml
[keymap]
"action.id" = ["key-sequence", "alternate"]

[navigation]
small_scroll_points = 32.0
large_scroll_viewport_fraction = 0.8
zoom_factor = 1.1

[input]
prefix_timeout_ms = 400
prefix = "<C-b>"
```


## Key grammar

### Tokens and sequences

- A bare printable Unicode character is a literal token: `j`, `G`, `/`, `한`, and `O`. Whitespace is not a bare token; write `<Space>`.
- Concatenate tokens without separators for a sequence: `gg`, `zx`, `g12`, or `<C-b>r`.
- A coded token is `<modifier-base>`. Modifiers are `D` (Command), `C` (Control), `A` (Option), and `S` (Shift), normalized in that order.
- Shift rule: an uppercase Latin letter is always a bare literal (`O`). `<S-o>` normalizes to that same `O` token. In a chord with another modifier, write Shift explicitly: `<D-S-o>`; `<D-O>` and `<S-O>` are invalid.

### Named keys

Named-key spelling is case-insensitive and canonical output uses this table:

| Keys | Canonical notation |
|---|---|
| Escape | `<Esc>` |
| Enter | `<Enter>` |
| Backspace / forward delete | `<BS>`, `<Del>` |
| Tabs | `<Tab>`, `<Backtab>` (`<S-Tab>`) |
| Navigation | `<Left>`, `<Right>`, `<Up>`, `<Down>`, `<Home>`, `<End>`, `<PageUp>`, `<PageDown>` |
| Space and punctuation keys | `<Space>`, `<LT>`, `<GT>`, `<Minus>` |
| Function keys | `<F1>` through `<F12>` |

Use bare literals for backtick (`` ` ``), plus (`+`), equal (`=`), and slash (`/`); their former named spellings are rejected. Fn, Globe, media, power, raw key codes, action chains, and general Vim numeric counts are not part of the grammar.

- `<prefix>` in any binding expands to the `[input] prefix` chord (default `<C-b>`). Rebind the prefix once and every `<prefix>` binding follows.
- An empty array (`[]`) unbinds an action. An empty sequence string is invalid.
- `prompt.commit`, `prompt.cancel`, `search.next`, and `search.previous` are fixed keys (Enter/Esc, Enter/Shift+Enter). They are not rebindable and are omitted from `[keymap]`; a `[keymap]` entry for them is ignored with a warning.

## Input contexts

The exhaustive contexts are `navigation`, `pagePrompt`, `searchPrompt`, and `searchResults`. Only `document.open`, `app.new`, `app.quit`, `config.writeDefault`, and `config.resetDefault` are global. Contextual bindings may reuse a sequence only when their active contexts are disjoint.

## Stable v1 actions and defaults

| Action ID | Default | Contexts | Repeat |
|---|---|---|---|
| `document.open` | `<D-o>` | global | `suppressed` |
| `document.close` | `<D-w>` | `navigation`, `searchResults` | `suppressed` |
| `document.print` | `<D-p>` | global | `suppressed` |
| `app.quit` | `<D-q>` | global | `suppressed` |
| `app.new` | `<D-n>` | global | `suppressed` |
| `palette.open` | `:`, `<D-S-p>` | `navigation`, `searchResults` | `suppressed` |
| `help.show` | `?` | `navigation` | `suppressed` |
| `tab.next` | `N` | `navigation`, `searchResults` | `suppressed` |
| `tab.previous` | `P` | `navigation`, `searchResults` | `suppressed` |
| `tab.select.1` | `<D-1>` | `navigation`, `searchResults` | `suppressed` |
| `tab.select.2` | `<D-2>` | `navigation`, `searchResults` | `suppressed` |
| `tab.select.3` | `<D-3>` | `navigation`, `searchResults` | `suppressed` |
| `tab.select.4` | `<D-4>` | `navigation`, `searchResults` | `suppressed` |
| `tab.select.5` | `<D-5>` | `navigation`, `searchResults` | `suppressed` |
| `tab.select.6` | `<D-6>` | `navigation`, `searchResults` | `suppressed` |
| `tab.select.7` | `<D-7>` | `navigation`, `searchResults` | `suppressed` |
| `tab.select.8` | `<D-8>` | `navigation`, `searchResults` | `suppressed` |
| `tab.select.9` | `<D-9>` | `navigation`, `searchResults` | `suppressed` |
| `scroll.left` | `h`, `<Left>` | `navigation`, `searchResults` | `allowed` |
| `scroll.down` | `j`, `<Down>` | `navigation`, `searchResults` | `allowed` |
| `scroll.up` | `k`, `<Up>` | `navigation`, `searchResults` | `allowed` |
| `scroll.right` | `l`, `<Right>` | `navigation`, `searchResults` | `allowed` |
| `scroll.largeDown` | `d` | `navigation`, `searchResults` | `allowed` |
| `scroll.largeUp` | `u` | `navigation`, `searchResults` | `allowed` |
| `toc.toggle` | `t` | `navigation`, `searchResults` | `suppressed` |
| `toc.scrollDown` | `J` | `navigation`, `searchResults` | `allowed` |
| `toc.scrollUp` | `K` | `navigation`, `searchResults` | `allowed` |
| `page.next` | `n` | `navigation`, `searchResults` | `allowed` |
| `page.previous` | `p` | `navigation`, `searchResults` | `allowed` |
| `page.first` | `gg` | `navigation`, `searchResults` | `suppressed` |
| `page.last` | `G` | `navigation`, `searchResults` | `suppressed` |
| `page.prompt` | `g` | `navigation`, `searchResults` | `suppressed` |
| `history.back` | `<C-o>` | `navigation` | `suppressed` |
| `history.forward` | `<C-i>` | `navigation` | `suppressed` |
| `search.prompt` | `/` | `navigation`, `searchResults` | `suppressed` |
| `search.cancel` | `<Esc>` | `searchResults` | `suppressed` |
| `view.zoomIn` | `=` | `navigation`, `searchResults` | `allowed` |
| `view.zoomOut` | `-` | `navigation`, `searchResults` | `allowed` |
| `view.zoomReset` | unbound | `navigation`, `searchResults` | `suppressed` |
| `view.fitWidth` | `w` | `navigation`, `searchResults` | `suppressed` |
| `view.fitPage` | `F` | `navigation`, `searchResults` | `suppressed` |
| `view.rotateLeft` | `[` | `navigation`, `searchResults` | `suppressed` |
| `view.rotateRight` | `]` | `navigation`, `searchResults` | `suppressed` |
| `link.hint` | `f` | `navigation` | `suppressed` |
| `config.reload` | `<C-b>r` | `navigation` | `suppressed` |
| `config.writeDefault` | unbound | global | `suppressed` |
| `config.resetDefault` | unbound | global | `suppressed` |
| `theme.picker` | `T` | `navigation`, `searchResults` | `suppressed` |
| `indicator.picker` | `I` | `navigation`, `searchResults` | `suppressed` |
| `update.show` | `U` | `navigation`, `searchResults` | `suppressed` |
| `pane.splitRight` | `<C-b>|` | `navigation`, `searchResults` | `suppressed` |
| `pane.splitDown` | `<C-b>-` | `navigation`, `searchResults` | `suppressed` |
| `pane.focusLeft` | `<C-h>` | `navigation`, `searchResults` | `suppressed` |
| `pane.focusDown` | `<C-j>` | `navigation`, `searchResults` | `suppressed` |
| `pane.focusUp` | `<C-k>` | `navigation`, `searchResults` | `suppressed` |
| `pane.focusRight` | `<C-l>` | `navigation`, `searchResults` | `suppressed` |
| `pane.unsplit` | `<C-b>o` | `navigation`, `searchResults` | `suppressed` |
## Built-in values

- Small scroll: `32 pt` (valid `1...512`).
- Large scroll: `0.8 × viewport` (valid `0.1...2.0`).
- Zoom factor: `1.10` (valid `1.01...2.0`).
- Prefix timeout: `400 ms` (valid `100...2000`).
- Pane prefix: `<C-b>` (any single key chord; used by `<prefix>` bindings).
- Themes: `tokyo-night`, `gruvbox-dark`, `solarized-dark`, `dracula`, `everforest`, `nord`, `catppuccin-latte`.
- Themes are chosen in-app with the theme picker (`T`) and persisted separately. 테마는 앱 내 테마 선택기(`T`)에서 선택하며 별도로 저장됩니다.

A document starts on page 1 in a vertically continuous, fit-width layout. `j`/`↓`/`d` scroll forward through the connected pages and `k`/`↑`/`u` scroll backward. In fit-page mode those keys move one page at a time; `=` or `-` exits to continuous manual zoom while preserving the reading anchor, and `w` exits to continuous fit-width. The status bar shows `FIT PAGE` and `SEARCH` pills while active. Actual Size remains available from the View menu and as `view.zoomReset`, but is intentionally unbound by default.


## Prompt-safe bindings

Prompt text, dead keys, and IME composition stay on the native text-input path. A binding active in a prompt must be unbound or contain exactly one safe token. `<Enter>` and `<Esc>` are reserved for prompt lifecycle actions; other printable or non-Command modifier chords are rejected. The following two generated tables are compatibility-sensitive v1 constants.

<!-- BEGIN GENERATED: PROMPT_NATIVE_RESERVATION_V1 -->
### PromptNativeReservationV1

- `<A-BS>`
- `<A-Del>`
- `<A-Down>`
- `<A-End>`
- `<A-Home>`
- `<A-Left>`
- `<A-PageDown>`
- `<A-PageUp>`
- `<A-Right>`
- `<A-S-BS>`
- `<A-S-Del>`
- `<A-S-Down>`
- `<A-S-End>`
- `<A-S-Home>`
- `<A-S-Left>`
- `<A-S-PageDown>`
- `<A-S-PageUp>`
- `<A-S-Right>`
- `<A-S-Up>`
- `<A-Up>`
- `<BS>`
- `<C-BS>`
- `<C-Del>`
- `<C-Down>`
- `<C-End>`
- `<C-Home>`
- `<C-Left>`
- `<C-PageDown>`
- `<C-PageUp>`
- `<C-Right>`
- `<C-S-BS>`
- `<C-S-Del>`
- `<C-S-Down>`
- `<C-S-End>`
- `<C-S-Home>`
- `<C-S-Left>`
- `<C-S-PageDown>`
- `<C-S-PageUp>`
- `<C-S-Right>`
- `<C-S-Up>`
- `<C-Up>`
- `<D-BS>`
- `<D-Del>`
- `<D-Down>`
- `<D-End>`
- `<D-Home>`
- `<D-Left>`
- `<D-PageDown>`
- `<D-PageUp>`
- `<D-Right>`
- `<D-S-BS>`
- `<D-S-Del>`
- `<D-S-Down>`
- `<D-S-End>`
- `<D-S-Home>`
- `<D-S-Left>`
- `<D-S-PageDown>`
- `<D-S-PageUp>`
- `<D-S-Right>`
- `<D-S-Up>`
- `<D-S-z>`
- `<D-Up>`
- `<D-a>`
- `<D-c>`
- `<D-v>`
- `<D-x>`
- `<D-z>`
- `<Del>`
- `<Down>`
- `<End>`
- `<Home>`
- `<Left>`
- `<PageDown>`
- `<PageUp>`
- `<Right>`
- `<S-BS>`
- `<S-Del>`
- `<S-Down>`
- `<S-End>`
- `<S-Home>`
- `<S-Left>`
- `<S-PageDown>`
- `<S-PageUp>`
- `<S-Right>`
- `<S-Tab>`
- `<S-Up>`
- `<Tab>`
- `<Up>`
<!-- END GENERATED: PROMPT_NATIVE_RESERVATION_V1 -->

<!-- BEGIN GENERATED: SYSTEM_KEY_RESERVATION_V1 -->
### SystemKeyReservationV1

- `<D-A-Esc>`
- `<D-A-S-q>`
- `<D-A-d>`
- `<D-A-h>`
- `<D-C-Space>`
- `<D-C-f>`
- `<D-C-q>`
- `<D-S-3>`
- `<D-S-4>`
- `<D-S-5>`
- `<D-S-Tab>`
- ``<D-S-`>``
- `<D-S-q>`
- `<D-Space>`
- `<D-Tab>`
- ``<D-`>``
- `<D-h>`
- `<D-m>`
<!-- END GENERATED: SYSTEM_KEY_RESERVATION_V1 -->

## Complete built-in TOML

```toml
# Modeleaf configuration — generated from PDFReaderCore.BuiltInDefaults.
# Do not edit this bundled copy. Copy it to ~/.config/modeleaf/config.toml and edit the copy.
#
# Key notation (chords are wrapped in <...>):
#   D = Command (Cmd)   C = Control (Ctrl)   A = Option (Alt)   S = Shift
#   Bare printable characters are literal; use <Space> for space. Concatenate tokens for sequences (gg).
#   Uppercase letters are bare literals (O). In a chord, write Shift explicitly (<D-S-o>).
#   e.g. <D-o> = Cmd+o, <C-j> = Ctrl+j, <S-Enter> = Shift+Enter.
#   <prefix> expands to the pane prefix defined under [input] below. Rebind the prefix
#   once and every <prefix> binding follows; <prefix> may be used in any binding.
#
# Enter/Esc prompt commit & cancel and search next/previous are fixed keys and are
# intentionally omitted here — they cannot be rebound.

[keymap]

# --- Application ---
"document.open"    = ["<D-o>"]  # Cmd+o
"document.close"   = ["<D-w>"]  # Cmd+w
"document.print"   = ["<D-p>"]  # Cmd+p
"app.quit"         = ["<D-q>"]  # Cmd+q
"app.new"          = ["<D-n>"]  # Cmd+n

# --- Command palette ---
"palette.open"     = [":", "<D-S-p>"]  # :

# --- Help ---
"help.show"        = ["?"]  # ?

# --- Tabs ---
"tab.next"         = ["N"]  # N
"tab.previous"     = ["P"]  # P
"tab.select.1"     = ["<D-1>"]  # Cmd+1
"tab.select.2"     = ["<D-2>"]  # Cmd+2
"tab.select.3"     = ["<D-3>"]  # Cmd+3
"tab.select.4"     = ["<D-4>"]  # Cmd+4
"tab.select.5"     = ["<D-5>"]  # Cmd+5
"tab.select.6"     = ["<D-6>"]  # Cmd+6
"tab.select.7"     = ["<D-7>"]  # Cmd+7
"tab.select.8"     = ["<D-8>"]  # Cmd+8
"tab.select.9"     = ["<D-9>"]  # Cmd+9

# --- Scroll ---
"scroll.left"      = ["h", "<Left>"]  # h
"scroll.down"      = ["j", "<Down>"]  # j
"scroll.up"        = ["k", "<Up>"]  # k
"scroll.right"     = ["l", "<Right>"]  # l
"scroll.largeDown" = ["d"]  # d
"scroll.largeUp"   = ["u"]  # u

# --- Table of contents ---
"toc.toggle"       = ["t"]  # t
"toc.scrollDown"   = ["J"]  # J
"toc.scrollUp"     = ["K"]  # K

# --- Pages ---
"page.next"        = ["n"]  # n
"page.previous"    = ["p"]  # p
"page.first"       = ["gg"]  # g g
"page.last"        = ["G"]  # G
"page.prompt"      = ["g"]  # g

# --- Navigation ---
"history.back"     = ["<C-o>"]  # Ctrl+o
"history.forward"  = ["<C-i>"]  # Ctrl+i

# --- Search ---
"search.prompt"    = ["/"]  # /
"search.cancel"    = ["<Esc>"]  # Esc

# --- View / Zoom ---
"view.zoomIn"      = ["="]  # =
"view.zoomOut"     = ["-"]  # -
"view.zoomReset"   = []
"view.fitWidth"    = ["w"]  # w
"view.fitPage"     = ["F"]  # F
"view.rotateLeft"  = ["["]  # [
"view.rotateRight" = ["]"]  # ]

# --- Links ---
"link.hint"        = ["f"]  # f

# --- Config ---
"config.reload"    = ["<prefix>r"]  # Ctrl+b r
"config.writeDefault" = []
"config.resetDefault" = []

# --- Theme ---
"theme.picker"     = ["T"]  # T

# --- Link indicator ---
"indicator.picker" = ["I"]  # I

# --- Update ---
"update.show"      = ["U"]  # U

# --- Panes ---
# split/unsplit use <prefix>; focus keys are direct. Change the prefix under [input].
"pane.splitRight"  = ["<prefix>|"]  # Ctrl+b |
"pane.splitDown"   = ["<prefix>-"]  # Ctrl+b -
"pane.focusLeft"   = ["<C-h>"]  # Ctrl+h
"pane.focusDown"   = ["<C-j>"]  # Ctrl+j
"pane.focusUp"     = ["<C-k>"]  # Ctrl+k
"pane.focusRight"  = ["<C-l>"]  # Ctrl+l
"pane.unsplit"     = ["<prefix>o"]  # Ctrl+b o

[navigation]
small_scroll_points = 32.0
large_scroll_viewport_fraction = 0.8
zoom_factor = 1.1

[input]
prefix_timeout_ms = 400
# Pane prefix chord. Every <prefix> binding above expands to this.
prefix = "<C-b>"
```
