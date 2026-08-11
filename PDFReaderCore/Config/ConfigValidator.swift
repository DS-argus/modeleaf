import Foundation

public struct ValidatedAppConfig: Sendable {
    public let config: EffectiveAppConfig
    public let keymap: ValidatedKeymap
    public let keySequenceTrie: KeySequenceTrie
    public let menuDescriptors: [MenuDescriptor]

    init(
        config: EffectiveAppConfig,
        keymap: ValidatedKeymap,
        keySequenceTrie: KeySequenceTrie,
        menuDescriptors: [MenuDescriptor]
    ) {
        self.config = config
        self.keymap = keymap
        self.keySequenceTrie = keySequenceTrie
        self.menuDescriptors = menuDescriptors
    }

    public func makeKeyEngine(context: InputContext) -> KeySequenceEngine {
        KeySequenceEngine(
            trie: keySequenceTrie,
            context: context,
            prefixTimeoutMilliseconds: config.input.prefixTimeoutMilliseconds
        )
    }
}

public struct ConfigValidationReport: Sendable {
    public let validatedConfig: ValidatedAppConfig?
    public let diagnostics: [ConfigDiagnostic]

    init(validatedConfig: ValidatedAppConfig?, diagnostics: [ConfigDiagnostic]) {
        self.validatedConfig = validatedConfig
        self.diagnostics = diagnostics
    }

    public var isValid: Bool {
        validatedConfig != nil && !diagnostics.contains { $0.severity == .error }
    }
}

enum ConfigSeed {
    case builtInTemplated
    case concrete([ActionID: [KeySequence]])
}

public enum ConfigValidator {
    public static func validate(
        _ sparse: SparseAppConfig,
        source: ConfigSourceMetadata = .none,
        registry: ActionRegistry = .v1
    ) -> ConfigValidationReport {
        validate(
            sparse,
            source: source,
            seed: .builtInTemplated,
            defaults: BuiltInDefaults.config,
            registry: registry
        )
    }

    public static func validate(
        _ sparse: SparseAppConfig,
        source: ConfigSourceMetadata = .none,
        defaults: EffectiveAppConfig,
        registry: ActionRegistry = .v1
    ) -> ConfigValidationReport {
        validate(
            sparse,
            source: source,
            seed: .concrete(defaults.keymap),
            defaults: defaults,
            registry: registry
        )
    }

