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
            "- The app never creates the configuration file. Copy the generated example below when customization is needed.",
            "- Input must be UTF-8 and no larger than 256 KiB. The size gate runs before TOML parsing.",
            "- The adapter recursively visits the complete parsed TOML tree. Unknown sections, keys, nested leaves, array elements, and empty unknown nodes are errors.",
            "- Present values decode into a sparse model, validate, overlay the typed built-ins, and then the complete effective value validates again.",
            "- Activation is atomic. If any error exists, every user value is discarded and the complete typed built-ins activate; diagnostics are aggregated when parsing permits. Warnings do not force fallback.",
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
            "small_scroll_points = 48.0",
            "large_scroll_viewport_fraction = 0.8",
            "zoom_factor = 1.1",
            "",
            "[input]",
            "prefix_timeout_ms = 300",
            "",
            "[theme]",
            "built_in = \"catppuccin-mocha\"",
            "",
            "[theme.overrides]",
            "accent = \"#89B4FA\"",
            "```",
            "",
            "## Key grammar",
            "",
            "- Printable Unicode characters are logical keys: `j`, `G`, `/`, `한`.",
            "- Multi-key sequences concatenate tokens: `gg`, `zx`, `g12`.",
            "- Named keys and chords use angle brackets, for example `<Esc>`, `<CR>`, `<S-CR>`, `<D-o>`, `<D-1>`, and `<D-F12>`.",
            "- Modifier order is normalized as `D` (Command), `C` (Control), `A` (Option), `S` (Shift).",
            "- Supported named keys are Esc, CR, BS, Del, Tab/Backtab, arrows, Home/End, PageUp/PageDown, Space, Backtick, LT/GT, Plus/Minus/Equal/Slash, and F1…F24.",
            "- Fn, Globe, media, power, raw key codes, action chains, and general Vim numeric counts are not part of the grammar.",
            "- An empty array unbinds an action. An empty sequence string is invalid.",
            "- Unbinding both `prompt.commit` and `prompt.cancel` is valid and emits a usability warning; the visible prompt controls remain available.",
            "",
            "## Input contexts",
            "",
            "The exhaustive contexts are `navigation`, `pagePrompt`, `searchPrompt`, and `searchResults`. Only `document.open` and `app.quit` are global. Contextual bindings may reuse a sequence only when their active contexts are disjoint.",
            "",
            "## Stable v1 actions and defaults",
            "",
            "| Action ID | Default | Contexts | Repeat |",
            "|---|---|---|---|",
        ]

        for descriptor in ActionRegistry.v1.descriptors {
            let defaults = BuiltInDefaults.keymap[descriptor.id, default: []]
                .map { "`\($0.description)`" }
                .joined(separator: ", ")
            lines.append(
                "| `\(descriptor.id.rawValue)` | \(defaults.isEmpty ? "unbound" : defaults) | \(contextDescription(descriptor.scope)) | `\(descriptor.repeatPolicy.rawValue)` |"
            )
        }

        lines += [
            "",
            "## Built-in values",
            "",
            "- Small scroll: `48 pt` (valid `1...512`).",
            "- Large scroll: `0.8 × viewport` (valid `0.1...2.0`).",
            "- Zoom factor: `1.10` (valid `1.01...2.0`).",
            "- Prefix timeout: `300 ms` (valid `100...2000`).",
            "- Initial theme: `catppuccin-mocha`.",
            "- Themes: `catppuccin-mocha`, `tokyo-night`, `gruvbox-dark`, `nord`.",
            "",
            "A newly opened document starts on page 1 in fit-page mode. In that mode, `j`/`d` advance a page and `k`/`u` go back. After manual zoom, each scroll action first moves within an overflowing axis. At a vertical edge, another downward action enters the next page at its top and another upward action enters the previous page at its bottom; vertical actions remain inert when the page overflows only horizontally. Actual Size remains available from the View menu and as `view.zoomReset`, but is intentionally unbound by default.",
            "",
            "Themes apply to application chrome, overlays, and the surrounding PDF canvas. They never alter PDF page pixels.",
            "Theme overrides use the semantic tokens `background` (the surrounding canvas and base chrome), `foreground`, `muted-text`, `border`, `accent`, `active-tab`, `inactive-tab`, `statusline`, `error`, `search-highlight`, `active-search-highlight`, and `focus-indicator`. Colors must use `#RRGGBB` or `#RRGGBBAA` hexadecimal form.",
            "",
            "## Prompt-safe bindings",
            "",
            "Prompt text, dead keys, and IME composition stay on the native text-input path. A binding active in a prompt must be unbound or contain exactly one safe token. `<CR>` and `<Esc>` are reserved for prompt lifecycle actions; other printable or non-Command modifier chords are rejected. The following two generated tables are compatibility-sensitive v1 constants.",
            "",
            "<!-- BEGIN GENERATED: PROMPT_NATIVE_RESERVATION_V1 -->",
            "### PromptNativeReservationV1",
            "",
        ]
        lines += PromptNativeReservationV1.shared.normalizedEntries.map { "- `\($0)`" }
        lines += [
            "<!-- END GENERATED: PROMPT_NATIVE_RESERVATION_V1 -->",
            "",
            "<!-- BEGIN GENERATED: SYSTEM_KEY_RESERVATION_V1 -->",
            "### SystemKeyReservationV1",
            "",
        ]
        lines += SystemKeyReservationV1.shared.normalizedEntries.map { "- `\($0)`" }
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
}
