import AppKit
import Foundation

public enum ProbeInputContext: String, CaseIterable, Hashable, Sendable {
    case navigation
    case pagePrompt
    case searchPrompt
    case searchResults
}

public enum ProbeActionScope: Equatable, Sendable {
    case global
    case contexts(Set<ProbeInputContext>)
}

public struct ProbeActionDescriptor: Equatable, Sendable {
    public let id: String
    public let scope: ProbeActionScope
    public let promptLifecycle: Bool

    public init(id: String, scope: ProbeActionScope, promptLifecycle: Bool = false) {
        self.id = id
        self.scope = scope
        self.promptLifecycle = promptLifecycle
    }

    public var isPromptActive: Bool {
        switch scope {
        case .global:
            true
        case let .contexts(contexts):
            contexts.contains(.pagePrompt) || contexts.contains(.searchPrompt)
        }
    }
}

public struct ProbeKeyToken: Hashable, Sendable, CustomStringConvertible {
    public let normalized: String

    public init(_ normalized: String) {
        self.normalized = normalized
    }

    public var description: String { normalized }

    var isPrintable: Bool {
        guard !normalized.hasPrefix("<") else { return false }
        return normalized.unicodeScalars.count == 1
    }

    var hasCommand: Bool {
        normalized.hasPrefix("<") && modifierLetters.contains("D")
    }

    var hasControl: Bool {
        normalized.hasPrefix("<") && modifierLetters.contains("C")
    }

    var hasOption: Bool {
        normalized.hasPrefix("<") && modifierLetters.contains("A")
    }

    var hasShift: Bool {
        normalized.hasPrefix("<") && modifierLetters.contains("S")
    }

    var baseName: String {
        guard normalized.hasPrefix("<"), normalized.hasSuffix(">") else { return normalized }
        let body = String(normalized.dropFirst().dropLast())
        return body.split(separator: "-").last.map(String.init) ?? body
    }

    private var modifierLetters: Set<Character> {
        guard normalized.hasPrefix("<"), normalized.hasSuffix(">") else { return [] }
        let body = String(normalized.dropFirst().dropLast())
        let parts = body.split(separator: "-").dropLast()
        return Set(parts.flatMap { $0 })
    }
}

public struct ProbeKeySequence: Equatable, Sendable, CustomStringConvertible {
    public let tokens: [ProbeKeyToken]

    public init(tokens: [ProbeKeyToken]) {
        self.tokens = tokens
    }

    public init(_ source: String) {
        var result: [ProbeKeyToken] = []
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "<", let close = source[index...].firstIndex(of: ">") {
                result.append(ProbeKeyToken(String(source[index...close])))
                index = source.index(after: close)
            } else {
                result.append(ProbeKeyToken(String(source[index])))
                index = source.index(after: index)
            }
        }
        self.tokens = result
    }

    public var description: String { tokens.map(\.normalized).joined() }
}

public enum ProbeBindingDecision: Equatable, Sendable {
    case valid
    case invalid(String)

    public var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}

public enum PromptNativeReservationV1 {
    public static let tokens: Set<String> = {
        var values: Set<String> = [
            "<BS>", "<Del>", "<Tab>", "<S-Tab>",
            "<Left>", "<Right>", "<Up>", "<Down>",
            "<Home>", "<End>", "<PageUp>", "<PageDown>",
            "<D-a>", "<D-c>", "<D-x>", "<D-v>", "<D-z>", "<D-S-z>",
        ]
        let navigationKeys = ["Left", "Right", "Up", "Down", "Home", "End", "PageUp", "PageDown", "BS", "Del"]
        let modifierPrefixes = ["S", "A", "A-S", "D", "D-S", "C", "C-S"]
        for key in navigationKeys {
            for modifiers in modifierPrefixes {
                values.insert("<\(modifiers)-\(key)>")
            }
        }
        return values
    }()
}

public enum SystemKeyReservationV1 {
    public static let tokens: Set<String> = [
        "<D-h>", "<D-A-h>", "<D-m>", "<D-`>", "<D-S-`>",
        "<D-Tab>", "<D-S-Tab>", "<D-Space>", "<D-A-Esc>", "<D-A-d>",
        "<D-S-3>", "<D-S-4>", "<D-S-5>", "<D-C-q>", "<D-C-f>", "<D-C-Space>",
        "<D-S-q>", "<D-A-S-q>",
    ]
}

public enum ProbePromptSafeBindingPredicate {
    public static func evaluate(
        action: ProbeActionDescriptor,
        sequence: ProbeKeySequence
    ) -> ProbeBindingDecision {
        if sequence.tokens.isEmpty { return .valid }
        guard action.isPromptActive else { return .valid }
        guard sequence.tokens.count == 1 else {
            return .invalid("prompt-active sequences must contain exactly one token")
        }

        let token = sequence.tokens[0]
        if token.normalized == "<CR>" || token.normalized == "<Esc>" {
            return action.promptLifecycle
                ? .valid
                : .invalid("only prompt lifecycle actions may claim CR or Esc")
        }
        if PromptNativeReservationV1.tokens.contains(token.normalized) {
            return .invalid("reserved for native text editing")
        }
        if SystemKeyReservationV1.tokens.contains(token.normalized) {
            return .invalid("reserved for macOS")
        }
        if token.isPrintable {
            return .invalid("printable prompt text must remain native")
        }
        if !token.hasCommand && (token.hasControl || token.hasOption || token.hasShift) {
            return .invalid("non-Command modifier chord may produce text or native editing")
        }
        return .valid
    }
}

