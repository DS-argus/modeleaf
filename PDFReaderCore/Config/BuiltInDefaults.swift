import Foundation

public enum ConfigBounds {
    public static let smallScrollPoints = 1.0...512.0
    public static let largeScrollViewportFraction = 0.1...2.0
    public static let zoomFactor = 1.01...2.0
    public static let prefixTimeoutMilliseconds = 100...2_000
}

public enum BuiltInDefaults {
    public static let config = EffectiveAppConfig(
        keymap: keymap,
        navigation: NavigationConfiguration(
            smallScrollPoints: 48.0,
            largeScrollViewportFraction: 0.8,
            zoomFactor: 1.10
        ),
        input: InputConfiguration(prefixTimeoutMilliseconds: 800, prefix: "<C-b>")
    )

    public static let keymap: [ActionID: [KeySequence]] = [
        .documentOpen: sequences("<D-o>"),
        .documentClose: sequences("<D-w>"),
        .appQuit: sequences("<D-q>"),
        .appNew: sequences("<D-n>"),
        .paletteOpen: sequences(":", "<D-S-p>"),
        .helpShow: sequences("?"),

        .tabNext: sequences("N"),
        .tabPrevious: sequences("P"),
        .tabSelect1: sequences("<D-1>"),
        .tabSelect2: sequences("<D-2>"),
        .tabSelect3: sequences("<D-3>"),
        .tabSelect4: sequences("<D-4>"),
        .tabSelect5: sequences("<D-5>"),
        .tabSelect6: sequences("<D-6>"),
        .tabSelect7: sequences("<D-7>"),
        .tabSelect8: sequences("<D-8>"),
        .tabSelect9: sequences("<D-9>"),

        .scrollLeft: sequences("h"),
        .scrollDown: sequences("j"),
        .scrollUp: sequences("k"),
        .scrollRight: sequences("l"),
        .scrollLargeDown: sequences("d"),
        .scrollLargeUp: sequences("u"),

        .pageNext: sequences("n"),
        .pagePrevious: sequences("p"),
        .pageFirst: sequences("gg"),
        .pageLast: sequences("G"),
        .pagePrompt: sequences("g"),

        .promptCommit: sequences("<CR>"),
        .promptCancel: sequences("<Esc>"),

        .searchPrompt: sequences("/"),
        .searchNext: sequences("<CR>"),
        .searchPrevious: sequences("<S-CR>"),
        .searchCancel: sequences("<Esc>"),

        .viewZoomIn: sequences("="),
        .viewZoomOut: sequences("-"),
        .viewZoomReset: [],
        .viewFitWidth: sequences("w"),
        .viewFitPage: sequences("f"),

        .themePicker: sequences("T"),

        // Pane prefix: Ctrl+b (the tmux default), with tmux-style split
        // mnemonics (| splits side-by-side, - splits stacked). Unlike
        // Ctrl+Space it never collides with the macOS input-source switcher.
        // The prefix is user-configurable by rebinding these sequences in
        // config.toml.
        .paneSplitRight: sequences("<C-b>|"),
        .paneSplitDown: sequences("<C-b>-"),
        .paneFocusLeft: sequences("<C-h>"),
        .paneFocusDown: sequences("<C-j>"),
        .paneFocusUp: sequences("<C-k>"),
        .paneFocusRight: sequences("<C-l>"),
        .paneUnsplit: sequences("<C-b>o"),
    ]

    public static var defaultConfigTOML: String {
        var lines = [
            "# Modeleaf configuration \u{2014} generated from PDFReaderCore.BuiltInDefaults.",
            "# Do not edit this bundled copy. Copy it to ~/.config/modeleaf/config.toml and edit the copy.",
            "#",
            "# Key notation (chords are wrapped in <...>):",
            "#   D = Command (Cmd)   C = Control (Ctrl)   A = Option (Alt)   S = Shift",
            "#   e.g. <D-o> = Cmd+O, <C-j> = Ctrl+J, <S-CR> = Shift+Enter.",
            "#   Plain characters are literal keys; concatenation is a multi-key sequence (gg = g then g).",
            "#   <prefix> expands to the pane prefix defined under [input] below. Rebind the prefix",
            "#   once and every <prefix> binding follows; <prefix> may be used in any binding.",
            "#",
            "# Enter/Esc prompt commit & cancel and search next/previous are fixed keys and are",
            "# intentionally omitted here \u{2014} they cannot be rebound.",
            "",
            "[keymap]",
        ]
        var previousCategory: String?
        for descriptor in ActionRegistry.v1.userConfigurableDescriptors {
            let category = categoryTitle(for: descriptor.id)
            if category != previousCategory {
                lines.append("")
                lines.append("# --- \(category) ---")
                if category == "Panes" {
                    lines.append("# split/unsplit use <prefix>; focus keys are direct. Change the prefix under [input].")
                }
                previousCategory = category
            }
            let sequences = keymap[descriptor.id, default: []]
            let rendered = sequences
                .map { "\"\(escapeTOML(templated($0.description)))\"" }
                .joined(separator: ", ")
            let key = "\"\(descriptor.id.rawValue)\""
            let padded = key.padding(toLength: max(key.count, 18), withPad: " ", startingAt: 0)
            let assignment = "\(padded) = [\(rendered)]"
            if let hint = keyHint(sequences) {
                lines.append("\(assignment)  # \(hint)")
            } else {
                lines.append(assignment)
            }
        }
        lines += [
            "",
            "[navigation]",
            "small_scroll_points = \(config.navigation.smallScrollPoints)",
            "large_scroll_viewport_fraction = \(config.navigation.largeScrollViewportFraction)",
            "zoom_factor = \(config.navigation.zoomFactor)",
            "",
            "[input]",
            "prefix_timeout_ms = \(config.input.prefixTimeoutMilliseconds)",
            "# Pane prefix chord. Every <prefix> binding above expands to this.",
            "prefix = \"\(escapeTOML(config.input.prefix))\"",
        ]
        return lines.joined(separator: "\n")
    }

    private static func sequences(_ sources: String...) -> [KeySequence] {
        sources.map { source in
            do {
                return try KeySequenceParser.parse(source)
            } catch {
                preconditionFailure("invalid built-in binding \(source): \(error)")
            }
        }
    }

    private static func escapeTOML(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
    public static func categoryTitle(for id: ActionID) -> String {
        switch String(id.rawValue.prefix(while: { $0 != "." })) {
        case "app", "document": return "Application"
        case "palette": return "Command palette"
        case "help": return "Help"
        case "tab": return "Tabs"
        case "scroll": return "Scroll"
        case "page": return "Pages"
        case "search": return "Search"
        case "view": return "View / Zoom"
        case "theme": return "Theme"
        case "pane": return "Panes"
        default: return "Other"
        }
    }

    private static func templated(_ rendered: String) -> String {
        rendered.replacingOccurrences(of: config.input.prefix, with: "<prefix>")
    }

    private static func keyHint(_ sequences: [KeySequence]) -> String? {
        sequences.first.flatMap(KeyBindingHint.text(for:))
    }
}
