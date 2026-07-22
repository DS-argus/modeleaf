import PDFReaderCore
import Testing

@Suite("Strict configuration validation")
struct ConfigValidatorTests {
    @Test("U-CFG-03 sparse values overlay typed defaults without leaking omissions")
    func sparseOverlayProducesCompleteEffectiveConfig() throws {
        let sparse = SparseAppConfig(
            keymap: [ActionID.scrollDown.rawValue: ["x"]],
            navigation: SparseNavigationConfiguration(smallScrollPoints: 72),
            theme: SparseThemeConfiguration(
                builtIn: ThemeID.nord.rawValue,
                overrides: [ThemeToken.accent.rawValue: "#abcdef"]
            )
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
        #expect(active.config.theme.builtIn == .nord)
        #expect(active.config.theme.overrides == [.accent: try #require(ThemeColor(rawValue: "#ABCDEF"))])
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
            theme: BuiltInDefaults.config.theme
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

        let disjoint = ConfigValidator.validate(
            SparseAppConfig(
                keymap: [
                    ActionID.promptCommit.rawValue: ["<D-F12>"],
                    ActionID.searchNext.rawValue: ["<D-F12>"],
                ]
            )
        )
        #expect(disjoint.isValid)
        #expect(disjoint.validatedConfig?.keymap.bindings(for: .promptCommit) == [try sequence("<D-F12>")])
        #expect(disjoint.validatedConfig?.keymap.bindings(for: .searchNext) == [try sequence("<D-F12>")])

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

    @Test("U-THEME-02 theme overrides are sparse, typed, and strict")
    func themeOverrides() throws {
        let valid = ConfigValidator.validate(
            SparseAppConfig(
                theme: SparseThemeConfiguration(
                    overrides: [ThemeToken.statusline.rawValue: "#12345678"]
                )
            )
        )
        let active = try #require(valid.validatedConfig)
        #expect(active.config.theme.builtIn == BuiltInDefaults.config.theme.builtIn)
        #expect(active.config.theme.overrides == [.statusline: try #require(ThemeColor(rawValue: "#12345678"))])

        let invalid = ConfigValidator.validate(
            SparseAppConfig(
                theme: SparseThemeConfiguration(
                    builtIn: "solarized",
                    overrides: [
                        "pdf-page": "#FFFFFF",
                        ThemeToken.error.rawValue: "red",
                    ]
                )
            )
        )
        #expect(!invalid.isValid)
        #expect(Set(invalid.diagnostics.map(\.code)).isSuperset(of: [.invalidTheme, .invalidThemeToken, .invalidColor]))
        #expect(invalid.validatedConfig == nil)
    }

    @Test("U-CFG-13 every prompt-active action shares one strict binding predicate")
    func promptActiveActionsUseSharedPredicate() throws {
        let promptActive = ActionRegistry.v1.descriptors.filter(\.isPromptActive)
        #expect(promptActive.map(\.id) == [.documentOpen, .appQuit, .promptCommit, .promptCancel])

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

    @Test("U-CFG-14 prompt lifecycle can be intentionally keyboard-unbound")
    func promptLifecycleUnbindRemainsUsable() throws {
        let report = ConfigValidator.validate(
            SparseAppConfig(
                keymap: [
                    ActionID.promptCommit.rawValue: [],
                    ActionID.promptCancel.rawValue: [],
                ]
            )
        )
        let active = try #require(report.validatedConfig)
        let warnings = report.diagnostics.filter { $0.code == .promptLifecycleUnbound }

        #expect(report.isValid)
        #expect(warnings.count == 1)
        #expect(warnings[0].severity == .warning)
        #expect(
            Set(warnings[0].actions)
                == [ActionID.promptCommit.rawValue, ActionID.promptCancel.rawValue]
        )
        #expect(!active.keymap.isBound(.promptCommit))
        #expect(!active.keymap.isBound(.promptCancel))

        var engine = active.makeKeyEngine(context: .pagePrompt)
        #expect(engine.handle(try token("<CR>")) == .ignored(.noBinding))
        #expect(engine.handle(try token("<Esc>")) == .ignored(.noBinding))

        let promptControls = ActionSurfaceRegistry.v1.filter { $0.kind == .promptControl }
        #expect(promptControls.contains { $0.actionID == .promptCommit })
        #expect(promptControls.contains { $0.actionID == .promptCancel })
        #expect(active.keymap.isBound(.appQuit))
        let quitToken = try token("<D-q>")
        #expect(active.menuDescriptors.first { $0.actionID == .appQuit }?.keyEquivalent == quitToken)
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
