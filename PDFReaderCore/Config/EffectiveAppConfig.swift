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

public struct ThemeConfiguration: Equatable, Sendable {
    public let builtIn: ThemeID
    public let overrides: [ThemeToken: ThemeColor]

    public init(builtIn: ThemeID, overrides: [ThemeToken: ThemeColor] = [:]) {
        self.builtIn = builtIn
        self.overrides = overrides
    }
}

public struct EffectiveAppConfig: Equatable, Sendable {
    public let keymap: [ActionID: [KeySequence]]
    public let navigation: NavigationConfiguration
    public let input: InputConfiguration
    public let theme: ThemeConfiguration

    public init(
        keymap: [ActionID: [KeySequence]],
        navigation: NavigationConfiguration,
        input: InputConfiguration,
        theme: ThemeConfiguration
    ) {
        self.keymap = keymap
        self.navigation = navigation
        self.input = input
        self.theme = theme
    }
}
