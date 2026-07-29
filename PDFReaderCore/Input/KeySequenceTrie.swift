import Foundation

public enum ExactPrefixRejectionReason: String, Equatable, Sendable {
    case shorterActionIsNotReplaySafe
    case lifecycleOrDestructiveAction
    case replayTargetCannotConsumeTokenClass
}

public enum KeySequenceTrieDiagnostic: Equatable, Sendable {
    case invalidExactPrefix(
        shorterAction: ActionID,
        shorterSequence: KeySequence,
        longerAction: ActionID,
        longerSequence: KeySequence,
        overlappingContexts: Set<InputContext>,
        reason: ExactPrefixRejectionReason
    )
}

public enum KeySequenceTrieMatch: Equatable, Sendable {
    case none
    case prefix
    case exact(ActionID)
    case exactAndPrefix(ActionID)
}

public struct KeySequenceTrieBuildReport: Sendable {
    public let diagnostics: [KeySequenceTrieDiagnostic]
    private let builtTrie: KeySequenceTrie?

    fileprivate init(diagnostics: [KeySequenceTrieDiagnostic], trie: KeySequenceTrie?) {
        self.diagnostics = diagnostics
        self.builtTrie = trie
    }

    public var isValid: Bool { diagnostics.isEmpty && builtTrie != nil }

    public var trie: KeySequenceTrie? { builtTrie }
}

public struct KeySequenceTrie: Sendable {
    private let roots: [InputContext: TrieNode]
    private let descriptors: [ActionID: ActionDescriptor]

    private init(
        roots: [InputContext: TrieNode],
        descriptors: [ActionID: ActionDescriptor]
    ) {
        self.roots = roots
        self.descriptors = descriptors
    }

    public static func build(
        from keymap: ValidatedKeymap,
        registry: ActionRegistry = .v1
    ) -> KeySequenceTrieBuildReport {
        let entries = registry.descriptors.flatMap { descriptor in
            keymap.bindings(for: descriptor.id).map { sequence in
                BindingEntry(descriptor: descriptor, sequence: sequence)
            }
        }
        let diagnostics = exactPrefixDiagnostics(entries)
        guard diagnostics.isEmpty else {
            return KeySequenceTrieBuildReport(diagnostics: diagnostics, trie: nil)
        }

        let roots: [InputContext: MutableTrieNode] = Dictionary(
            uniqueKeysWithValues: InputContext.allCases.map { ($0, MutableTrieNode()) }
        )
        for entry in entries {
            for context in entry.descriptor.activeContexts {
                roots[context]?.insert(entry.sequence.tokens[...], actionID: entry.descriptor.id)
            }
        }
        let frozenRoots = roots.mapValues(TrieNode.init)
        return KeySequenceTrieBuildReport(
            diagnostics: [],
            trie: KeySequenceTrie(
                roots: frozenRoots,
                descriptors: Dictionary(
                    uniqueKeysWithValues: registry.descriptors.map { ($0.id, $0) }
                )
            )
        )
    }

    public func match(_ sequence: KeySequence, in context: InputContext) -> KeySequenceTrieMatch {
        guard !sequence.tokens.isEmpty, var node = roots[context] else { return .none }
        for token in sequence.tokens {
            guard let child = node.children[token] else { return .none }
            node = child
        }
        switch (node.actionID, node.children.isEmpty) {
        case (nil, true):
            return .none
        case (nil, false):
            return .prefix
        case let (actionID?, true):
            return .exact(actionID)
        case let (actionID?, false):
            return .exactAndPrefix(actionID)
        }
    }

    func descriptor(for actionID: ActionID) -> ActionDescriptor? {
        descriptors[actionID]
    }

