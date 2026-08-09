import Foundation

public enum BuiltInThemes {
    public static let all: [Theme] = [
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
            .solarizedDark,
            "Solarized Dark",
            [
                .background: "#002B36",
                .foreground: "#839496",
                .mutedText: "#586E75",
                .border: "#0B4F5E",
                .accent: "#268BD2",
                .activeTab: "#073642",
                .inactiveTab: "#001F27",
                .statusline: "#001F27",
                .error: "#DC322F",
                .searchHighlight: "#B58900",
                .activeSearchHighlight: "#CB4B16",
                .focusIndicator: "#268BD2",
            ]
        ),
        make(
            .dracula,
            "Dracula",
            [
                .background: "#282A36",
                .foreground: "#F8F8F2",
                .mutedText: "#6272A4",
                .border: "#44475A",
                .accent: "#BD93F9",
                .activeTab: "#44475A",
                .inactiveTab: "#21222C",
                .statusline: "#191A21",
                .error: "#FF5555",
                .searchHighlight: "#F1FA8C",
                .activeSearchHighlight: "#FFB86C",
                .focusIndicator: "#BD93F9",
            ]
        ),
        make(
            .everforest,
            "Everforest",
            [
                .background: "#2D353B",
                .foreground: "#D3C6AA",
                .mutedText: "#859289",
                .border: "#475258",
                .accent: "#A7C080",
                .activeTab: "#343F44",
                .inactiveTab: "#232A2E",
                .statusline: "#232A2E",
                .error: "#E67E80",
                .searchHighlight: "#DBBC7F",
                .activeSearchHighlight: "#E69875",
                .focusIndicator: "#A7C080",
            ]
        ),
        make(
            .nord,
            "Nord",
            [
                .background: "#2E3440",
                .foreground: "#D8DEE9",
                .mutedText: "#81A1C1",
                .border: "#4C566A",
                .accent: "#88C0D0",
                .activeTab: "#3B4252",
                .inactiveTab: "#272C36",
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
