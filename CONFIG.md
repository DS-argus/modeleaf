# PDF Reader configuration

The optional user configuration lives at `~/.config/pdf-reader/config.toml`. A missing file uses the complete built-in configuration. Configuration is declarative data only: it cannot define actions, macros, scripts, shell commands, or plugins.

## Loading and activation

- The app never creates the configuration file. Copy the generated example below when customization is needed.
- Input must be UTF-8 and no larger than 256 KiB. The size gate runs before TOML parsing.
- The adapter recursively visits the complete parsed TOML tree. Unknown sections, keys, nested leaves, array elements, and empty unknown nodes are errors.
- Present values decode into a sparse model, validate, overlay the typed built-ins, and then the complete effective value validates again.
- Activation is atomic. If any error exists, every user value is discarded and the complete typed built-ins activate; diagnostics are aggregated when parsing permits. Warnings do not force fallback.
- `PDFReaderCore.BuiltInDefaults` is the only runtime default source. The bundled `DefaultConfig.toml` and this document are generated examples, never fallback input.

## TOML schema

Only the following sections and value shapes are accepted. Every field is optional, and an omitted field keeps its typed default.

```toml
[keymap]
"action.id" = ["key-sequence", "alternate"]

[navigation]
small_scroll_points = 48.0
large_scroll_viewport_fraction = 0.8
zoom_factor = 1.1

[input]
prefix_timeout_ms = 500

[theme]
built_in = "catppuccin-mocha"

[theme.overrides]
accent = "#89B4FA"
```

## Key grammar

- Printable Unicode characters are logical keys: `j`, `G`, `/`, `한`.
- Multi-key sequences concatenate tokens: `gt`, `gT`, `gg`.
- Named keys and chords use angle brackets, for example `<Esc>`, `<CR>`, `<S-CR>`, `<D-o>`, and `<D-F12>`.
- Modifier order is normalized as `D` (Command), `C` (Control), `A` (Option), `S` (Shift).
- Supported named keys are Esc, CR, BS, Del, Tab/Backtab, arrows, Home/End, PageUp/PageDown, Space, Backtick, LT/GT, Plus/Minus/Equal/Slash, and F1…F24.
- Fn, Globe, media, power, raw key codes, action chains, and general Vim numeric counts are not part of the grammar.
- An empty array unbinds an action. An empty sequence string is invalid.
- Unbinding both `prompt.commit` and `prompt.cancel` is valid and emits a usability warning; the visible prompt controls remain available.

## Input contexts

The exhaustive contexts are `navigation`, `pagePrompt`, `searchPrompt`, and `searchResults`. Only `document.open` and `app.quit` are global. Contextual bindings may reuse a sequence only when their active contexts are disjoint.

## Stable v1 actions and defaults

| Action ID | Default | Contexts | Repeat |
|---|---|---|---|
| `document.open` | `<D-o>` | global | `suppressed` |
| `document.close` | `<D-w>` | `navigation`, `searchResults` | `suppressed` |
| `app.quit` | `<D-q>` | global | `suppressed` |
| `tab.next` | `gt` | `navigation`, `searchResults` | `suppressed` |
| `tab.previous` | `gT` | `navigation`, `searchResults` | `suppressed` |
| `scroll.left` | `h` | `navigation`, `searchResults` | `allowed` |
| `scroll.down` | `j` | `navigation`, `searchResults` | `allowed` |
| `scroll.up` | `k` | `navigation`, `searchResults` | `allowed` |
| `scroll.right` | `l` | `navigation`, `searchResults` | `allowed` |
| `scroll.largeDown` | `d` | `navigation`, `searchResults` | `allowed` |
| `scroll.largeUp` | `u` | `navigation`, `searchResults` | `allowed` |
| `page.next` | `n` | `navigation`, `searchResults` | `allowed` |
| `page.previous` | `p` | `navigation`, `searchResults` | `allowed` |
| `page.first` | `gg` | `navigation`, `searchResults` | `suppressed` |
| `page.last` | `G` | `navigation`, `searchResults` | `suppressed` |
| `page.prompt` | `g` | `navigation`, `searchResults` | `suppressed` |
| `prompt.commit` | `<CR>` | `pagePrompt`, `searchPrompt` | `suppressed` |
| `prompt.cancel` | `<Esc>` | `pagePrompt`, `searchPrompt` | `suppressed` |
| `search.prompt` | `/` | `navigation`, `searchResults` | `suppressed` |
| `search.next` | `<CR>` | `searchResults` | `allowed` |
| `search.previous` | `<S-CR>` | `searchResults` | `allowed` |
| `search.cancel` | `<Esc>` | `searchResults` | `suppressed` |
| `view.zoomIn` | `+` | `navigation`, `searchResults` | `allowed` |
| `view.zoomOut` | `-` | `navigation`, `searchResults` | `allowed` |
| `view.zoomReset` | `=` | `navigation`, `searchResults` | `suppressed` |
| `view.fitWidth` | `w` | `navigation`, `searchResults` | `suppressed` |
| `view.fitPage` | `f` | `navigation`, `searchResults` | `suppressed` |

