import Foundation

public struct SystemKeyReservationV1: Sendable {
    public static let shared = SystemKeyReservationV1()

    public let tokens: Set<KeyToken>

    public init() {
        self.tokens = Set([
            Self.token("<D-h>"),
            Self.token("<D-A-h>"),
            Self.token("<D-m>"),
            Self.token("<D-`>"),
            Self.token("<D-S-`>"),
            Self.token("<D-Tab>"),
            Self.token("<D-S-Tab>"),
            Self.token("<D-Space>"),
            Self.token("<D-A-Esc>"),
            Self.token("<D-A-d>"),
            Self.token("<D-S-3>"),
            Self.token("<D-S-4>"),
            Self.token("<D-S-5>"),
            Self.token("<D-C-q>"),
            Self.token("<D-C-f>"),
            Self.token("<D-C-Space>"),
            Self.token("<D-S-q>"),
            Self.token("<D-A-S-q>"),
        ])
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
            preconditionFailure("invalid built-in system reservation \(source): \(error)")
        }
    }
}
