import AppKit
import PDFReaderCore

enum AppKitKeyEventAdapter {
    static func tokens(for event: NSEvent) -> [KeyToken] {
        guard event.type == .keyDown else { return [] }

        let modifiers = keyModifiers(from: event.modifierFlags)
        guard let characters = event.charactersIgnoringModifiers ?? event.characters else {
            return [.imeComposition]
        }
        guard !characters.isEmpty else { return [.deadKey] }
        guard characters.count == 1, let character = characters.first else {
            return [.imeComposition]
        }

        // Ctrl-I is a printable physical chord, not the Tab hardware key.
        // AppKit may report it as a control character, so key code is the
        // stable distinction between Ctrl-I (34) and Tab (48).
        if event.keyCode == 34, modifiers == [.control] {
            return [KeyToken(symbol: .character("i"), modifiers: .control)]
        }
        if let namedKey = namedKey(for: character, keyCode: event.keyCode) {
            return [KeyToken(symbol: .named(namedKey), modifiers: modifiers)]
        }

        var candidates: [KeyToken] = []
        if modifiers == .shift,
           let produced = event.characters,
           produced.count == 1
        {
            candidates.append(KeyToken(symbol: .character(produced)))
        }

        let unmodifiedCharacters = modifiers.contains(.shift)
            ? unmodifiedCharacters(for: event)
            : nil
        let chordCharacter = unmodifiedCharacters.flatMap {
            $0.count == 1 ? $0.first : nil
        } ?? character
        let value = String(chordCharacter)
        candidates.append(KeyToken(symbol: .character(value), modifiers: modifiers))

        if let alias = printableAlias(for: chordCharacter) {
            candidates.append(KeyToken(symbol: .named(alias), modifiers: modifiers))
        }
        return candidates.removingDuplicates()
    }

    /// Layout translation used for physical-key chord candidates.
    ///
    /// `NSEvent.characters(byApplyingModifiers:)` consults the system's current
    /// keyboard layout, which makes synthesized test events dependent on the
    /// machine's active input source (e.g. a Hangul layout translates key code
    /// 5 to "\u{314E}" instead of "g"). Tests may pin this seam to a
    /// deterministic translation; production always uses the live layout.
    nonisolated(unsafe) static var unmodifiedCharactersProvider: (NSEvent) -> String? = {
        $0.characters(byApplyingModifiers: [])
    }

    private static func unmodifiedCharacters(for event: NSEvent) -> String? {
        unmodifiedCharactersProvider(event)
    }
    private static func keyModifiers(from flags: NSEvent.ModifierFlags) -> KeyModifiers {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: KeyModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    private static func namedKey(for character: Character, keyCode: UInt16) -> NamedKey? {
        switch keyCode {
        case 36, 76: return .carriageReturn
        case 48: return .tab
        case 51: return .backspace
        case 53: return .escape
        case 115: return .home
        case 116: return .pageUp
        case 117: return .deleteForward
        case 119: return .end
        case 121: return .pageDown
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: break
        }

        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value
        else {
            return nil
        }
        switch Int(value) {
        case 0x1B: return .escape
        case 0x0A, 0x0D: return .carriageReturn
        case 0x08, 0x7F: return .backspace
        case NSDeleteFunctionKey: return .deleteForward
        case NSLeftArrowFunctionKey: return .left
        case NSRightArrowFunctionKey: return .right
        case NSUpArrowFunctionKey: return .up
        case NSDownArrowFunctionKey: return .down
        case NSHomeFunctionKey: return .home
        case NSEndFunctionKey: return .end
        case NSPageUpFunctionKey: return .pageUp
        case NSPageDownFunctionKey: return .pageDown
        case NSF1FunctionKey...NSF24FunctionKey:
            return .function(Int(value) - NSF1FunctionKey + 1)
        default:
            return character == " " ? .space : nil
        }
    }

    private static func printableAlias(for character: Character) -> NamedKey? {
        switch character {
        case "`": .backtick
        case "<": .lessThan
        case ">": .greaterThan
        case "+": .plus
        case "-": .minus
        case "=": .equal
        case "/": .slash
        default: nil
        }
    }
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
