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
        input: InputConfiguration(prefixTimeoutMilliseconds: 300),
        theme: ThemeConfiguration(builtIn: .catppuccinMocha)
    )

    public static let keymap: [ActionID: [KeySequence]] = [
        .documentOpen: sequences("<D-o>"),
        .documentClose: sequences("<D-w>"),
        .appQuit: sequences("<D-q>"),

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


        .paneSplitRight: sequences("<C-w>v"),
        .paneSplitDown: sequences("<C-w>s"),
        .paneFocusLeft: sequences("<C-h>"),
        .paneFocusDown: sequences("<C-j>"),
        .paneFocusUp: sequences("<C-k>"),
        .paneFocusRight: sequences("<C-l>"),
        .paneUnsplit: sequences("<C-w>o"),
    ]

    public static var defaultConfigTOML: String {
        var lines = [
            "# Generated from PDFReaderCore.BuiltInDefaults. Do not edit this bundled copy.",
            "# Copy it to ~/.config/modeleaf/config.toml and edit the copy.",
            "",
            "[keymap]",
        ]
        for descriptor in ActionRegistry.v1.descriptors {
            let values = keymap[descriptor.id, default: []]
                .map { "\"\(escapeTOML($0.description))\"" }
                .joined(separator: ", ")
            lines.append("\"\(descriptor.id.rawValue)\" = [\(values)]")
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
            "",
            "[theme]",
            "built_in = \"\(config.theme.builtIn.rawValue)\"",
            "",
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
}
