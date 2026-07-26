import Foundation

public struct NavigationConfiguration: Equatable, Sendable {
    public let smallScrollPoints: Double
    public let largeScrollViewportFraction: Double
    public let zoomFactor: Double

    public init(
        smallScrollPoints: Double,
        largeScrollViewportFraction: Double,
        zoomFactor: Double
    ) {
        self.smallScrollPoints = smallScrollPoints
        self.largeScrollViewportFraction = largeScrollViewportFraction
        self.zoomFactor = zoomFactor
    }
}

public struct InputConfiguration: Equatable, Sendable {
    public let prefixTimeoutMilliseconds: Int

    public init(prefixTimeoutMilliseconds: Int) {
        self.prefixTimeoutMilliseconds = prefixTimeoutMilliseconds
    }
}

public struct EffectiveAppConfig: Equatable, Sendable {
    public let keymap: [ActionID: [KeySequence]]
    public let navigation: NavigationConfiguration
    public let input: InputConfiguration

    public init(
        keymap: [ActionID: [KeySequence]],
        navigation: NavigationConfiguration,
        input: InputConfiguration
    ) {
        self.keymap = keymap
        self.navigation = navigation
        self.input = input
    }
}
