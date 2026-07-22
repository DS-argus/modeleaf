import Foundation

public struct KeySequence: Hashable, Sendable, CustomStringConvertible {
    public static let empty = KeySequence(tokens: [])

    public let tokens: [KeyToken]

    public init(tokens: [KeyToken]) {
        self.tokens = tokens
    }

    public var description: String {
        tokens.map(\.description).joined()
    }

    public var singleToken: KeyToken? {
        tokens.count == 1 ? tokens[0] : nil
    }
}
