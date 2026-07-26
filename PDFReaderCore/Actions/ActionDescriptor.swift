import Foundation

public enum ActionScope: Equatable, Sendable {
    case global
    case contexts(Set<InputContext>)

    public var activeContexts: Set<InputContext> {
        switch self {
        case .global:
            Set(InputContext.allCases)
        case let .contexts(contexts):
            contexts
        }
    }

    public func isActive(in context: InputContext) -> Bool {
        switch self {
        case .global:
            true
        case let .contexts(contexts):
            contexts.contains(context)
        }
    }
}

public enum ActionRepeatPolicy: String, Codable, Equatable, Sendable {
    case allowed
    case suppressed
}

public enum ReplayTokenClass: String, Codable, Equatable, Sendable {
    case decimalDigit
}

public enum PrefixFallbackPolicy: Equatable, Sendable {
    case none
    case transitionAndReplay(to: InputContext, acceptedToken: ReplayTokenClass)
}

public struct ActionDescriptor: Equatable, Sendable {
    public let id: ActionID
    public let title: String
    public let scope: ActionScope
    public let repeatPolicy: ActionRepeatPolicy
    public let prefixFallbackPolicy: PrefixFallbackPolicy
    public let isPromptLifecycle: Bool
    public let isFixedBinding: Bool

    public init(
        id: ActionID,
        title: String,
        scope: ActionScope,
        repeatPolicy: ActionRepeatPolicy = .suppressed,
        prefixFallbackPolicy: PrefixFallbackPolicy = .none,
        isPromptLifecycle: Bool = false,
        isFixedBinding: Bool = false
    ) {
        self.id = id
        self.title = title
        self.scope = scope
        self.repeatPolicy = repeatPolicy
        self.prefixFallbackPolicy = prefixFallbackPolicy
        self.isPromptLifecycle = isPromptLifecycle
        self.isFixedBinding = isFixedBinding
    }

    public var activeContexts: Set<InputContext> { scope.activeContexts }

    public var isPromptActive: Bool {
        !activeContexts.isDisjoint(with: InputContext.promptContexts)
    }

    public func isActive(in context: InputContext) -> Bool {
        scope.isActive(in: context)
    }
}
