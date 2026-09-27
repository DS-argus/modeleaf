import AppKit
import PDFReaderCore

@MainActor
enum ShortcutKeyDisplay {
    /// The active keyboard layout's translation for a physical key and modifier flags.
    /// Tests replace this closure with a deterministic layout table without changing the user's
    /// input source.
    static var layoutCharactersProvider: (UInt16, NSEvent.ModifierFlags) -> String? = {
        keyCode, modifiers in
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: keyCode
        ) else {
            return nil
        }
        return event.characters(byApplyingModifiers: modifiers)
    }

    /// Renders the source spelling used by settings and recording. Source identity is retained:
    /// a bare produced character is not rewritten to the physical Shift chord that may produce it
    /// on the active keyboard layout.
    static func text(for source: String) -> String {
        let prefixMarker = "<prefix>"
        let usesPrefix = source.hasPrefix(prefixMarker)
        let sequenceSource = usesPrefix ? String(source.dropFirst(prefixMarker.count)) : source
        guard !sequenceSource.isEmpty,
              let sequence = try? KeySequenceParser.parse(sequenceSource),
              !sequence.tokens.isEmpty
        else {
            return source
        }

        let rendered = sequence.tokens.map(render).joined(separator: " → ")
        return usesPrefix ? "<pre> → \(rendered)" : rendered
    }

    /// Renders a resolved key sequence using the configured common prefix. A prefix is shown as
    /// `<pre>` only when it is the complete first token of a multi-token sequence.
    static func text(for sequence: KeySequence, prefix: String) -> String {
        guard !sequence.tokens.isEmpty else { return "" }
        let prefixToken = try? KeySequenceParser.parseSingleToken(prefix)
        let usesPrefix = sequence.tokens.count > 1 && sequence.tokens.first == prefixToken
        let rendered = sequence.tokens.enumerated().map { index, token in
            usesPrefix && index == 0 ? "<pre>" : render(token)
        }.joined(separator: " → ")
        return rendered
    }

    /// Returns editable aliases before any immutable foundational bindings for an action.
    /// `ValidatedKeymap` stores foundations first for runtime validation, while presentation keeps
    /// the user-configurable alias as the primary shortcut.
    static func orderedBindings(for action: ActionID, keymap: ValidatedKeymap) -> [KeySequence] {
        let bindings = keymap.bindings(for: action)
        let foundations = Set(FoundationalBindings.sequences(for: action))
        let aliases = bindings.filter { !foundations.contains($0) }
        let fixed = bindings.filter { foundations.contains($0) }
        return aliases + fixed
    }

    /// Describes a physical Shift expansion only when the active layout proves that the source
    /// glyph is produced by a different key/modifier combination. Returns nil when the source is
    /// already the resolved display or the layout cannot resolve it.
    static func inputDescription(for source: String) -> String? {
        let prefixMarker = "<prefix>"
        let usesPrefix = source.hasPrefix(prefixMarker)
        let sequenceSource = usesPrefix ? String(source.dropFirst(prefixMarker.count)) : source
        guard !sequenceSource.isEmpty,
              let sequence = try? KeySequenceParser.parse(sequenceSource),
              !sequence.tokens.isEmpty
        else {
            return nil
        }

        var changed = false
        let rendered = sequence.tokens.map { token -> String in
            let primary = render(token)
            guard let resolved = resolvedInputDisplay(for: token) else { return primary }
            if resolved != primary { changed = true }
            return resolved
        }.joined(separator: " → ")
        guard changed else { return nil }
        return usesPrefix ? "<pre> → \(rendered)" : rendered
    }

    private static func render(_ token: KeyToken) -> String {
        let modifiers = modifierSymbols(for: token.modifiers)
        switch token.symbol {
        case let .character(character):
            if token.modifiers.isEmpty {
                return character
            }
            // Canonical modifier chords keep their source identity while the base glyph stays
            // lowercase. This avoids making Shift+letter and Command+Shift+letter look like
            // different kinds of bindings.
            return modifiers + character.lowercased()
        case let .named(key):
            return modifiers + namedDisplay(for: key)
        case .deadKey, .imeComposition:
            return modifiers + token.description
        }
    }

    private static func modifierSymbols(for modifiers: KeyModifiers) -> String {
        var result = ""
        if modifiers.contains(.command) { result += "⌘" }
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        return result
    }

    private static func namedDisplay(for key: NamedKey) -> String {
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
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "PageUp"
        case .pageDown: return "PageDown"
        case .minus: return "-"
        case .equal: return "="
        case .plus: return "+"
        case .slash: return "/"
        case .lessThan: return "<"
        case .greaterThan: return ">"
        case .backtick: return "`"
        case let .function(number): return "F\(number)"
        }
    }

    private static func resolvedInputDisplay(for token: KeyToken) -> String? {
        let character: String
        switch token.symbol {
        case let .character(value):
            character = value
        case let .named(key):
            guard let value = printableCharacter(for: key) else { return nil }
            character = value
        case .deadKey, .imeComposition:
            return nil
        }

        let baseFlags: NSEvent.ModifierFlags = []
        let shiftedFlags = baseFlags.union(.shift)
        var shiftedCandidate: String?
        for keyCode in UInt16(0)...UInt16(127) {
            guard let unshifted = layoutCharactersProvider(keyCode, baseFlags),
                  let shifted = layoutCharactersProvider(keyCode, shiftedFlags)
            else { continue }
            if unshifted == character {
                return render(token)
            }
            if shifted == character, shifted != unshifted, shiftedCandidate == nil {
                shiftedCandidate = physicalDisplay(base: unshifted, modifiers: token.modifiers.union(.shift))
            }
        }
        return shiftedCandidate
    }

    private static func physicalDisplay(base: String, modifiers: KeyModifiers) -> String {
        let baseLabel: String
        switch base {
        case "\\": baseLabel = "backslash"
        case " ": baseLabel = "Space"
        default: baseLabel = base.lowercased()
        }
        return modifierSymbols(for: modifiers) + baseLabel
    }

    private static func printableCharacter(for key: NamedKey) -> String? {
        switch key {
        case .space: return " "
        case .backtick: return "`"
        case .lessThan: return "<"
        case .greaterThan: return ">"
        case .plus: return "+"
        case .minus: return "-"
        case .equal: return "="
        case .slash: return "/"
        default: return nil
        }
    }
}
