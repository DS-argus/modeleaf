import Foundation

public enum PromptSafetyViolation: Equatable, Sendable {
    case multipleTokens
    case promptTextInput(KeyToken)
    case modifierWithoutCommand(KeyToken)
    case promptNativeReservation(KeyToken)
    case systemReservation(KeyToken)
    case lifecycleKeyRequiresPromptAction(KeyToken)
    case compositionInput(KeyToken)
}

public struct PromptSafetyFailure: Equatable, Sendable {
    public let actionID: ActionID
    public let promptContexts: Set<InputContext>
    public let sequence: KeySequence
    public let violation: PromptSafetyViolation

    public init(
        actionID: ActionID,
        promptContexts: Set<InputContext>,
        sequence: KeySequence,
        violation: PromptSafetyViolation
    ) {
        self.actionID = actionID
        self.promptContexts = promptContexts
        self.sequence = sequence
        self.violation = violation
    }
}

public enum PromptSafetyDecision: Equatable, Sendable {
    case valid
    case invalid(PromptSafetyFailure)

    public var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    public var failure: PromptSafetyFailure? {
        if case let .invalid(failure) = self { return failure }
        return nil
    }
}

public enum PromptSafeBindingPredicate {
    public static func evaluate(
        action: ActionDescriptor,
        activeContexts: Set<InputContext>,
        sequence: KeySequence,
        native: PromptNativeReservationV1 = .shared,
        system: SystemKeyReservationV1 = .shared
    ) -> PromptSafetyDecision {
        if sequence.tokens.isEmpty { return .valid }

        let relevantPromptContexts = Set(
            activeContexts.filter { context in
                InputContext.promptContexts.contains(context) && action.isActive(in: context)
            }
        )
        guard !relevantPromptContexts.isEmpty else { return .valid }
        guard sequence.tokens.count == 1 else {
            return invalid(
                action: action,
                contexts: relevantPromptContexts,
                sequence: sequence,
                violation: .multipleTokens
            )
        }

        let token = sequence.tokens[0]
        if token == lifecycleToken(.carriageReturn) || token == lifecycleToken(.escape) {
            return action.isPromptLifecycle
                ? .valid
                : invalid(
                    action: action,
                    contexts: relevantPromptContexts,
                    sequence: sequence,
                    violation: .lifecycleKeyRequiresPromptAction(token)
                )
        }
        if native.contains(token) {
            return invalid(
                action: action,
                contexts: relevantPromptContexts,
                sequence: sequence,
                violation: .promptNativeReservation(token)
            )
        }
        if system.contains(token) {
            return invalid(
                action: action,
                contexts: relevantPromptContexts,
                sequence: sequence,
                violation: .systemReservation(token)
            )
        }
        if token.isCompositionInput {
            return invalid(
                action: action,
                contexts: relevantPromptContexts,
                sequence: sequence,
                violation: .compositionInput(token)
            )
        }
        if token.isPrintable && !token.hasCommand {
            return invalid(
                action: action,
                contexts: relevantPromptContexts,
                sequence: sequence,
                violation: .promptTextInput(token)
            )
        }
        if !token.hasCommand && !token.modifiers.isEmpty {
            return invalid(
                action: action,
                contexts: relevantPromptContexts,
                sequence: sequence,
                violation: .modifierWithoutCommand(token)
            )
        }
        return .valid
    }

    private static func lifecycleToken(_ key: NamedKey) -> KeyToken {
        KeyToken(symbol: .named(key))
    }

    private static func invalid(
        action: ActionDescriptor,
        contexts: Set<InputContext>,
        sequence: KeySequence,
        violation: PromptSafetyViolation
    ) -> PromptSafetyDecision {
        .invalid(
            PromptSafetyFailure(
                actionID: action.id,
                promptContexts: contexts,
                sequence: sequence,
                violation: violation
            )
        )
    }
}
