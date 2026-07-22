import Foundation

public struct PromptNativeReservationV1: Sendable {
    public static let shared = PromptNativeReservationV1()

    public let tokens: Set<KeyToken>

    public init() {
        var values = Set([
            Self.token("<BS>"), Self.token("<Del>"), Self.token("<Tab>"), Self.token("<S-Tab>"),
            Self.token("<Left>"), Self.token("<Right>"), Self.token("<Up>"), Self.token("<Down>"),
            Self.token("<Home>"), Self.token("<End>"), Self.token("<PageUp>"), Self.token("<PageDown>"),
            Self.token("<D-a>"), Self.token("<D-c>"), Self.token("<D-x>"), Self.token("<D-v>"),
            Self.token("<D-z>"), Self.token("<D-S-z>"),
        ])
        let navigationKeys = ["Left", "Right", "Up", "Down", "Home", "End", "PageUp", "PageDown", "BS", "Del"]
        let modifierPrefixes = ["S", "A", "A-S", "D", "D-S", "C", "C-S"]
        for key in navigationKeys {
            for modifiers in modifierPrefixes {
                values.insert(Self.token("<\(modifiers)-\(key)>"))
            }
        }
        self.tokens = values
    }

    public func contains(_ token: KeyToken) -> Bool {
        tokens.contains(token)
    }

    public var normalizedEntries: [String] {
        tokens.map(\.description).sorted()
    }

    private static func token(_ source: String) -> KeyToken {
        do {
            return try KeySequenceParser.parseSingleToken(source)
        } catch {
            preconditionFailure("invalid built-in prompt reservation \(source): \(error)")
        }
    }
}