    private static func validate(
        _ sparse: SparseAppConfig,
        source: ConfigSourceMetadata,
        seed: ConfigSeed,
        defaults: EffectiveAppConfig,
        registry: ActionRegistry
    ) -> ConfigValidationReport {
        var diagnostics: [ConfigDiagnostic] = []

        let rawPrefix = sparse.input?.prefix ?? defaults.input.prefix
        let effectivePrefix: String
        if (try? KeySequenceParser.parseSingleToken(rawPrefix)) != nil {
            effectivePrefix = rawPrefix
        } else {
            effectivePrefix = defaults.input.prefix
            diagnostics.append(
                makeDiagnostic(
                    severity: .warning,
                    code: .invalidPrefix,
                    message: "Invalid pane prefix \"\(rawPrefix)\"; expected a single key chord such as <C-b>. Using \(defaults.input.prefix).",
                    path: "input.prefix",
                    source: source
                )
            )
        }

        var bindings: [ActionID: [KeySequence]]
        switch seed {
        case .builtInTemplated:
            bindings = resolvedBuiltInKeymap(prefix: effectivePrefix)
        case let .concrete(keymap):
            bindings = keymap
        }
        for rawAction in sparse.keymap?.keys.sorted() ?? [] {
            let rawSequences = sparse.keymap?[rawAction] ?? []
            guard let actionID = ActionID(rawValue: rawAction), registry.descriptor(for: actionID) != nil else {
                diagnostics.append(
                    makeDiagnostic(
                        code: .unknownAction,
                        message: "Unknown action identifier \(rawAction).",
                        path: ConfigSemanticPath.keymap(action: rawAction),
                        source: source,
                        actions: [rawAction]
                    )
                )
                continue
            }

            if registry.isFixedBinding(actionID) {
                diagnostics.append(
                    makeDiagnostic(
                        severity: .warning,
                        code: .reservedAction,
                        message: "\(rawAction) is a fixed key and cannot be rebound; keeping the built-in binding.",
                        path: ConfigSemanticPath.keymap(action: rawAction),
                        source: source,
                        actions: [rawAction]
                    )
                )
                continue
            }

            var parsed: [KeySequence] = []
            for (index, rawSequence) in rawSequences.enumerated() {
                do {
                    parsed.append(try KeySequenceParser.parse(Self.expandPrefix(rawSequence, prefix: effectivePrefix)))
                } catch {
                    let descriptor = registry.descriptor(for: actionID)
                    let diagnosticContexts = descriptor?.isPromptActive == true
                        ? descriptor?.activeContexts.intersection(InputContext.promptContexts) ?? []
                        : descriptor?.activeContexts ?? []
                    diagnostics.append(
                        makeDiagnostic(
                            code: .invalidKeySequence,
                            message: String(describing: error),
                            path: ConfigSemanticPath.keymap(action: rawAction, bindingIndex: index),
                            source: source,
                            actions: [rawAction],
                            contexts: diagnosticContexts
                        )
                    )
                }
            }
            bindings[actionID] = parsed
        }

        let navigation = NavigationConfiguration(
            smallScrollPoints: bounded(
                sparse.navigation?.smallScrollPoints,
                default: defaults.navigation.smallScrollPoints,
                range: ConfigBounds.smallScrollPoints,
                path: "navigation.small_scroll_points",
                source: source,
                diagnostics: &diagnostics
            ),
            largeScrollViewportFraction: bounded(
                sparse.navigation?.largeScrollViewportFraction,
                default: defaults.navigation.largeScrollViewportFraction,
                range: ConfigBounds.largeScrollViewportFraction,
                path: "navigation.large_scroll_viewport_fraction",
                source: source,
                diagnostics: &diagnostics
            ),
            zoomFactor: bounded(
                sparse.navigation?.zoomFactor,
                default: defaults.navigation.zoomFactor,
                range: ConfigBounds.zoomFactor,
                path: "navigation.zoom_factor",
                source: source,
                diagnostics: &diagnostics
            )
        )
        let input = InputConfiguration(
            prefixTimeoutMilliseconds: bounded(
                sparse.input?.prefixTimeoutMilliseconds,
                default: defaults.input.prefixTimeoutMilliseconds,
                range: ConfigBounds.prefixTimeoutMilliseconds,
                path: "input.prefix_timeout_ms",
                source: source,
                diagnostics: &diagnostics
            ),
            prefix: effectivePrefix
        )



        let effective = EffectiveAppConfig(
            keymap: bindings,
            navigation: navigation,
            input: input
        )
        validateEffectiveConfiguration(
            effective,
            registry: registry,
            source: source,
            diagnostics: &diagnostics
        )

        let bindingReport = ActionBindingPolicy.evaluateEffective(bindings, registry: registry)
        diagnostics += bindingReport.diagnostics.map {
            bindingDiagnostic($0, bindings: bindings, source: source)
        }

        var trie: KeySequenceTrie?
        if let validatedKeymap = bindingReport.validatedKeymap {
            let trieReport = KeySequenceTrie.build(from: validatedKeymap, registry: registry)
            diagnostics += trieReport.diagnostics.map {
                prefixDiagnostic($0, bindings: bindings, source: source)
            }
            trie = trieReport.trie
        }

        let hasErrors = diagnostics.contains { $0.severity == .error }
        guard !hasErrors,
              let validatedKeymap = bindingReport.validatedKeymap,
              let trie
        else {
            return ConfigValidationReport(validatedConfig: nil, diagnostics: diagnostics)
        }

        let menus = MenuEquivalentPolicy.makeDescriptors(
            evaluatedBindings: bindingReport.evaluatedBindings,
            registry: registry
        )
        for descriptor in registry.descriptors where descriptor.scope == .global {
            let configured = bindings[descriptor.id, default: []]
            let menu = menus.first { $0.actionID == descriptor.id }
            if !configured.isEmpty, menu != nil, menu?.keyEquivalent == nil {
                diagnostics.append(
                    makeDiagnostic(
                        severity: .warning,
                        code: .menuEquivalentOmitted,
                        message: "The binding remains router-active, but no safe global menu equivalent can be derived.",
                        path: ConfigSemanticPath.keymap(action: descriptor.id.rawValue),
                        source: source,
                        actions: [descriptor.id.rawValue],
                        contexts: descriptor.activeContexts
                    )
                )
            }
        }

        return ConfigValidationReport(
            validatedConfig: ValidatedAppConfig(
                config: effective,
                keymap: validatedKeymap,
                keySequenceTrie: trie,
                menuDescriptors: menus
            ),
            diagnostics: diagnostics
        )
    }

