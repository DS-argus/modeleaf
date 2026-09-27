import Foundation

public enum ShortcutRecordingTarget: Equatable, Sendable {
    case binding(prefix: KeyToken)
    case prefix
}

/// Records exactly what the user will press. A shared-prefix sequence keeps its
/// symbolic <prefix> relationship rather than freezing the current prefix key.
public struct ShortcutRecordingBuffer: Equatable, Sendable {
    public let target: ShortcutRecordingTarget
    public private(set) var tokens: [KeyToken] = []
    public private(set) var error: String?
    private var recordedPhysicalModifiers: [KeyModifiers] = []

    public init(target: ShortcutRecordingTarget) { self.target = target }

    public enum InputResult: Equatable, Sendable {
        case recorded
        case ignoredRepeat
        case rejected
        /// Empty source means remove the editable binding, not an empty sequence.
        case completed(String)
        case cancelled
        case invalid(String)
    }

    /// Receives one key token and its physical modifier state.
    ///
    /// The token is canonically normalized (for example, `Shift+u` is `U`), so
    /// physical modifiers are kept separately for direct two-key eligibility.
    public mutating func receive(
        _ token: KeyToken,
        physicalModifiers: KeyModifiers,
        isRepeat: Bool = false
    ) -> InputResult {
        guard !isRepeat else { return .ignoredRepeat }
        if token == KeyToken(symbol: .named(.escape)) { return .cancelled }
        if token == KeyToken(symbol: .named(.carriageReturn)) {
            if let error { return .invalid(error) }
            guard !tokens.isEmpty else {
                return target == .prefix ? .cancelled : .completed("")
            }
            if case let .binding(prefix) = target, tokens.first == prefix {
                guard tokens.count == 2 else {
                    return .invalid("Press one key after the common prefix.")
                }
                return .completed("<prefix>" + tokens[1].description)
            }
            return .completed(KeySequence(tokens: tokens).description)
        }
        guard error == nil else { return .rejected }
        guard !token.isCompositionInput else {
            error = "Composed text and dead keys cannot be recorded. Press Esc to return."
            return .rejected
        }

        let candidate = tokens + [token]
        let candidatePhysicalModifiers = recordedPhysicalModifiers + [physicalModifiers]
        guard acceptsPartial(candidate, physicalModifiers: candidatePhysicalModifiers) else {
            error = target == .prefix
                ? "The common prefix must be one key or modifier chord."
                : "Use one key or modifier chord, two plain keys (physically unmodified), or prefix followed by one key."
            return .rejected
        }
        tokens = candidate
        recordedPhysicalModifiers = candidatePhysicalModifiers
        return .recorded
    }

    private func acceptsPartial(
        _ candidate: [KeyToken],
        physicalModifiers: [KeyModifiers]
    ) -> Bool {
        switch target {
        case .prefix:
            return candidate.count == 1
        case let .binding(prefix):
            if candidate.first == prefix {
                return candidate.count == 1 || candidate.count == 2
            }
            return candidate.count == 1
                || (candidate.count == 2 && physicalModifiers.allSatisfy { $0.isEmpty })
        }
    }
}