@MainActor
public enum ProbeMenuBuilder {
    public static func menuItem(
        action: ProbeActionDescriptor,
        binding: ProbeKeySequence,
        globallyUnique: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: action.id, action: #selector(ProbeMenuTarget.invoke(_:)), keyEquivalent: "")
        item.target = ProbeMenuTarget.shared

        guard action.scope == .global,
              globallyUnique,
              ProbePromptSafeBindingPredicate.evaluate(action: action, sequence: binding).isValid,
              binding.tokens.count == 1,
              let representation = appKitRepresentation(of: binding.tokens[0])
        else {
            return item
        }

        item.keyEquivalent = representation.key
        item.keyEquivalentModifierMask = representation.modifiers
        return item
    }

    private static func appKitRepresentation(of token: ProbeKeyToken) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard token.normalized.hasPrefix("<") else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        if token.hasCommand { modifiers.insert(.command) }
        if token.hasControl { modifiers.insert(.control) }
        if token.hasOption { modifiers.insert(.option) }
        if token.hasShift { modifiers.insert(.shift) }

        let key: String
        switch token.baseName.lowercased() {
        case "f12": key = String(UnicodeScalar(NSF12FunctionKey)!)
        case "cr": key = "\r"
        case "esc": key = String(UnicodeScalar(0x1B)!)
        default:
            guard token.baseName.count == 1 else { return nil }
            key = token.baseName.lowercased()
        }
        return (key, modifiers)
    }
}

@MainActor
private final class ProbeMenuTarget: NSObject {
    static let shared = ProbeMenuTarget()

    @objc func invoke(_ sender: Any?) {}
}

@MainActor
public enum InputAndMenuProbe {
    public static func run() -> ProbeSection {
        let globalOpen = ProbeActionDescriptor(id: "document.open", scope: .global)
        let globalQuit = ProbeActionDescriptor(id: "app.quit", scope: .global)
        let contextualNext = ProbeActionDescriptor(
            id: "page.next",
            scope: .contexts([.navigation, .searchResults])
        )
        let promptCommit = ProbeActionDescriptor(
            id: "prompt.commit",
            scope: .contexts([.pagePrompt, .searchPrompt]),
            promptLifecycle: true
        )

        let first = ProbeMenuBuilder.menuItem(
            action: globalOpen,
            binding: ProbeKeySequence("<D-o>"),
            globallyUnique: true
        )
        let remapped = ProbeMenuBuilder.menuItem(
            action: globalOpen,
            binding: ProbeKeySequence("<D-F12>"),
            globallyUnique: true
        )
        let contextual = ProbeMenuBuilder.menuItem(
            action: contextualNext,
            binding: ProbeKeySequence("n"),
            globallyUnique: true
        )
        let shadowing = ProbeMenuBuilder.menuItem(
            action: globalOpen,
            binding: ProbeKeySequence("o"),
            globallyUnique: true
        )
        let ambiguous = ProbeMenuBuilder.menuItem(
            action: globalOpen,
            binding: ProbeKeySequence("<D-o>"),
            globallyUnique: false
        )
        let multi = ProbeMenuBuilder.menuItem(
            action: globalOpen,
            binding: ProbeKeySequence("go"),
            globallyUnique: true
        )
        let unbound = ProbeMenuBuilder.menuItem(
            action: globalOpen,
            binding: ProbeKeySequence(tokens: []),
            globallyUnique: true
        )

        let unsafeSequences = ["o", "go", "<C-o>", "<A-o>", "<S-o>"]
        let unsafeRejected = unsafeSequences.allSatisfy {
            !ProbePromptSafeBindingPredicate.evaluate(action: globalOpen, sequence: ProbeKeySequence($0)).isValid
        }
        let nativeRejected = PromptNativeReservationV1.tokens.allSatisfy {
            !ProbePromptSafeBindingPredicate.evaluate(action: globalOpen, sequence: ProbeKeySequence($0)).isValid
        }
        let systemRejected = SystemKeyReservationV1.tokens.allSatisfy {
            !ProbePromptSafeBindingPredicate.evaluate(action: globalQuit, sequence: ProbeKeySequence($0)).isValid
        }

        return ProbeSection(
            id: "input-menu",
            title: "Prompt safety and config-derived menus",
            checks: [
                checked("global-equivalent", first.keyEquivalent == "o" && first.keyEquivalentModifierMask.contains(.command), detail: "<D-o> generated a Command-O menu equivalent"),
                checked("remap", !remapped.keyEquivalent.isEmpty && remapped.keyEquivalent != first.keyEquivalent, detail: "remapping replaces the generated equivalent"),
                checked("contextual-without-equivalent", contextual.keyEquivalent.isEmpty && contextual.action != nil, detail: "contextual actions stay clickable but have no application-wide equivalent"),
                checked("unsafe-equivalents-omitted", [shadowing, ambiguous, multi, unbound].allSatisfy { $0.keyEquivalent.isEmpty && $0.action != nil }, detail: "shadowing, ambiguous, multi-key, and unbound cases retain clickable items without equivalents"),
                checked("unsafe-global-rejected", unsafeRejected, detail: "printable, multi-token, Control, Option, and Shift-only prompt-active globals are rejected"),
                checked("native-reservations", nativeRejected, detail: "every PromptNativeReservationV1 token is rejected for globals"),
                checked("system-reservations", systemRejected, detail: "every SystemKeyReservationV1 token is rejected for globals"),
                checked("safe-command-fixtures", ["<D-o>", "<D-q>", "<D-F12>"].allSatisfy { ProbePromptSafeBindingPredicate.evaluate(action: globalOpen, sequence: ProbeKeySequence($0)).isValid }, detail: "safe Command fixtures remain dispatchable during prompts"),
                checked("prompt-lifecycle", ProbePromptSafeBindingPredicate.evaluate(action: promptCommit, sequence: ProbeKeySequence("<CR>")).isValid, detail: "CR remains remappable for prompt lifecycle actions only"),
            ]
        )
    }
}
