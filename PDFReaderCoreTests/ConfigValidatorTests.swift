import PDFReaderCore
import Testing

@Suite("Strict configuration validation")
struct ConfigValidatorTests {
    @Test("U-CFG-03 sparse values overlay typed defaults without leaking omissions")
    func sparseOverlayProducesCompleteEffectiveConfig() throws {
        let sparse = SparseAppConfig(
            keymap: [ActionID.scrollDown.rawValue: ["x"]],
            navigation: SparseNavigationConfiguration(smallScrollPoints: 72),
        )

        let report = ConfigValidator.validate(sparse)
        let active = try #require(report.validatedConfig)

        #expect(report.isValid)
        #expect(report.diagnostics.isEmpty)
        #expect(active.config.navigation.smallScrollPoints == 72)
        #expect(
            active.config.navigation.largeScrollViewportFraction
                == BuiltInDefaults.config.navigation.largeScrollViewportFraction
        )
        #expect(active.config.navigation.zoomFactor == BuiltInDefaults.config.navigation.zoomFactor)
        #expect(active.config.input == BuiltInDefaults.config.input)
        #expect(active.keymap.bindings(for: .scrollDown) == [try sequence("x")])
        #expect(active.keymap.bindings(for: .scrollUp) == BuiltInDefaults.keymap[.scrollUp])
        #expect(Set(active.config.keymap.keys) == Set(ActionRegistry.v1.actionIDs))
    }

    @Test("U-CFG-03 the complete effective value is revalidated")
    func effectiveConfigurationIsRevalidated() {
        let invalidDefaults = EffectiveAppConfig(
            keymap: BuiltInDefaults.keymap,
            navigation: BuiltInDefaults.config.navigation,
            input: InputConfiguration(prefixTimeoutMilliseconds: 99),
        )

        let report = ConfigValidator.validate(SparseAppConfig(), defaults: invalidDefaults)

        #expect(!report.isValid)
        #expect(report.validatedConfig == nil)
        #expect(report.diagnostics.contains { diagnostic in
            diagnostic.code == .internalInvariant
                && diagnostic.semanticPath == "input.prefix_timeout_ms"
        })
    }

    @Test("U-CFG-05 unknown action identifiers retain semantic source location")
    func unknownActionIsRejected() {
        let action = "bookmark.toggle"
        let path = ConfigSemanticPath.keymap(action: action)
        let source = ConfigSourceMetadata(
            sourcePath: "/tmp/config.toml",
            lineBySemanticPath: [path: 17]
        )

        let report = ConfigValidator.validate(
            SparseAppConfig(keymap: [action: ["b"]]),
            source: source
        )
        let diagnostic = report.diagnostics.first { $0.code == .unknownAction }

        #expect(!report.isValid)
        #expect(diagnostic?.semanticPath == path)
        #expect(diagnostic?.sourcePath == "/tmp/config.toml")
        #expect(diagnostic?.line == 17)
        #expect(diagnostic?.actions == [action])
    }

    @Test("U-CFG-06 duplicate, overlapping, disjoint, and exact-prefix bindings are deterministic")
    func bindingRelationships() throws {
        let duplicate = ConfigValidator.validate(
            SparseAppConfig(keymap: [ActionID.scrollDown.rawValue: ["x", "x"]])
        )
        #expect(!duplicate.isValid)
        #expect(duplicate.diagnostics.contains { $0.code == .duplicateBinding })

        let conflict = ConfigValidator.validate(
            SparseAppConfig(
                keymap: [
                    ActionID.scrollDown.rawValue: ["x"],
                    ActionID.scrollUp.rawValue: ["x"],
                ]
            )
        )
        let conflictDiagnostic = conflict.diagnostics.first { $0.code == .conflictingBinding }
        #expect(!conflict.isValid)
        #expect(conflictDiagnostic?.actions == [ActionID.scrollDown.rawValue, ActionID.scrollUp.rawValue])
        #expect(conflictDiagnostic?.contexts == [.navigation, .searchResults])

        let disjoint = ConfigValidator.validate(SparseAppConfig())
        #expect(disjoint.isValid)
        #expect(disjoint.validatedConfig?.keymap.bindings(for: .promptCommit) == [try sequence("<CR>")])
        #expect(disjoint.validatedConfig?.keymap.bindings(for: .searchNext) == [try sequence("<CR>")])

        let invalidPrefix = ConfigValidator.validate(
            SparseAppConfig(
                keymap: [
                    ActionID.pageLast.rawValue: ["q"],
                    ActionID.pageFirst.rawValue: ["qq"],
                ]
            )
        )
        let prefixDiagnostic = invalidPrefix.diagnostics.first { $0.code == .invalidExactPrefix }
        #expect(!invalidPrefix.isValid)
        #expect(prefixDiagnostic?.actions == [ActionID.pageLast.rawValue, ActionID.pageFirst.rawValue])
        #expect(prefixDiagnostic?.contexts == [.navigation, .searchResults])
        #expect(prefixDiagnostic?.semanticPath == ConfigSemanticPath.keymap(action: ActionID.pageFirst.rawValue, bindingIndex: 0))
    }

    @Test("U-CFG-07 numeric bounds reject every supplied out-of-range value")
    func numericBounds() {
        let report = ConfigValidator.validate(
            SparseAppConfig(
                navigation: SparseNavigationConfiguration(
                    smallScrollPoints: 0,
                    largeScrollViewportFraction: 2.01,
                    zoomFactor: 1
                ),
                input: SparseInputConfiguration(prefixTimeoutMilliseconds: 2_001)
            )
        )

        #expect(!report.isValid)
        #expect(report.validatedConfig == nil)
        #expect(
            Set(report.diagnostics.filter { $0.code == .valueOutOfRange }.map(\.semanticPath))
                == [
                    "navigation.small_scroll_points",
                    "navigation.large_scroll_viewport_fraction",
                    "navigation.zoom_factor",
                    "input.prefix_timeout_ms",
                ]
        )
    }


    @Test("U-CFG-13 every prompt-active action shares one strict binding predicate")
    func promptActiveActionsUseSharedPredicate() throws {
        let promptActive = ActionRegistry.v1.descriptors.filter { $0.isPromptActive && !$0.isFixedBinding }
        #expect(promptActive.map(\.id) == [.documentOpen, .appQuit, .appNew])

        for descriptor in promptActive {
            let unbound = validateBinding([], for: descriptor.id)
            #expect(unbound.isValid, "\(descriptor.id.rawValue) must support an intentional unbind")

            let safe = validateBinding(["<D-F12>"], for: descriptor.id)
            #expect(safe.isValid, "\(descriptor.id.rawValue) must accept the shared safe Command chord")

            for source in ["go", "o", "<C-o>", "<A-o>", "<S-o>", "<DeadKey>", "<IME>"] {
                assertPromptBindingRejected(source, for: descriptor)
            }
            for source in PromptNativeReservationV1.shared.normalizedEntries {
                assertPromptBindingRejected(source, for: descriptor)
            }
            for source in SystemKeyReservationV1.shared.normalizedEntries {
                assertPromptBindingRejected(source, for: descriptor)
            }
        }
    }

    @Test("U-CFG-14 fixed prompt and search keys reject rebinding and keep defaults")
    func fixedKeysRejectRebinding() throws {
        let report = ConfigValidator.validate(
            SparseAppConfig(
                keymap: [
                    ActionID.promptCommit.rawValue: [],
                    ActionID.promptCancel.rawValue: ["<D-F12>"],
                    ActionID.searchNext.rawValue: ["x"],
                    ActionID.searchPrevious.rawValue: [],
                ]
            )
        )
        let active = try #require(report.validatedConfig)
        let warnings = report.diagnostics.filter { $0.code == .reservedAction }
        #expect(report.isValid)
        #expect(warnings.count == 4)
        #expect(warnings.allSatisfy { $0.severity == .warning })
        #expect(
            Set(warnings.flatMap(\.actions)) == [
                ActionID.promptCommit.rawValue, ActionID.promptCancel.rawValue,
                ActionID.searchNext.rawValue, ActionID.searchPrevious.rawValue,
            ]
        )
        #expect(active.keymap.bindings(for: .promptCommit) == [try sequence("<CR>")])
        #expect(active.keymap.bindings(for: .promptCancel) == [try sequence("<Esc>")])
        #expect(active.keymap.bindings(for: .searchNext) == [try sequence("<CR>")])
        #expect(active.keymap.bindings(for: .searchPrevious) == [try sequence("<S-CR>")])
        var engine = active.makeKeyEngine(context: .pagePrompt)
        #expect(engine.handle(try token("<CR>")) != .ignored(.noBinding))
        #expect(engine.handle(try token("<Esc>")) != .ignored(.noBinding))
    }

    @Test("U-CFG-15 pane prefix is configurable and expands <prefix> bindings")
    func configurablePanePrefix() throws {
        let custom = ConfigValidator.validate(
            SparseAppConfig(
                keymap: [ActionID.paneSplitRight.rawValue: ["<prefix>|"]],
                input: SparseInputConfiguration(prefix: "<C-a>")
            )
        )
        let active = try #require(custom.validatedConfig)
        #expect(custom.isValid)
        #expect(active.config.input.prefix == "<C-a>")
        #expect(active.keymap.bindings(for: .paneSplitRight) == [try sequence("<C-a>|")])

        let reused = ConfigValidator.validate(
            SparseAppConfig(
                keymap: [ActionID.themePicker.rawValue: ["<prefix>t"]],
                input: SparseInputConfiguration(prefix: "<C-b>")
            )
        )
        #expect(reused.validatedConfig?.keymap.bindings(for: .themePicker) == [try sequence("<C-b>t")])

        let invalid = ConfigValidator.validate(
            SparseAppConfig(input: SparseInputConfiguration(prefix: "nonsense-chord"))
        )
        #expect(invalid.isValid)
        #expect(invalid.diagnostics.contains { $0.code == .invalidPrefix && $0.severity == .warning })
        #expect(invalid.validatedConfig?.config.input.prefix == "<C-b>")
    }

    private func validateBinding(_ sources: [String], for actionID: ActionID) -> ConfigValidationReport {
        ConfigValidator.validate(
            SparseAppConfig(keymap: [actionID.rawValue: sources])
        )
    }

    private func assertPromptBindingRejected(
        _ source: String,
        for descriptor: ActionDescriptor,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let report = validateBinding([source], for: descriptor.id)
        let expectedPath = ConfigSemanticPath.keymap(action: descriptor.id.rawValue, bindingIndex: 0)
        let matching = report.diagnostics.first { diagnostic in
            diagnostic.actions == [descriptor.id.rawValue]
                && diagnostic.semanticPath == expectedPath
                && Set(diagnostic.contexts) == descriptor.activeContexts.intersection(InputContext.promptContexts)
        }

        #expect(!report.isValid, "\(descriptor.id.rawValue) unexpectedly accepted \(source)", sourceLocation: sourceLocation)
        #expect(
            matching?.code == .promptUnsafeBinding || matching?.code == .invalidKeySequence,
            "\(descriptor.id.rawValue) did not diagnose \(source) with the shared path/context contract",
            sourceLocation: sourceLocation
        )
    }

    private func sequence(_ source: String) throws -> KeySequence {
        try KeySequenceParser.parse(source)
    }

    private func token(_ source: String) throws -> KeyToken {
        try KeySequenceParser.parseSingleToken(source)
    }
}
