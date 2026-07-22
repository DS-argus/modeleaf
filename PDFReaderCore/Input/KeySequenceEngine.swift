import Foundation

public struct PrefixEpoch: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: PrefixEpoch, rhs: PrefixEpoch) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct PendingKeySequence: Equatable, Sendable {
    public let sequence: KeySequence
    public let epoch: PrefixEpoch
    public let exactAction: ActionID?
    public let hasLongerMatches: Bool
    public let timeoutMilliseconds: Int

    public init(
        sequence: KeySequence,
        epoch: PrefixEpoch,
        exactAction: ActionID?,
        hasLongerMatches: Bool,
        timeoutMilliseconds: Int
    ) {
        self.sequence = sequence
        self.epoch = epoch
        self.exactAction = exactAction
        self.hasLongerMatches = hasLongerMatches
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}

public struct SemanticKeyReplay: Equatable, Sendable {
    public let token: KeyToken
    public let tokenClass: ReplayTokenClass
    public let targetContext: InputContext

    public init(token: KeyToken, tokenClass: ReplayTokenClass, targetContext: InputContext) {
        self.token = token
        self.tokenClass = tokenClass
        self.targetContext = targetContext
    }
}

public struct KeyActionDispatch: Equatable, Sendable {
    public let actionID: ActionID
    public let transitionedContext: InputContext?
    public let semanticReplay: SemanticKeyReplay?

    public init(
        actionID: ActionID,
        transitionedContext: InputContext? = nil,
        semanticReplay: SemanticKeyReplay? = nil
    ) {
        self.actionID = actionID
        self.transitionedContext = transitionedContext
        self.semanticReplay = semanticReplay
    }
}

public enum KeyInputInvalidationReason: String, Equatable, Sendable {
    case contextChanged
    case configurationChanged
    case focusLost
    case sessionChanged
    case sessionClosed
    case promptCommitted
    case promptCancelled
    case explicitCancel
}

public enum KeyInputIgnoreReason: Equatable, Sendable {
    case noBinding
    case invalidSequence
    case rejectedPagePromptText
    case repeatSuppressed(ActionID)
    case repeatCannotBeginPrefix
    case repeatDuringPrefix
    case timeoutWithoutExactAction
    case staleTimeout(PrefixEpoch)
    case invalidated(KeyInputInvalidationReason)
}

public enum KeyInputOutcome: Equatable, Sendable {
    case native(KeyToken)
    case pending(PendingKeySequence)
    case dispatch(KeyActionDispatch)
    case ignored(KeyInputIgnoreReason)
}

public enum PromptInputOwnership: Equatable, Sendable {
    case actionEngine
    case native
    case rejected
}

public enum PromptInputOwnershipPolicy {
    public static func classify(
        _ token: KeyToken,
        in context: InputContext,
        native: PromptNativeReservationV1 = .shared,
        system: SystemKeyReservationV1 = .shared
    ) -> PromptInputOwnership {
        guard InputContext.promptContexts.contains(context) else { return .actionEngine }
        if token.isCompositionInput || native.contains(token) || system.contains(token) {
            return .native
        }
        guard token.isPrintable,
              !token.modifiers.contains(.command),
              !token.modifiers.contains(.control)
        else {
            return .actionEngine
        }
        switch context {
        case .searchPrompt:
            return .native
        case .pagePrompt:
            return token.asciiDecimalDigit == nil ? .rejected : .native
        case .navigation, .searchResults:
            return .actionEngine
        }
    }
}

public struct KeySequenceEngine: Sendable {
    private var trie: KeySequenceTrie
    private var epochCounter = PrefixEpoch(rawValue: 0)

    public private(set) var context: InputContext
    public private(set) var pending: PendingKeySequence?
    public private(set) var prefixTimeoutMilliseconds: Int

    public init(
        trie: KeySequenceTrie,
        context: InputContext,
        prefixTimeoutMilliseconds: Int
    ) {
        precondition(
            ConfigBounds.prefixTimeoutMilliseconds.contains(prefixTimeoutMilliseconds),
            "prefix timeout is outside the supported bounds"
        )
        self.trie = trie
        self.context = context
        self.prefixTimeoutMilliseconds = prefixTimeoutMilliseconds
    }

