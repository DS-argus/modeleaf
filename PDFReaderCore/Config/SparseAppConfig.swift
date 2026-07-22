import Foundation

public struct SparseNavigationConfiguration: Decodable, Equatable, Sendable {
    public let smallScrollPoints: Double?
    public let largeScrollViewportFraction: Double?
    public let zoomFactor: Double?

    public init(
        smallScrollPoints: Double? = nil,
        largeScrollViewportFraction: Double? = nil,
        zoomFactor: Double? = nil
    ) {
        self.smallScrollPoints = smallScrollPoints
        self.largeScrollViewportFraction = largeScrollViewportFraction
        self.zoomFactor = zoomFactor
    }

    enum CodingKeys: String, CodingKey {
        case smallScrollPoints = "small_scroll_points"
        case largeScrollViewportFraction = "large_scroll_viewport_fraction"
        case zoomFactor = "zoom_factor"
    }
}

public struct SparseInputConfiguration: Decodable, Equatable, Sendable {
    public let prefixTimeoutMilliseconds: Int?

    public init(prefixTimeoutMilliseconds: Int? = nil) {
        self.prefixTimeoutMilliseconds = prefixTimeoutMilliseconds
    }

    enum CodingKeys: String, CodingKey {
        case prefixTimeoutMilliseconds = "prefix_timeout_ms"
    }
}

public struct SparseThemeConfiguration: Decodable, Equatable, Sendable {
    public let builtIn: String?
    public let overrides: [String: String]?

    public init(builtIn: String? = nil, overrides: [String: String]? = nil) {
        self.builtIn = builtIn
        self.overrides = overrides
    }

    enum CodingKeys: String, CodingKey {
        case builtIn = "built_in"
        case overrides
    }
}

public struct SparseAppConfig: Decodable, Equatable, Sendable {
    public let keymap: [String: [String]]?
    public let navigation: SparseNavigationConfiguration?
    public let input: SparseInputConfiguration?
    public let theme: SparseThemeConfiguration?

    public init(
        keymap: [String: [String]]? = nil,
        navigation: SparseNavigationConfiguration? = nil,
        input: SparseInputConfiguration? = nil,
        theme: SparseThemeConfiguration? = nil
    ) {
        self.keymap = keymap
        self.navigation = navigation
        self.input = input
        self.theme = theme
    }
}