    private static func bounded<T: Comparable>(
        _ supplied: T?,
        default defaultValue: T,
        range: ClosedRange<T>,
        path: String,
        source: ConfigSourceMetadata,
        diagnostics: inout [ConfigDiagnostic]
    ) -> T {
        guard let supplied else { return defaultValue }
        guard range.contains(supplied) else {
            diagnostics.append(
                makeDiagnostic(
                    code: .valueOutOfRange,
                    message: "Value must be in \(range.lowerBound)...\(range.upperBound).",
                    path: path,
                    source: source
                )
            )
            return defaultValue
        }
        return supplied
    }

    private static func validateEffectiveConfiguration(
        _ config: EffectiveAppConfig,
        registry: ActionRegistry,
        source: ConfigSourceMetadata,
        diagnostics: inout [ConfigDiagnostic]
    ) {
        validateEffectiveValue(
            config.navigation.smallScrollPoints,
            range: ConfigBounds.smallScrollPoints,
            path: "navigation.small_scroll_points",
            source: source,
            diagnostics: &diagnostics
        )
        validateEffectiveValue(
            config.navigation.largeScrollViewportFraction,
            range: ConfigBounds.largeScrollViewportFraction,
            path: "navigation.large_scroll_viewport_fraction",
            source: source,
            diagnostics: &diagnostics
        )
        validateEffectiveValue(
            config.navigation.zoomFactor,
            range: ConfigBounds.zoomFactor,
            path: "navigation.zoom_factor",
            source: source,
            diagnostics: &diagnostics
        )
        validateEffectiveValue(
            config.input.prefixTimeoutMilliseconds,
            range: ConfigBounds.prefixTimeoutMilliseconds,
            path: "input.prefix_timeout_ms",
            source: source,
            diagnostics: &diagnostics
        )

        let unknownEffectiveActions = Set(config.keymap.keys).subtracting(registry.actionIDs)
        for actionID in unknownEffectiveActions.sorted(by: { $0.rawValue < $1.rawValue }) {
            diagnostics.append(
                makeDiagnostic(
                    code: .internalInvariant,
                    message: "The effective keymap contains an action outside the active registry.",
                    path: ConfigSemanticPath.keymap(action: actionID.rawValue),
                    source: source,
                    actions: [actionID.rawValue]
                )
            )
        }
    }

    private static func validateEffectiveValue<T: Comparable>(
        _ value: T,
        range: ClosedRange<T>,
        path: String,
        source: ConfigSourceMetadata,
        diagnostics: inout [ConfigDiagnostic]
    ) {
        guard !range.contains(value) else { return }
        diagnostics.append(
            makeDiagnostic(
                code: .internalInvariant,
                message: "The effective value is outside (range.lowerBound)...(range.upperBound).",
                path: path,
                source: source
            )
        )
    }

