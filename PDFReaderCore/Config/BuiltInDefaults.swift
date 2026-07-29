import Foundation

public enum ConfigBounds {
    public static let smallScrollPoints = 1.0...512.0
    public static let largeScrollViewportFraction = 0.1...2.0
    public static let zoomFactor = 1.01...2.0
    public static let prefixTimeoutMilliseconds = 100...2_000
}

public enum BuiltInDefaults {
    private static let defaultPrefix = "<C-b>"

    public static let config = EffectiveAppConfig(
        keymap: keymap,
        navigation: NavigationConfiguration(
            smallScrollPoints: 48.0,
            largeScrollViewportFraction: 0.8,
            zoomFactor: 1.10
        ),
        input: InputConfiguration(prefixTimeoutMilliseconds: 800, prefix: defaultPrefix)
    )

    public static let templatedKeymap: [ActionID: [String]] = [
        .documentOpen: ["<D-o>"], .documentClose: ["<D-w>"], .appQuit: ["<D-q>"], .appNew: ["<D-n>"], .paletteOpen: [":", "<D-S-p>"], .helpShow: ["?"],
        .tabNext: ["N"], .tabPrevious: ["P"],
        .tabSelect1: ["<D-1>"], .tabSelect2: ["<D-2>"], .tabSelect3: ["<D-3>"],
        .tabSelect4: ["<D-4>"], .tabSelect5: ["<D-5>"], .tabSelect6: ["<D-6>"],
        .tabSelect7: ["<D-7>"], .tabSelect8: ["<D-8>"], .tabSelect9: ["<D-9>"],
        .scrollLeft: ["h"], .scrollDown: ["j"], .scrollUp: ["k"], .scrollRight: ["l"],
        .scrollLargeDown: ["d"], .scrollLargeUp: ["u"],
        .pageNext: ["n"], .pagePrevious: ["p"], .pageFirst: ["gg"], .pageLast: ["G"], .pagePrompt: ["g"],
        .promptCommit: ["<CR>"], .promptCancel: ["<Esc>"],
        .searchPrompt: ["/"], .searchNext: ["<CR>"], .searchPrevious: ["<S-CR>"], .searchCancel: ["<Esc>"],
        .viewZoomIn: ["="], .viewZoomOut: ["-"], .viewZoomReset: [], .viewFitWidth: ["w"], .viewFitPage: ["F"], .linkHint: ["f"],
        .configReload: ["<prefix>r"], .configWriteDefault: [], .configResetDefault: [],
        .themePicker: ["T"],
        .paneSplitRight: ["<prefix>|"], .paneSplitDown: ["<prefix>-"], .paneUnsplit: ["<prefix>o"],
        .paneFocusLeft: ["<C-h>"], .paneFocusDown: ["<C-j>"], .paneFocusUp: ["<C-k>"], .paneFocusRight: ["<C-l>"],
    ]

    public static let keymap = resolvedKeymap(templatedKeymap, prefix: defaultPrefix)
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
            let templateSources = templatedKeymap[descriptor.id, default: []]
            let rendered = templateSources
                .map { "\"\(escapeTOML($0))\"" }
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

    private static func resolvedKeymap(
        _ templates: [ActionID: [String]],
        prefix: String
    ) -> [ActionID: [KeySequence]] {
        templates.mapValues { sources in
            sources.map { source in
                do {
                    return try KeySequenceParser.parse(source.replacingOccurrences(of: "<prefix>", with: prefix))
                } catch {
                    preconditionFailure("invalid built-in binding \(source): \(error)")
                }
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
        case "link": return "Links"
        case "config": return "Config"
        case "view": return "View / Zoom"
        case "theme": return "Theme"
        case "pane": return "Panes"
        default: return "Other"
        }
    }


    private static func keyHint(_ sequences: [KeySequence]) -> String? {
        sequences.first.flatMap(KeyBindingHint.text(for:))
    }
}
