import Foundation

public enum ConfigDocumentation {
    public static var markdown: String {
        var lines = [
            "# Modeleaf configuration",
            "",
            "The optional user configuration lives at `~/.config/modeleaf/config.toml`. A missing file uses the complete built-in configuration. Configuration is declarative data only: it cannot define actions, macros, scripts, shell commands, or plugins.",
            "",
            "## Loading and activation",
            "",
            "- The app never creates the configuration file automatically. Only the explicit `Write Default Config` and `Reset Config` palette commands write it; `Write Default Config` is available only when the file is absent, while `Reset Config` first saves the existing file as `config.toml.bak` and then restores the built-in defaults.",
            "- Input must be UTF-8 and no larger than 256 KiB. The size gate runs before TOML parsing.",
            "- The adapter recursively visits the complete parsed TOML tree. Unknown sections, keys, nested leaves, array elements, and empty unknown nodes are errors.",
            "- Present values decode into a sparse model, validate, overlay the typed built-ins, and then the complete effective value validates again.",
            "- Launch activation is atomic. If any error exists, every user value is discarded and the complete typed built-ins activate; diagnostics are aggregated when parsing permits. Warnings do not force fallback.",
            "- `Reload Config` applies a valid file at runtime without restarting. Its default binding is `<prefix>r` (`Ctrl-b r` by default), so it follows any `[input] prefix` rebinding. A reload error does not activate the built-ins: the last good configuration remains active and a pinned diagnostic reports the error.",
            "- `PDFReaderCore.BuiltInDefaults` is the only runtime default source. The bundled `DefaultConfig.toml` and this document are generated examples, never fallback input.",
            "",
            "## TOML schema",
            "",
            "Only the following sections and value shapes are accepted. Every field is optional, and an omitted field keeps its typed default.",
            "",
            "```toml",
            "[keymap]",
            "\"action.id\" = [\"key-sequence\", \"alternate\"]",
            "",
            "[navigation]",
            "small_scroll_points = 32.0",
            "large_scroll_viewport_fraction = 0.8",
            "zoom_factor = 1.1",
            "",
            "[input]",
            "prefix_timeout_ms = 800",
            "prefix = \"<C-b>\"",
            "",
            "```",
            "",
            "## Key grammar",
            "",
            "### Tokens and sequences",
            "",
            "- A bare printable Unicode character is a literal token: `j`, `G`, `/`, `한`, and `O`. Whitespace is not a bare token; write `<Space>`.",
            "- Concatenate tokens without separators for a sequence: `gg`, `zx`, `g12`, or `<C-b>r`.",
            "- A coded token is `<modifier-base>`. Modifiers are `D` (Command), `C` (Control), `A` (Option), and `S` (Shift), normalized in that order.",
            "- Shift rule: an uppercase Latin letter is always a bare literal (`O`). `<S-o>` normalizes to that same `O` token. In a chord with another modifier, write Shift explicitly: `<D-S-o>`; `<D-O>` and `<S-O>` are invalid.",
            "",
            "### Named keys",
            "",
            "Named-key spelling is case-insensitive and canonical output uses this table:",
            "",
            "| Keys | Canonical notation |",
            "|---|---|",
            "| Escape | `<Esc>` |",
            "| Enter | `<Enter>` |",
            "| Backspace / forward delete | `<BS>`, `<Del>` |",
            "| Tabs | `<Tab>`, `<Backtab>` (`<S-Tab>`) |",
            "| Navigation | `<Left>`, `<Right>`, `<Up>`, `<Down>`, `<Home>`, `<End>`, `<PageUp>`, `<PageDown>` |",
            "| Space and punctuation keys | `<Space>`, `<LT>`, `<GT>`, `<Minus>` |",
            "| Function keys | `<F1>` through `<F12>` |",
            "",
            "Use bare literals for backtick (`` ` ``), plus (`+`), equal (`=`), and slash (`/`); their former named spellings are rejected. Fn, Globe, media, power, raw key codes, action chains, and general Vim numeric counts are not part of the grammar.",
            "",
            "- `<prefix>` in any binding expands to the `[input] prefix` chord (default `<C-b>`). Rebind the prefix once and every `<prefix>` binding follows.",
            "- An empty array (`[]`) unbinds an action. An empty sequence string is invalid.",
            "- `prompt.commit`, `prompt.cancel`, `search.next`, and `search.previous` are fixed keys (Enter/Esc, Enter/Shift+Enter). They are not rebindable and are omitted from `[keymap]`; a `[keymap]` entry for them is ignored with a warning.",
            "",
            "## Input contexts",
            "",
            "The exhaustive contexts are `navigation`, `pagePrompt`, `searchPrompt`, and `searchResults`. Only `document.open`, `app.new`, `app.quit`, `config.writeDefault`, and `config.resetDefault` are global. Contextual bindings may reuse a sequence only when their active contexts are disjoint.",
            "",
            "## Stable v1 actions and defaults",
            "",
            "| Action ID | Default | Contexts | Repeat |",
            "|---|---|---|---|",
        ]

        for descriptor in ActionRegistry.v1.userConfigurableDescriptors {
            let defaults = BuiltInDefaults.keymap[descriptor.id, default: []]
                .map { inlineCode($0.description) }
                .joined(separator: ", ")
            lines.append(
                "| `\(descriptor.id.rawValue)` | \(defaults.isEmpty ? "unbound" : defaults) | \(contextDescription(descriptor.scope)) | `\(descriptor.repeatPolicy.rawValue)` |"
            )
        }

        lines += [
            "## Built-in values",
            "",
            "- Small scroll: `32 pt` (valid `1...512`).",
            "- Large scroll: `0.8 × viewport` (valid `0.1...2.0`).",
            "- Zoom factor: `1.10` (valid `1.01...2.0`).",
            "- Prefix timeout: `800 ms` (valid `100...2000`).",
            "- Pane prefix: `<C-b>` (any single key chord; used by `<prefix>` bindings).",
            "- Themes: `tokyo-night`, `gruvbox-dark`, `solarized-dark`, `dracula`, `everforest`, `nord`, `catppuccin-latte`.",
            "- Themes are chosen in-app with the theme picker (`T`) and persisted separately. 테마는 앱 내 테마 선택기(`T`)에서 선택하며 별도로 저장됩니다.",
            "",
            "A document starts on page 1 in a vertically continuous, fit-width layout. `j`/`↓`/`d` scroll forward through the connected pages and `k`/`↑`/`u` scroll backward. In fit-page mode those keys move one page at a time; `=` or `-` exits to continuous manual zoom while preserving the reading anchor, and `w` exits to continuous fit-width. The status bar shows `FIT PAGE` and `SEARCH` pills while active. Actual Size remains available from the View menu and as `view.zoomReset`, but is intentionally unbound by default.",
            "",
            "",
            "## Prompt-safe bindings",
            "",
            "Prompt text, dead keys, and IME composition stay on the native text-input path. A binding active in a prompt must be unbound or contain exactly one safe token. `<Enter>` and `<Esc>` are reserved for prompt lifecycle actions; other printable or non-Command modifier chords are rejected. The following two generated tables are compatibility-sensitive v1 constants.",
            "",
            "<!-- BEGIN GENERATED: PROMPT_NATIVE_RESERVATION_V1 -->",
            "### PromptNativeReservationV1",
            "",
        ]
        lines += PromptNativeReservationV1.shared.normalizedEntries.map { "- \(inlineCode($0))" }
        lines += [
            "<!-- END GENERATED: PROMPT_NATIVE_RESERVATION_V1 -->",
            "",
            "<!-- BEGIN GENERATED: SYSTEM_KEY_RESERVATION_V1 -->",
            "### SystemKeyReservationV1",
            "",
        ]
        lines += SystemKeyReservationV1.shared.normalizedEntries.map { "- \(inlineCode($0))" }
        lines += [
            "<!-- END GENERATED: SYSTEM_KEY_RESERVATION_V1 -->",
            "",
            "## Complete built-in TOML",
            "",
            "```toml",
            BuiltInDefaults.defaultConfigTOML.trimmingCharacters(in: .newlines),
            "```",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    private static func contextDescription(_ scope: ActionScope) -> String {
        switch scope {
        case .global:
            "global"
        case let .contexts(contexts):
            InputContext.allCases.filter(contexts.contains)
                .map { "`\($0.rawValue)`" }
                .joined(separator: ", ")
        }
    }

    private static func inlineCode(_ value: String) -> String {
        value.contains("`") ? "``\(value)``" : "`\(value)`"
    }
}