    private static func bindingDiagnostic(
        _ diagnostic: ActionBindingDiagnostic,
        bindings: [ActionID: [KeySequence]],
        source: ConfigSourceMetadata
    ) -> ConfigDiagnostic {
        switch diagnostic {
        case let .missingAction(actionID):
            return makeDiagnostic(
                code: .missingAction,
                message: "The effective keymap omitted a registry action.",
                path: ConfigSemanticPath.keymap(action: actionID.rawValue),
                source: source,
                actions: [actionID.rawValue]
            )
        case let .emptySequence(actionID, bindingOrder):
            return makeDiagnostic(
                code: .invalidKeySequence,
                message: "An empty KeySequence value is not a valid binding; use an empty TOML array to unbind.",
                path: ConfigSemanticPath.keymap(action: actionID.rawValue, bindingIndex: bindingOrder),
                source: source,
                actions: [actionID.rawValue]
            )
        case let .duplicateSequence(actionID, sequence):
            return makeDiagnostic(
                code: .duplicateBinding,
                message: "Duplicate binding \(sequence.description) for the same action.",
                path: path(for: sequence, action: actionID, bindings: bindings),
                source: source,
                actions: [actionID.rawValue]
            )
        case let .promptUnsafe(failure):
            return makeDiagnostic(
                code: .promptUnsafeBinding,
                message: promptViolationDescription(failure.violation),
                path: path(for: failure.sequence, action: failure.actionID, bindings: bindings),
                source: source,
                actions: [failure.actionID.rawValue],
                contexts: failure.promptContexts
            )
        case let .conflictingSequence(sequence, first, second, overlappingContexts):
            return makeDiagnostic(
                code: .conflictingBinding,
                message: "Binding \(sequence.description) is assigned to actions with overlapping contexts.",
                path: path(for: sequence, action: second, bindings: bindings),
                source: source,
                actions: [first.rawValue, second.rawValue],
                contexts: overlappingContexts
            )
        }
    }

    private static func prefixDiagnostic(
        _ diagnostic: KeySequenceTrieDiagnostic,
        bindings: [ActionID: [KeySequence]],
        source: ConfigSourceMetadata
    ) -> ConfigDiagnostic {
        switch diagnostic {
        case let .invalidExactPrefix(
            shorterAction,
            shorterSequence,
            longerAction,
            longerSequence,
            overlappingContexts,
            reason
        ):
            return makeDiagnostic(
                code: .invalidExactPrefix,
                message: "Exact binding \(shorterSequence.description) prefixes \(longerSequence.description), but \(reason.rawValue).",
                path: path(for: longerSequence, action: longerAction, bindings: bindings),
                source: source,
                actions: [shorterAction.rawValue, longerAction.rawValue],
                contexts: overlappingContexts
            )
        }
    }

    private static func path(
        for sequence: KeySequence,
        action: ActionID,
        bindings: [ActionID: [KeySequence]]
    ) -> String {
        let index = bindings[action, default: []].firstIndex(of: sequence)
        return ConfigSemanticPath.keymap(action: action.rawValue, bindingIndex: index)
    }

    private static func promptViolationDescription(_ violation: PromptSafetyViolation) -> String {
        switch violation {
        case .multipleTokens:
            "Prompt-active actions accept at most one token in v1."
        case let .promptTextInput(token):
            "Token \(token.description) belongs to native prompt text input."
        case let .modifierWithoutCommand(token):
            "Token \(token.description) uses modifiers without Command and cannot own prompt input."
        case let .promptNativeReservation(token):
            "Token \(token.description) is reserved for native prompt editing/navigation."
        case let .systemReservation(token):
            "Token \(token.description) is reserved by the fixed macOS system table."
        case let .lifecycleKeyRequiresPromptAction(token):
            "Token \(token.description) may be bound only to a prompt lifecycle action."
        case let .compositionInput(token):
            "Token \(token.description) belongs to dead-key or IME composition."
        }
    }

    private static func makeDiagnostic(
        severity: ConfigDiagnosticSeverity = .error,
        code: ConfigDiagnosticCode,
        message: String,
        path: String,
        source: ConfigSourceMetadata,
        actions: [String] = [],
        contexts: Set<InputContext> = []
    ) -> ConfigDiagnostic {
        ConfigDiagnostic(
            severity: severity,
            code: code,
            message: message,
            semanticPath: path,
            sourcePath: source.sourcePath,
            line: source.line(for: path),
            actions: actions,
            contexts: InputContext.allCases.filter(contexts.contains)
        )
    }

    private static func resolvedBuiltInKeymap(prefix: String) -> [ActionID: [KeySequence]] {
        BuiltInDefaults.templatedKeymap.mapValues { sources in
            sources.map { source in
                do {
                    return try KeySequenceParser.parse(expandPrefix(source, prefix: prefix))
                } catch {
                    preconditionFailure("invalid built-in binding \(source): \(error)")
                }
            }
        }
    }
    private static func expandPrefix(_ raw: String, prefix: String) -> String {
        raw.replacingOccurrences(of: "<prefix>", with: prefix)
    }
}
