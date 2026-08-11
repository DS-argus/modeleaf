import Foundation

public enum LinkDestinationIndicatorStyle: String, CaseIterable, Codable, Sendable {
    case pulseRing = "pulse-ring"
    case target
    case beacon
    case staticRing = "static-ring"
    case diamondPulse = "diamond-pulse"
}

public enum LinkDestinationIndicatorColorPreset: String, CaseIterable, Codable, Sendable {
    case red
    case amber
    case cyan
    case green
    case purple
    case accent
    case autoContrast = "auto-contrast"
    case highContrast = "high-contrast"
}

public enum LinkDestinationIndicatorColor: Equatable, Sendable {
    case preset(LinkDestinationIndicatorColorPreset)
    case customHex(String)

    public init?(configurationValue: String) {
        let normalized = configurationValue.lowercased()
        if let preset = LinkDestinationIndicatorColorPreset(rawValue: normalized) {
            self = .preset(preset)
            return
        }
        guard normalized.count == 7,
              normalized.first == "#",
              normalized.dropFirst().allSatisfy(\.isHexDigit)
        else { return nil }
        self = .customHex(normalized)
    }

    public var configurationValue: String {
        switch self {
        case let .preset(preset): preset.rawValue
        case let .customHex(value): value
        }
    }
}

public struct LinkDestinationIndicatorSettings: Equatable, Sendable {
    public static let sizeRange = 16.0...48.0
    public static let durationMillisecondsRange = 500...3_000
    public static let standard = LinkDestinationIndicatorSettings(
        style: .pulseRing,
        color: .preset(.red),
        size: 28,
        durationMilliseconds: 1_500
    )

    public let style: LinkDestinationIndicatorStyle
    public let color: LinkDestinationIndicatorColor
    public let size: Double
    public let durationMilliseconds: Int

    public init(
        style: LinkDestinationIndicatorStyle,
        color: LinkDestinationIndicatorColor,
        size: Double,
        durationMilliseconds: Int
    ) {
        precondition(Self.sizeRange.contains(size), "indicator size is outside the supported range")
        precondition(
            Self.durationMillisecondsRange.contains(durationMilliseconds),
            "indicator duration is outside the supported range"
        )
        self.style = style
        self.color = color
        self.size = size
        self.durationMilliseconds = durationMilliseconds
    }
}