    public mutating func handle(
        _ token: KeyToken,
        eventIsRepeat: Bool = false
    ) -> KeyInputOutcome {
        switch PromptInputOwnershipPolicy.classify(token, in: context) {
        case .native:
            return .native(token)
        case .rejected:
            return .ignored(.rejectedPagePromptText)
        case .actionEngine:
            break
        }

        if eventIsRepeat, pending != nil {
            return .ignored(.repeatDuringPrefix)
        }

        let previous = pending
        let tokens = (previous?.sequence.tokens ?? []) + [token]
        let candidate = KeySequence(tokens: tokens)
        switch trie.match(candidate, in: context) {
        case .none:
            pending = nil
            guard let exactAction = previous?.exactAction,
                  let descriptor = trie.descriptor(for: exactAction),
                  case let .transitionAndReplay(target, tokenClass) = descriptor.prefixFallbackPolicy,
                  SemanticReplayPolicy.accepts(token, as: tokenClass, in: target)
            else {
                return .ignored(previous == nil ? .noBinding : .invalidSequence)
            }
            return dispatch(
                descriptor,
                replay: SemanticKeyReplay(token: token, tokenClass: tokenClass, targetContext: target)
            )

        case .prefix:
            guard !eventIsRepeat else { return .ignored(.repeatCannotBeginPrefix) }
            return beginPending(candidate, exactAction: nil)

        case let .exact(actionID):
            pending = nil
            return dispatch(actionID, eventIsRepeat: eventIsRepeat)

        case let .exactAndPrefix(actionID):
            guard !eventIsRepeat else { return .ignored(.repeatCannotBeginPrefix) }
            return beginPending(candidate, exactAction: actionID)
        }
    }

    public mutating func timeout(epoch: PrefixEpoch) -> KeyInputOutcome {
        guard let current = pending, current.epoch == epoch else {
            return .ignored(.staleTimeout(epoch))
        }
        pending = nil
        guard let actionID = current.exactAction else {
            return .ignored(.timeoutWithoutExactAction)
        }
        return dispatch(actionID, eventIsRepeat: false)
    }

    public mutating func changeContext(to context: InputContext) -> KeyInputOutcome {
        self.context = context
        return invalidate(.contextChanged)
    }

    public mutating func activate(
        trie: KeySequenceTrie,
        prefixTimeoutMilliseconds: Int
    ) -> KeyInputOutcome {
        precondition(
            ConfigBounds.prefixTimeoutMilliseconds.contains(prefixTimeoutMilliseconds),
            "prefix timeout is outside the supported bounds"
        )
        self.trie = trie
        self.prefixTimeoutMilliseconds = prefixTimeoutMilliseconds
        return invalidate(.configurationChanged)
    }

    public mutating func invalidate(_ reason: KeyInputInvalidationReason) -> KeyInputOutcome {
        advanceEpoch()
        pending = nil
        return .ignored(.invalidated(reason))
    }

    private mutating func beginPending(
        _ sequence: KeySequence,
        exactAction: ActionID?
    ) -> KeyInputOutcome {
        advanceEpoch()
        let value = PendingKeySequence(
            sequence: sequence,
            epoch: epochCounter,
            exactAction: exactAction,
            hasLongerMatches: true,
            timeoutMilliseconds: prefixTimeoutMilliseconds
        )
        pending = value
        return .pending(value)
    }

    private mutating func dispatch(
        _ actionID: ActionID,
        eventIsRepeat: Bool
    ) -> KeyInputOutcome {
        guard let descriptor = trie.descriptor(for: actionID) else {
            return .ignored(.noBinding)
        }
        guard ActionBindingPolicy.shouldDispatch(eventIsRepeat: eventIsRepeat, action: descriptor) else {
            return .ignored(.repeatSuppressed(actionID))
        }
        return dispatch(descriptor, replay: nil)
    }

    private mutating func dispatch(
        _ descriptor: ActionDescriptor,
        replay: SemanticKeyReplay?
    ) -> KeyInputOutcome {
        let transition: InputContext?
        if case let .transitionAndReplay(target, _) = descriptor.prefixFallbackPolicy {
            context = target
            transition = target
        } else {
            transition = nil
        }
        return .dispatch(
            KeyActionDispatch(
                actionID: descriptor.id,
                transitionedContext: transition,
                semanticReplay: replay
            )
        )
    }

    private mutating func advanceEpoch() {
        precondition(epochCounter.rawValue < UInt64.max, "prefix epoch exhausted")
        epochCounter = PrefixEpoch(rawValue: epochCounter.rawValue + 1)
    }
}

public extension ReplayTokenClass {
    func accepts(_ token: KeyToken) -> Bool {
        switch self {
        case .decimalDigit:
            token.asciiDecimalDigit != nil
        }
    }
}

public extension KeyToken {
    var asciiDecimalDigit: Character? {
        guard modifiers.isEmpty,
              case let .character(value) = symbol,
              value.unicodeScalars.count == 1,
              let scalar = value.unicodeScalars.first,
              (48...57).contains(scalar.value)
        else {
            return nil
        }
        return Character(value)
    }
}
