import Foundation

public enum ThemeID: String, CaseIterable, Codable, Hashable, Sendable {
    case tokyoNight = "tokyo-night"
    case gruvboxDark = "gruvbox-dark"
    case solarizedDark = "solarized-dark"
    case dracula
    case everforest
    case nord
    case catppuccinLatte = "catppuccin-latte"
}

public enum ThemeToken: String, CaseIterable, Codable, Hashable, Sendable {
    case background
    case foreground
    case mutedText = "muted-text"
    case border
    case accent
    case activeTab = "active-tab"
    case inactiveTab = "inactive-tab"
    case statusline
    case error
    case searchHighlight = "search-highlight"
    case activeSearchHighlight = "active-search-highlight"
    case focusIndicator = "focus-indicator"
}

public struct ThemeColor: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.first == "#" else { return nil }
        let digits = rawValue.dropFirst()
        guard digits.count == 6 || digits.count == 8,
              digits.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value)
                      || (65...70).contains(scalar.value)
                      || (97...102).contains(scalar.value)
              })
        else {
            return nil
        }
        self.rawValue = "#" + digits.uppercased()
    }

    public var description: String { rawValue }
}

public struct ThemePalette: Equatable, Sendable {
    public let values: [ThemeToken: ThemeColor]

    public init?(values: [ThemeToken: ThemeColor]) {
        guard Set(values.keys) == Set(ThemeToken.allCases) else { return nil }
        self.values = values
    }

    public subscript(token: ThemeToken) -> ThemeColor {
        values[token]!
    }
}

public struct Theme: Equatable, Sendable {
    public let id: ThemeID
    public let displayName: String
    public let palette: ThemePalette

    public init(id: ThemeID, displayName: String, palette: ThemePalette) {
        self.id = id
        self.displayName = displayName
        self.palette = palette
    }
}
