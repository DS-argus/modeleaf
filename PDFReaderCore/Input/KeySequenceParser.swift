import Foundation

public struct KeySequenceParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Reason: Equatable, Sendable {
        case emptySequence
        case unterminatedChord
        case unexpectedClosingBracket
        case emptyChord
        case nestedChord
        case duplicateModifier(String)
        case unknownModifier(String)
        case unknownKey(String)
        case uppercaseLatinBase(String)
        case removedNamedKey(String)
        case unsupportedLiteral(String)
    }

    public let source: String
    public let characterOffset: Int
    public let reason: Reason

    public init(source: String, characterOffset: Int, reason: Reason) {
        self.source = source
        self.characterOffset = characterOffset
        self.reason = reason
    }

    public var description: String {
        "invalid key sequence at character \(characterOffset): \(reasonDescription)"
    }

    private var reasonDescription: String {
        switch reason {
        case .emptySequence: "sequence is empty"
        case .unterminatedChord: "chord is missing >"
        case .unexpectedClosingBracket: "unexpected >"
        case .emptyChord: "chord is empty"
        case .nestedChord: "nested < is not allowed"
        case let .duplicateModifier(modifier): "duplicate modifier \(modifier)"
        case let .unknownModifier(modifier): "unknown modifier \(modifier)"
        case let .unknownKey(key): "unknown or unsupported key \(key)"
        case let .uppercaseLatinBase(key): "uppercase Latin chord base \(key); use <D-S-\(key.lowercased())> or <D-\(key.lowercased())>"
        case let .removedNamedKey(key): "unsupported named key \(key)"
        case let .unsupportedLiteral(literal): "unsupported literal \(literal.debugDescription)"
        }
    }
}

public enum KeySequenceParser {
    public static func parse(_ source: String) throws -> KeySequence {
        guard !source.isEmpty else {
            throw KeySequenceParseError(source: source, characterOffset: 0, reason: .emptySequence)
        }

        var tokens: [KeyToken] = []
        var index = source.startIndex
        var offset = 0

        while index < source.endIndex {
            let character = source[index]
            if character == "<" {
                let bodyStart = source.index(after: index)
                guard let close = source[bodyStart...].firstIndex(of: ">") else {
                    throw KeySequenceParseError(source: source, characterOffset: offset, reason: .unterminatedChord)
                }
                let body = String(source[bodyStart..<close])
                guard !body.isEmpty else {
                    throw KeySequenceParseError(source: source, characterOffset: offset, reason: .emptyChord)
                }
                guard !body.contains("<") else {
                    throw KeySequenceParseError(source: source, characterOffset: offset, reason: .nestedChord)
                }
                tokens.append(try parseChord(body, source: source, offset: offset))
                offset += source[index...close].count
                index = source.index(after: close)
                continue
            }

            guard character != ">" else {
                throw KeySequenceParseError(source: source, characterOffset: offset, reason: .unexpectedClosingBracket)
            }
            guard isSupportedLiteral(character) else {
                throw KeySequenceParseError(
                    source: source,
                    characterOffset: offset,
                    reason: .unsupportedLiteral(String(character))
                )
            }
            tokens.append(KeyToken(symbol: .character(String(character))))
            index = source.index(after: index)
            offset += 1
        }

        return KeySequence(tokens: tokens)
    }

    public static func parseSingleToken(_ source: String) throws -> KeyToken {
        let sequence = try parse(source)
        guard let token = sequence.singleToken else {
            throw KeySequenceParseError(source: source, characterOffset: 0, reason: .unknownKey(source))
        }
        return token
    }