## Built-in values

- Small scroll: `48 pt` (valid `1...512`).
- Large scroll: `0.8 × viewport` (valid `0.1...2.0`).
- Zoom factor: `1.10` (valid `1.01...2.0`).
- Prefix timeout: `500 ms` (valid `100...2000`).
- Initial theme: `catppuccin-mocha`.
- Themes: `catppuccin-mocha`, `tokyo-night`, `gruvbox-dark`, `nord`.

Themes apply to application chrome, overlays, and the surrounding PDF canvas. They never alter PDF page pixels.
Theme overrides use the semantic tokens `background` (the surrounding canvas and base chrome), `foreground`, `muted-text`, `border`, `accent`, `active-tab`, `inactive-tab`, `statusline`, `error`, `search-highlight`, `active-search-highlight`, and `focus-indicator`. Colors must use `#RRGGBB` or `#RRGGBBAA` hexadecimal form.

## Prompt-safe bindings

Prompt text, dead keys, and IME composition stay on the native text-input path. A binding active in a prompt must be unbound or contain exactly one safe token. `<CR>` and `<Esc>` are reserved for prompt lifecycle actions; other printable or non-Command modifier chords are rejected. The following two generated tables are compatibility-sensitive v1 constants.

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
- `<D-Backtick>`
- `<D-C-Space>`
- `<D-C-f>`
- `<D-C-q>`
- `<D-S-3>`
- `<D-S-4>`
- `<D-S-5>`
- `<D-S-Backtick>`
- `<D-S-Tab>`
- `<D-S-q>`
- `<D-Space>`
- `<D-Tab>`
- `<D-h>`
- `<D-m>`
<!-- END GENERATED: SYSTEM_KEY_RESERVATION_V1 -->

## Complete built-in TOML

```toml
# Generated from PDFReaderCore.BuiltInDefaults. Do not edit this bundled copy.
# Copy it to ~/.config/pdf-reader/config.toml and edit the copy.

[keymap]
"document.open" = ["<D-o>"]
"document.close" = ["<D-w>"]
"app.quit" = ["<D-q>"]
"tab.next" = ["gt"]
"tab.previous" = ["gT"]
"scroll.left" = ["h"]
"scroll.down" = ["j"]
"scroll.up" = ["k"]
"scroll.right" = ["l"]
"scroll.largeDown" = ["d"]
"scroll.largeUp" = ["u"]
"page.next" = ["n"]
"page.previous" = ["p"]
"page.first" = ["gg"]
"page.last" = ["G"]
"page.prompt" = ["g"]
"prompt.commit" = ["<CR>"]
"prompt.cancel" = ["<Esc>"]
"search.prompt" = ["/"]
"search.next" = ["<CR>"]
"search.previous" = ["<S-CR>"]
"search.cancel" = ["<Esc>"]
"view.zoomIn" = ["+"]
"view.zoomOut" = ["-"]
"view.zoomReset" = ["="]
"view.fitWidth" = ["w"]
"view.fitPage" = ["f"]

[navigation]
small_scroll_points = 48.0
large_scroll_viewport_fraction = 0.8
zoom_factor = 1.1

[input]
prefix_timeout_ms = 500

[theme]
built_in = "catppuccin-mocha"
```
