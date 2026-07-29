import Foundation

/// Renders a key sequence as a human-readable shortcut (e.g. `Ctrl+j`, `Cmd+o`,
/// `Cmd+Shift+P`). Shared by the generated config comments and the command palette so both
public enum KeyBindingHint {
    public static func text(for sequence: KeySequence) -> String? {
        guard !sequence.tokens.isEmpty else { return nil }
        return sequence.tokens.map(token).joined(separator: " ")
    }

    private static func token(_ token: KeyToken) -> String {
        let names: [String: String] = ["D": "Cmd", "C": "Ctrl", "A": "Opt", "S": "Shift"]
        let mods = token.modifiers.canonicalNames.map { names[$0] ?? $0 }
        let base: String
        switch token.symbol {
        case let .character(character):
            base = token.modifiers.contains(.shift) ? character.uppercased() : character
        case let .named(key):
            base = named(key)
        case .deadKey, .imeComposition:
            base = token.description
        }
        return (mods + [base]).joined(separator: "+")
    }

    private static func named(_ key: NamedKey) -> String {
        switch key {
        case .carriageReturn: return "Enter"
        case .escape: return "Esc"
        case .space: return "Space"
        case .tab: return "Tab"
        case .backspace: return "Backspace"
        case .deleteForward: return "Del"
        case .left: return "Left"
        case .right: return "Right"
        case .up: return "Up"
        case .down: return "Down"
        case .minus: return "-"
        case .equal: return "="
        case .plus: return "+"
        case .slash: return "/"
        case .lessThan: return "<"
        case .greaterThan: return ">"
        case .backtick: return "`"
        default: return key.canonicalName
        }
    }
}