    private static func parseChord(
        _ body: String,
        source: String,
        offset: Int
    ) throws -> KeyToken {
        let components = body.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let rawBase = components.last, !rawBase.isEmpty else {
            throw KeySequenceParseError(source: source, characterOffset: offset, reason: .unknownKey(body))
        }

        var modifiers: KeyModifiers = []
        for rawModifier in components.dropLast() {
            let modifier: KeyModifiers
            switch rawModifier.uppercased() {
            case "D": modifier = .command
            case "C": modifier = .control
            case "A": modifier = .option
            case "S": modifier = .shift
            default:
                throw KeySequenceParseError(
                    source: source,
                    characterOffset: offset,
                    reason: .unknownModifier(rawModifier)
                )
            }
            guard !modifiers.contains(modifier) else {
                throw KeySequenceParseError(
                    source: source,
                    characterOffset: offset,
                    reason: .duplicateModifier(rawModifier.uppercased())
                )
            }
            modifiers.insert(modifier)
        }

        let parsed = try parseBase(rawBase, source: source, offset: offset)
        if parsed.backtabAlias {
            guard !modifiers.contains(.shift) else {
                throw KeySequenceParseError(
                    source: source,
                    characterOffset: offset,
                    reason: .duplicateModifier("S")
                )
            }
            modifiers.insert(.shift)
        }
        if modifiers == [.shift], case let .character(character) = parsed.symbol,
           isLowercaseLatinLetter(character)
        {
            return KeyToken(symbol: .character(character.uppercased()))
        }
        return KeyToken(symbol: parsed.symbol, modifiers: modifiers)
    }

    private static func parseBase(
        _ rawBase: String,
        source: String,
        offset: Int
    ) throws -> (symbol: KeySymbol, backtabAlias: Bool) {
        if isUppercaseLatinLetter(rawBase) {
            throw KeySequenceParseError(
                source: source,
                characterOffset: offset,
                reason: .uppercaseLatinBase(rawBase)
            )
        }

        let lower = rawBase.lowercased()
        let named: NamedKey?
        switch lower {
        case "esc": named = .escape
        case "enter": named = .carriageReturn
        case "bs": named = .backspace
        case "del": named = .deleteForward
        case "tab": named = .tab
        case "backtab": return (.named(.tab), true)
        case "left": named = .left
        case "right": named = .right
        case "up": named = .up
        case "down": named = .down
        case "home": named = .home
        case "end": named = .end
        case "pageup": named = .pageUp
        case "pagedown": named = .pageDown
        case "space": named = .space
        case "lt": named = .lessThan
        case "gt": named = .greaterThan
        case "minus": named = .minus
        case "escape": throw removedNamedKeyError(rawBase, replacement: "Esc", source: source, offset: offset)
        case "cr", "return": throw removedNamedKeyError(rawBase, replacement: "Enter", source: source, offset: offset)
        case "backspace": throw removedNamedKeyError(rawBase, replacement: "BS", source: source, offset: offset)
        case "delete": throw removedNamedKeyError(rawBase, replacement: "Del", source: source, offset: offset)
        case "backtick": throw removedNamedKeyError(rawBase, replacement: "literal `", source: source, offset: offset)
        case "plus": throw removedNamedKeyError(rawBase, replacement: "literal +", source: source, offset: offset)
        case "equal": throw removedNamedKeyError(rawBase, replacement: "literal =", source: source, offset: offset)
        case "slash": throw removedNamedKeyError(rawBase, replacement: "literal /", source: source, offset: offset)
        default:
            if lower.first == "f", let number = Int(lower.dropFirst()), (1...12).contains(number) {
                named = .function(number)
            } else if lower.first == "f", let number = Int(lower.dropFirst()), (13...24).contains(number) {
                throw removedNamedKeyError(rawBase, replacement: "F1~F12 only", source: source, offset: offset)
            } else {
                named = nil
            }
        }
        if let named { return (.named(named), false) }

        if rawBase.count == 1, let character = rawBase.first, isSupportedLiteral(character) {
            return (.character(String(character)), false)
        }
        throw KeySequenceParseError(source: source, characterOffset: offset, reason: .unknownKey(rawBase))
    }

    private static func removedNamedKeyError(
        _ key: String,
        replacement: String,
        source: String,
        offset: Int
    ) -> KeySequenceParseError {
        KeySequenceParseError(
            source: source,
            characterOffset: offset,
            reason: .removedNamedKey("\(key); use \(replacement)")
        )
    }

    private static func isLowercaseLatinLetter(_ value: String) -> Bool {
        value.count == 1 && value.unicodeScalars.allSatisfy { (0x61...0x7A).contains($0.value) }
    }

    private static func isUppercaseLatinLetter(_ value: String) -> Bool {
        value.count == 1 && value.unicodeScalars.allSatisfy { (0x41...0x5A).contains($0.value) }
    }

    private static func isSupportedLiteral(_ character: Character) -> Bool {
        let value = String(character)
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
    }
}
