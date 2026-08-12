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
    public let prefix: String?

    public init(prefixTimeoutMilliseconds: Int? = nil, prefix: String? = nil) {
        self.prefixTimeoutMilliseconds = prefixTimeoutMilliseconds
        self.prefix = prefix
    }

    enum CodingKeys: String, CodingKey {
        case prefixTimeoutMilliseconds = "prefix_timeout_ms"
        case prefix
    }
}


public struct SparseAppConfig: Decodable, Equatable, Sendable {
    public let keymap: [String: [String]]?
    public let navigation: SparseNavigationConfiguration?
    public let input: SparseInputConfiguration?

    public init(
        keymap: [String: [String]]? = nil,
        navigation: SparseNavigationConfiguration? = nil,
        input: SparseInputConfiguration? = nil
    ) {
        self.keymap = keymap
        self.navigation = navigation
        self.input = input
    }

}
