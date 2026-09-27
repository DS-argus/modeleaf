import Foundation

/// A contextual binding that remains available independently of an action's editable aliases.
public struct FoundationBinding: Equatable, Sendable {
    public let action: ActionID
    public let sequence: KeySequence
    public let contexts: Set<InputContext>
    public let reason: String

    public init(
        action: ActionID,
        sequence: KeySequence,
        contexts: Set<InputContext>,
        reason: String
    ) {
        self.action = action
        self.sequence = sequence
        self.contexts = contexts
        self.reason = reason
    }

}

public enum FoundationalBindings {
    /// All contextual foundations owned by the v1 action registry.
    public static let all: [FoundationBinding] = [
        FoundationBinding(
            action: .paletteOpen,
            sequence: sequence("<D-S-p>"),
            contexts: [.navigation, .searchResults],
            reason: "Command palette access"
        ),
        FoundationBinding(
            action: .scrollLeft,
            sequence: sequence("<Left>"),
            contexts: [.navigation, .searchResults],
            reason: "PDF left-arrow navigation"
        ),
        FoundationBinding(
            action: .scrollDown,
            sequence: sequence("<Down>"),
            contexts: [.navigation, .searchResults],
            reason: "PDF down-arrow navigation"
        ),
        FoundationBinding(
            action: .scrollUp,
            sequence: sequence("<Up>"),
            contexts: [.navigation, .searchResults],
            reason: "PDF up-arrow navigation"
        ),
        FoundationBinding(
            action: .scrollRight,
            sequence: sequence("<Right>"),
            contexts: [.navigation, .searchResults],
            reason: "PDF right-arrow navigation"
        ),
        FoundationBinding(
            action: .searchCancel,
            sequence: sequence("<Esc>"),
            contexts: [.searchResults],
            reason: "Search cancellation"
        ),
    ]

    /// Returns the immutable foundation sequences owned by an action.
    public static func sequences(for action: ActionID) -> [KeySequence] {
        all.filter { $0.action == action }.map(\.sequence)
    }


    static func foundation(
        for action: ActionID,
        sequence: KeySequence
    ) -> FoundationBinding? {
        all.first { $0.action == action && $0.sequence == sequence }
    }

    static func compose(
        _ aliases: [ActionID: [KeySequence]],
        registry: ActionRegistry
    ) -> [ActionID: [KeySequence]] {
        var effective = aliases
        for foundation in all where registry.descriptor(for: foundation.action) != nil {
            guard aliases[foundation.action] != nil else { continue }
            let source = aliases[foundation.action, default: []]
            let ownOccurrences = source.filter { $0 == foundation.sequence }.count
            if ownOccurrences == 1 {
                // A source occurrence acknowledges the injected foundation; it is not
                // an additional dispatch entry. Keep every other source alias verbatim.
                effective[foundation.action] = [foundation.sequence] + source.filter { $0 != foundation.sequence }
            } else if ownOccurrences == 0 {
                // A missing source occurrence receives the foundation. Multiple source
                // occurrences stay visible so ordinary duplicate validation rejects them.
                effective[foundation.action] = [foundation.sequence] + source
            }
        }
        return effective
    }

    static func contexts(
        for action: ActionID,
        sequence: KeySequence
    ) -> Set<InputContext>? {
        foundation(for: action, sequence: sequence)?.contexts
    }

    private static func sequence(_ source: String) -> KeySequence {
        do {
            return try KeySequenceParser.parse(source)
        } catch {
            preconditionFailure("invalid foundational binding \(source): \(error)")
        }
    }
}
