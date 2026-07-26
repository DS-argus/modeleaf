import Foundation

public enum BuiltInThemes {
    public static let all: [Theme] = [
        make(
            .catppuccinMocha,
            "Catppuccin Mocha",
            [
                .background: "#1E1E2E",
                .foreground: "#CDD6F4",
                .mutedText: "#A6ADC8",
                .border: "#45475A",
                .accent: "#89B4FA",
                .activeTab: "#313244",
                .inactiveTab: "#181825",
                .statusline: "#11111B",
                .error: "#F38BA8",
                .searchHighlight: "#F9E2AF",
                .activeSearchHighlight: "#FAB387",
                .focusIndicator: "#89B4FA",
            ]
        ),
        make(
            .tokyoNight,
            "Tokyo Night",
            [
                .background: "#1A1B26",
                .foreground: "#C0CAF5",
                .mutedText: "#9AA5CE",
                .border: "#3B4261",
                .accent: "#7AA2F7",
                .activeTab: "#24283B",
                .inactiveTab: "#16161E",
                .statusline: "#101014",
                .error: "#F7768E",
                .searchHighlight: "#E0AF68",
                .activeSearchHighlight: "#FF9E64",
                .focusIndicator: "#7AA2F7",
            ]
        ),
        make(
            .gruvboxDark,
            "Gruvbox Dark",
            [
                .background: "#282828",
                .foreground: "#EBDBB2",
                .mutedText: "#A89984",
                .border: "#504945",
                .accent: "#83A598",
                .activeTab: "#3C3836",
                .inactiveTab: "#1D2021",
                .statusline: "#1D2021",
                .error: "#FB4934",
                .searchHighlight: "#FABD2F",
                .activeSearchHighlight: "#FE8019",
                .focusIndicator: "#83A598",
            ]
        ),
        make(
            .nord,
            "Nord",
            [
                .background: "#2E3440",
                .foreground: "#ECEFF4",
                .mutedText: "#D8DEE9",
                .border: "#4C566A",
                .accent: "#88C0D0",
                .activeTab: "#3B4252",
                .inactiveTab: "#242933",
                .statusline: "#242933",
                .error: "#BF616A",
                .searchHighlight: "#EBCB8B",
                .activeSearchHighlight: "#D08770",
                .focusIndicator: "#88C0D0",
            ]
        ),
        make(
            .catppuccinLatte,
            "Catppuccin Latte",
            [
                .background: "#EFF1F5",
                .foreground: "#4C4F69",
                .mutedText: "#6C6F85",
                .border: "#BCC0CC",
                .accent: "#1E66F5",
                .activeTab: "#DCE0E8",
                .inactiveTab: "#E6E9EF",
                .statusline: "#DCE0E8",
                .error: "#D20F39",
                .searchHighlight: "#DF8E1D",
                .activeSearchHighlight: "#FE640B",
                .focusIndicator: "#1E66F5",
            ]
        ),
    ]

    public static func theme(for id: ThemeID) -> Theme {
        guard let theme = all.first(where: { $0.id == id }) else {
            preconditionFailure("missing built-in theme \(id.rawValue)")
        }
        return theme
    }

    private static func make(_ id: ThemeID, _ displayName: String, _ colors: [ThemeToken: String]) -> Theme {
        precondition(Set(colors.keys) == Set(ThemeToken.allCases))
        let values = Dictionary(uniqueKeysWithValues: colors.map { token, source in
            guard let color = ThemeColor(rawValue: source) else {
                preconditionFailure("invalid built-in color \(source)")
            }
            return (token, color)
        })
        guard let palette = ThemePalette(values: values) else {
            preconditionFailure("incomplete built-in palette \(id.rawValue)")
        }
        return Theme(id: id, displayName: displayName, palette: palette)
    }
}