    private static func exactPrefixDiagnostics(
        _ entries: [BindingEntry]
    ) -> [KeySequenceTrieDiagnostic] {
        var diagnostics: [KeySequenceTrieDiagnostic] = []
        for firstIndex in entries.indices {
            for secondIndex in entries.indices where secondIndex > firstIndex {
                let first = entries[firstIndex]
                let second = entries[secondIndex]
                guard first.sequence.tokens.count != second.sequence.tokens.count else { continue }

                let shorter: BindingEntry
                let longer: BindingEntry
                if first.sequence.tokens.count < second.sequence.tokens.count {
                    (shorter, longer) = (first, second)
                } else {
                    (shorter, longer) = (second, first)
                }
                guard longer.sequence.tokens.starts(with: shorter.sequence.tokens) else { continue }

                let overlap = shorter.descriptor.activeContexts.intersection(longer.descriptor.activeContexts)
                guard !overlap.isEmpty,
                      let rejection = replayRejectionReason(for: shorter.descriptor)
                else {
                    continue
                }
                diagnostics.append(
                    .invalidExactPrefix(
                        shorterAction: shorter.descriptor.id,
                        shorterSequence: shorter.sequence,
                        longerAction: longer.descriptor.id,
                        longerSequence: longer.sequence,
                        overlappingContexts: overlap,
                        reason: rejection
                    )
                )
            }
        }
        return diagnostics
    }

    private static func replayRejectionReason(
        for descriptor: ActionDescriptor
    ) -> ExactPrefixRejectionReason? {
        guard case let .transitionAndReplay(target, tokenClass) = descriptor.prefixFallbackPolicy else {
            return .shorterActionIsNotReplaySafe
        }
        if ExactPrefixSafetyPolicy.isForbidden(descriptor) {
            return .lifecycleOrDestructiveAction
        }
        if !SemanticReplayPolicy.supports(tokenClass, in: target) {
            return .replayTargetCannotConsumeTokenClass
        }
        return nil
    }
}

public enum SemanticReplayPolicy {
    public static func supports(_ tokenClass: ReplayTokenClass, in context: InputContext) -> Bool {
        switch (tokenClass, context) {
        case (.decimalDigit, .pagePrompt):
            true
        default:
            false
        }
    }

    public static func accepts(
        _ token: KeyToken,
        as tokenClass: ReplayTokenClass,
        in context: InputContext
    ) -> Bool {
        supports(tokenClass, in: context) && tokenClass.accepts(token)
    }
}

private enum ExactPrefixSafetyPolicy {
    static func isForbidden(_ descriptor: ActionDescriptor) -> Bool {
        switch descriptor.id {
        case .documentOpen, .documentClose, .appQuit, .appNew,
             .promptCommit, .promptCancel,
             .searchCancel, .configReload, .configWriteDefault, .configResetDefault:
            true
        case .tabNext, .tabPrevious,
             .tabSelect1, .tabSelect2, .tabSelect3,
             .tabSelect4, .tabSelect5, .tabSelect6,
             .tabSelect7, .tabSelect8, .tabSelect9,
             .scrollLeft, .scrollDown, .scrollUp, .scrollRight,
             .scrollLargeDown, .scrollLargeUp,
             .pageNext, .pagePrevious, .pageFirst, .pageLast, .pagePrompt,
             .paletteOpen, .helpShow, .searchPrompt, .searchNext, .searchPrevious,
             .viewZoomIn, .viewZoomOut, .viewZoomReset, .viewFitWidth, .viewFitPage, .linkHint,
             .paneSplitRight, .paneSplitDown, .paneFocusLeft, .paneFocusDown,
             .paneFocusUp, .paneFocusRight, .paneUnsplit, .themePicker:
            false
        }
    }
}

private struct BindingEntry {
    let descriptor: ActionDescriptor
    let sequence: KeySequence
}

private final class MutableTrieNode {
    var actionID: ActionID?
    var children: [KeyToken: MutableTrieNode] = [:]

    func insert(_ tokens: ArraySlice<KeyToken>, actionID: ActionID) {
        guard let token = tokens.first else {
            precondition(self.actionID == nil, "validated keymap produced a duplicate exact binding")
            self.actionID = actionID
            return
        }
        let child = children[token] ?? MutableTrieNode()
        children[token] = child
        child.insert(tokens.dropFirst(), actionID: actionID)
    }
}

private struct TrieNode: Sendable {
    let actionID: ActionID?
    let children: [KeyToken: TrieNode]

    init(_ mutable: MutableTrieNode) {
        self.actionID = mutable.actionID
        self.children = mutable.children.mapValues(TrieNode.init)
    }
}
