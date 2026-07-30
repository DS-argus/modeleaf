import Foundation

public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)

    public static let canonicalOrder: [(modifier: KeyModifiers, name: String)] = [
        (.command, "D"),
        (.control, "C"),
        (.option, "A"),
        (.shift, "S"),
    ]

    public var canonicalNames: [String] {
        Self.canonicalOrder.compactMap { contains($0.modifier) ? $0.name : nil }
    }
}

public enum NamedKey: Hashable, Sendable {
    case escape
    case carriageReturn
    case backspace
    case deleteForward
    case tab
    case left
    case right
    case up
    case down
    case home
    case end
    case pageUp
    case pageDown
    case space
    case backtick
    case lessThan
    case greaterThan
    case plus
    case minus
    case equal
    case slash
    case function(Int)

    public var canonicalName: String {
        switch self {
        case .escape: "Esc"
        case .carriageReturn: "Enter"
        case .backspace: "BS"
        case .deleteForward: "Del"
        case .tab: "Tab"
        case .left: "Left"
        case .right: "Right"
        case .up: "Up"
        case .down: "Down"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "PageUp"
        case .pageDown: "PageDown"
        case .space: "Space"
        case .backtick: "Backtick"
        case .lessThan: "LT"
        case .greaterThan: "GT"
        case .plus: "Plus"
        case .minus: "Minus"
        case .equal: "Equal"
        case .slash: "Slash"
        case let .function(number): "F\(number)"
        }
    }

    public var representsPrintableCharacter: Bool {
        switch self {
        case .space, .backtick, .lessThan, .greaterThan, .plus, .minus, .equal, .slash:
            true
        default:
            false
        }
    }
}

public enum KeySymbol: Hashable, Sendable {
    case character(String)
    case named(NamedKey)
    case deadKey
    case imeComposition
}

public struct KeyToken: Hashable, Sendable, CustomStringConvertible {
    public let symbol: KeySymbol
    public let modifiers: KeyModifiers

    public init(symbol: KeySymbol, modifiers: KeyModifiers = []) {
        let normalized = Self.normalized(symbol, modifiers: modifiers)
        self.symbol = normalized.symbol
        self.modifiers = normalized.modifiers
    }

    public static let deadKey = KeyToken(symbol: .deadKey)
    public static let imeComposition = KeyToken(symbol: .imeComposition)

    public var isPrintable: Bool {
        switch symbol {
        case .character:
            true
        case let .named(key):
            key.representsPrintableCharacter
        case .deadKey, .imeComposition:
            false
        }
    }

    public var isCompositionInput: Bool {
        switch symbol {
        case .deadKey, .imeComposition:
            true
        default:
            false
        }
    }

    public var hasCommand: Bool { modifiers.contains(.command) }

    public var isAppKitRepresentable: Bool {
        switch symbol {
        case .character, .named:
            true
        case .deadKey, .imeComposition:
            false
        }
    }

    public var description: String {
        switch symbol {
        case let .character(character) where modifiers.isEmpty:
            character
        case let .character(character):
            chordDescription(base: character)
        case let .named(key):
            chordDescription(base: key.canonicalName)
        case .deadKey:
            "<DeadKey>"
        case .imeComposition:
            "<IME>"
        }
    }

    private func chordDescription(base: String) -> String {
        let components = modifiers.canonicalNames + [base]
        return "<\(components.joined(separator: "-"))>"
    }

    private static func normalized(
        _ symbol: KeySymbol,
        modifiers: KeyModifiers
    ) -> (symbol: KeySymbol, modifiers: KeyModifiers) {
        guard case let .character(character) = symbol else { return (symbol, modifiers) }
        if modifiers == [.shift], isLowercaseASCIILatinLetter(character) {
            return (.character(character.uppercased()), [])
        }
        guard !modifiers.isEmpty else { return (symbol, modifiers) }
        return (.character(character.lowercased()), modifiers)
    }

    private static func isLowercaseASCIILatinLetter(_ value: String) -> Bool {
        value.count == 1 && value.unicodeScalars.allSatisfy { (0x61...0x7A).contains($0.value) }
    }
}
