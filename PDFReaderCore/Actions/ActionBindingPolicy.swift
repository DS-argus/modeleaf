import Foundation

public struct EvaluatedActionBinding: Equatable, Sendable {
    public let action: ActionDescriptor
    public let sequence: KeySequence
    public let promptSafety: PromptSafetyDecision
    public let bindingOrder: Int

    public init(
        action: ActionDescriptor,
        sequence: KeySequence,
        promptSafety: PromptSafetyDecision,
        bindingOrder: Int
    ) {
        self.action = action
        self.sequence = sequence
        self.promptSafety = promptSafety
        self.bindingOrder = bindingOrder
    }
}

public enum ActionBindingDiagnostic: Equatable, Sendable {
    case missingAction(ActionID)
    case emptySequence(ActionID, bindingOrder: Int)
    case duplicateSequence(ActionID, KeySequence)
    case promptUnsafe(PromptSafetyFailure)
    case conflictingSequence(
        KeySequence,
        first: ActionID,
        second: ActionID,
        overlappingContexts: Set<InputContext>
    )
}

public struct ActionBindingPolicyReport: Sendable {
    public let evaluatedBindings: [ActionID: [EvaluatedActionBinding]]
    public let diagnostics: [ActionBindingDiagnostic]
    private let validated: ValidatedKeymap?

    fileprivate init(
        evaluatedBindings: [ActionID: [EvaluatedActionBinding]],
        diagnostics: [ActionBindingDiagnostic],
        validated: ValidatedKeymap?
    ) {
        self.evaluatedBindings = evaluatedBindings
        self.diagnostics = diagnostics
        self.validated = validated
    }

    public var isValid: Bool { diagnostics.isEmpty && validated != nil }

    public var validatedKeymap: ValidatedKeymap? { validated }
}

public struct ValidatedKeymap: Sendable {
    public let bindings: [ActionID: [KeySequence]]
    public let evaluatedBindings: [ActionID: [EvaluatedActionBinding]]
    private let actionOrder: [ActionID]
    private let descriptors: [ActionID: ActionDescriptor]

    fileprivate init(
        bindings: [ActionID: [KeySequence]],
        evaluatedBindings: [ActionID: [EvaluatedActionBinding]],
        registry: ActionRegistry
    ) {
        self.bindings = bindings
        self.evaluatedBindings = evaluatedBindings
        self.actionOrder = registry.actionIDs
        self.descriptors = Dictionary(uniqueKeysWithValues: registry.descriptors.map { ($0.id, $0) })
    }

    public func bindings(for actionID: ActionID) -> [KeySequence] {
        bindings[actionID] ?? []
    }

    public func isBound(_ actionID: ActionID) -> Bool {
        !(bindings[actionID] ?? []).isEmpty
    }

    public func action(forExact sequence: KeySequence, in context: InputContext) -> ActionID? {
        for actionID in actionOrder {
            guard descriptors[actionID]?.isActive(in: context) == true else { continue }
            if bindings[actionID]?.contains(sequence) == true { return actionID }
        }
        return nil
    }

    @discardableResult
    public func dispatchExact(
        _ sequence: KeySequence,
        in context: InputContext,
        eventIsRepeat: Bool = false,
        using dispatcher: any ActionDispatching
    ) -> Bool {
        guard let actionID = action(forExact: sequence, in: context),
              let descriptor = descriptors[actionID],
              ActionBindingPolicy.shouldDispatch(eventIsRepeat: eventIsRepeat, action: descriptor)
        else {
            return false
        }
        dispatcher.dispatch(actionID)
        return true
    }

    public func replacingBindings(
        for actionID: ActionID,
        with sequences: [KeySequence],
        registry: ActionRegistry = .v1
    ) -> ActionBindingPolicyReport {
        var replacement = bindings
        replacement[actionID] = sequences
        return ActionBindingPolicy.evaluateEffective(replacement, registry: registry)
    }
}

public enum ActionBindingPolicy {
    public static func evaluateEffective(
        _ bindings: [ActionID: [KeySequence]],
        registry: ActionRegistry = .v1,
        native: PromptNativeReservationV1 = .shared,
        system: SystemKeyReservationV1 = .shared
    ) -> ActionBindingPolicyReport {
        var evaluated: [ActionID: [EvaluatedActionBinding]] = [:]
        var diagnostics: [ActionBindingDiagnostic] = []

        for descriptor in registry.descriptors {
            guard let sequences = bindings[descriptor.id] else {
                diagnostics.append(.missingAction(descriptor.id))
                evaluated[descriptor.id] = []
                continue
            }

            var seen = Set<KeySequence>()
            var actionBindings: [EvaluatedActionBinding] = []
            for (order, sequence) in sequences.enumerated() {
                guard !sequence.tokens.isEmpty else {
                    diagnostics.append(.emptySequence(descriptor.id, bindingOrder: order))
                    continue
                }
                guard seen.insert(sequence).inserted else {
                    diagnostics.append(.duplicateSequence(descriptor.id, sequence))
                    continue
                }

                let safety = PromptSafeBindingPredicate.evaluate(
                    action: descriptor,
                    activeContexts: descriptor.activeContexts,
                    sequence: sequence,
                    native: native,
                    system: system
                )
                if case let .invalid(failure) = safety {
                    diagnostics.append(.promptUnsafe(failure))
                }
                actionBindings.append(
                    EvaluatedActionBinding(
                        action: descriptor,
                        sequence: sequence,
                        promptSafety: safety,
                        bindingOrder: order
                    )
                )
            }
            evaluated[descriptor.id] = actionBindings
        }

        let orderedBindings = registry.descriptors.flatMap { evaluated[$0.id] ?? [] }
        for firstIndex in orderedBindings.indices {
            let first = orderedBindings[firstIndex]
            guard first.promptSafety.isValid else { continue }
            for secondIndex in orderedBindings.indices where secondIndex > firstIndex {
                let second = orderedBindings[secondIndex]
                guard second.promptSafety.isValid,
                      first.action.id != second.action.id,
                      first.sequence == second.sequence
                else {
                    continue
                }
                let overlap = first.action.activeContexts.intersection(second.action.activeContexts)
                if !overlap.isEmpty {
                    diagnostics.append(
                        .conflictingSequence(
                            first.sequence,
                            first: first.action.id,
                            second: second.action.id,
                            overlappingContexts: overlap
                        )
                    )
                }
            }
        }

        let validated: ValidatedKeymap?
        if diagnostics.isEmpty {
            validated = ValidatedKeymap(bindings: bindings, evaluatedBindings: evaluated, registry: registry)
        } else {
            validated = nil
        }
        return ActionBindingPolicyReport(
            evaluatedBindings: evaluated,
            diagnostics: diagnostics,
            validated: validated
        )
    }

    public static func shouldDispatch(eventIsRepeat: Bool, action: ActionDescriptor) -> Bool {
        !eventIsRepeat || action.repeatPolicy == .allowed
    }
}
