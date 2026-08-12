import PDFReaderCore
import Testing

@Suite("Prefix trie and deterministic key engine")
struct KeySequenceEngineTests {
    @Test("U-SEQ-01 exact sequence without descendants dispatches immediately")
    func exactSequenceDispatchesImmediately() throws {
        var engine = try makeEngine()
        let j = try token("j")

        #expect(
            engine.handle(j)
                == .dispatch(KeyActionDispatch(actionID: .scrollDown))
        )
        #expect(engine.pending == nil)
        #expect(engine.context == .navigation)
    }

    @Test("U-SEQ-02 exact plus longer match remains visibly pending")
    func exactPlusLongerRemainsPending() throws {
        var engine = try makeEngine()
        let outcome = engine.handle(try token("g"))
        let pending = try #require(engine.pending)

        #expect(outcome == .pending(pending))
        #expect(pending.sequence.description == "g")
        #expect(pending.exactAction == .pagePrompt)
        #expect(pending.hasLongerMatches)
        #expect(pending.timeoutMilliseconds == 400)
        #expect(pending.epoch == PrefixEpoch(rawValue: 1))
    }

    @Test("U-SEQ-03 a longer exact match wins once and clears pending state")
    func longerExactMatchWins() throws {
        for (source, action) in [("gg", ActionID.pageFirst)] {
            var engine = try makeEngine()
            let characters = source.map(String.init)
            let first = engine.handle(try token(characters[0]))
            guard case let .pending(pending) = first else {
                Issue.record("first token of \(source) must become pending")
                continue
            }

            #expect(
                engine.handle(try token(characters[1]))
                    == .dispatch(KeyActionDispatch(actionID: action))
            )
            #expect(engine.pending == nil)
            #expect(engine.timeout(epoch: pending.epoch) == .ignored(.staleTimeout(pending.epoch)))
        }
    }

    @Test("U-SEQ-04 replay-safe mismatch transitions and replays one semantic digit")
    func semanticDigitReplay() throws {
        var engine = try makeEngine()
        _ = engine.handle(try token("g"))

        let digit = try token("1")
        let replay = SemanticKeyReplay(
            token: digit,
            tokenClass: .decimalDigit,
            targetContext: .pagePrompt
        )
        #expect(
            engine.handle(digit)
                == .dispatch(
                    KeyActionDispatch(
                        actionID: .pagePrompt,
                        transitionedContext: .pagePrompt,
                        semanticReplay: replay
                    )
                )
        )
        #expect(engine.context == .pagePrompt)
        #expect(engine.pending == nil)

        var pageBuffer = PageNumberInputBuffer()
        let replayWasAppended = pageBuffer.append(replay)
        #expect(replayWasAppended)
        let secondDigit = try token("2")
        #expect(engine.handle(secondDigit) == .native(secondDigit))
        let secondDigitWasAppended = pageBuffer.append(secondDigit)
        #expect(secondDigitWasAppended)
        #expect(pageBuffer.digits == "12")
        #expect(pageBuffer.resolve(maximumPageCount: 300) == .success(12))

        var remapped = BuiltInDefaults.keymap
        remapped[.pagePrompt] = [try sequence("z")]
        remapped[.pageFirst] = [try sequence("zz")]
        var remappedEngine = try makeEngine(bindings: remapped)
        _ = remappedEngine.handle(try token("z"))
        let seven = try token("7")
        #expect(
            remappedEngine.handle(seven)
                == .dispatch(
                    KeyActionDispatch(
                        actionID: .pagePrompt,
                        transitionedContext: .pagePrompt,
                        semanticReplay: SemanticKeyReplay(
                            token: seven,
                            tokenClass: .decimalDigit,
                            targetContext: .pagePrompt
                        )
                    )
                )
        )
    }

    @Test("U-SEQ-05 exact-prefix overlap requires a safe semantic transition")
    func exactPrefixValidation() throws {
        var bindings = BuiltInDefaults.keymap
        bindings[.pageLast] = [try sequence("q")]
        bindings[.pageFirst] = [try sequence("qq")]
        let policy = ActionBindingPolicy.evaluateEffective(bindings)
        let validated = try #require(policy.validatedKeymap)
        let report = KeySequenceTrie.build(from: validated)
        #expect(!report.isValid)
        #expect(
            report.diagnostics
                == [
                    .invalidExactPrefix(
                        shorterAction: .pageLast,
                        shorterSequence: try sequence("q"),
                        longerAction: .pageFirst,
                        longerSequence: try sequence("qq"),
                        overlappingContexts: [.navigation, .searchResults],
                        reason: .shorterActionIsNotReplaySafe
                    ),
                ]
        )

        let lifecycleRegistry = registryReplacing(.documentClose) { descriptor in
            ActionDescriptor(
                id: descriptor.id,
                title: descriptor.title,
                scope: descriptor.scope,
                repeatPolicy: descriptor.repeatPolicy,
                prefixFallbackPolicy: .transitionAndReplay(
                    to: .pagePrompt,
                    acceptedToken: .decimalDigit
                ),
                isPromptLifecycle: descriptor.isPromptLifecycle
            )
        }
        var lifecycleBindings = BuiltInDefaults.keymap
        lifecycleBindings[.documentClose] = [try sequence("q")]
        lifecycleBindings[.pageFirst] = [try sequence("qq")]
        let lifecyclePolicy = ActionBindingPolicy.evaluateEffective(
            lifecycleBindings,
            registry: lifecycleRegistry
        )
        let lifecycleKeymap = try #require(lifecyclePolicy.validatedKeymap)
        let lifecycleReport = KeySequenceTrie.build(
            from: lifecycleKeymap,
            registry: lifecycleRegistry
        )
        #expect(
            lifecycleReport.diagnostics.contains(
                .invalidExactPrefix(
                    shorterAction: .documentClose,
                    shorterSequence: try sequence("q"),
                    longerAction: .pageFirst,
                    longerSequence: try sequence("qq"),
                    overlappingContexts: [.navigation, .searchResults],
                    reason: .lifecycleOrDestructiveAction
                )
            )
        )

        let wrongTargetRegistry = registryReplacing(.pageLast) { descriptor in
            ActionDescriptor(
                id: descriptor.id,
                title: descriptor.title,
                scope: descriptor.scope,
                repeatPolicy: descriptor.repeatPolicy,
                prefixFallbackPolicy: .transitionAndReplay(
                    to: .searchPrompt,
                    acceptedToken: .decimalDigit
                ),
                isPromptLifecycle: descriptor.isPromptLifecycle
            )
        }
        let wrongTargetPolicy = ActionBindingPolicy.evaluateEffective(
            bindings,
            registry: wrongTargetRegistry
        )
        let wrongTargetKeymap = try #require(wrongTargetPolicy.validatedKeymap)
        #expect(
            KeySequenceTrie.build(from: wrongTargetKeymap, registry: wrongTargetRegistry)
                .diagnostics.contains(
                    .invalidExactPrefix(
                        shorterAction: .pageLast,
                        shorterSequence: try sequence("q"),
                        longerAction: .pageFirst,
                        longerSequence: try sequence("qq"),
                        overlappingContexts: [.navigation, .searchResults],
                        reason: .replayTargetCannotConsumeTokenClass
                    )
                )
        )
    }

    @Test("U-SEQ-06 timeout epochs dispatch once and stale callbacks never cross boundaries")
    func timeoutEpochs() throws {
        var timeoutEngine = try makeEngine()
        guard case let .pending(pending) = timeoutEngine.handle(try token("g")) else {
            Issue.record("g must be pending")
            return
        }
        #expect(
            timeoutEngine.timeout(epoch: pending.epoch)
                == .dispatch(
                    KeyActionDispatch(
                        actionID: .pagePrompt,
                        transitionedContext: .pagePrompt
                    )
                )
        )
        #expect(timeoutEngine.timeout(epoch: pending.epoch) == .ignored(.staleTimeout(pending.epoch)))

        for reason in [
            KeyInputInvalidationReason.configurationChanged,
            .focusLost,
            .sessionChanged,
            .sessionClosed,
            .promptCommitted,
            .promptCancelled,
            .explicitCancel,
        ] {
            var engine = try makeEngine()
            guard case let .pending(stale) = engine.handle(try token("g")) else {
                Issue.record("g must be pending")
                continue
            }
            #expect(engine.invalidate(reason) == .ignored(.invalidated(reason)))
            #expect(engine.pending == nil)
            #expect(engine.timeout(epoch: stale.epoch) == .ignored(.staleTimeout(stale.epoch)))
        }

        var contextEngine = try makeEngine()
        guard case let .pending(beforeContextChange) = contextEngine.handle(try token("g")) else {
            Issue.record("g must be pending")
            return
        }
        #expect(
            contextEngine.changeContext(to: .searchResults)
                == .ignored(.invalidated(.contextChanged))
        )
        #expect(
            contextEngine.timeout(epoch: beforeContextChange.epoch)
                == .ignored(.staleTimeout(beforeContextChange.epoch))
        )
        guard case let .pending(afterContextChange) = contextEngine.handle(try token("g")) else {
            Issue.record("g must be pending in search results")
            return
        }
        #expect(afterContextChange.epoch > beforeContextChange.epoch)

        let trie = try makeTrie().trie
        #expect(
            contextEngine.activate(trie: trie, prefixTimeoutMilliseconds: 750)
                == .ignored(.invalidated(.configurationChanged))
        )
        #expect(contextEngine.prefixTimeoutMilliseconds == 750)
        #expect(
            contextEngine.timeout(epoch: afterContextChange.epoch)
                == .ignored(.staleTimeout(afterContextChange.epoch))
        )
    }

    @Test("U-SEQ-07 invalid input and cancellation clear state without fallback dispatch")
    func cancellation() throws {
        var engine = try makeEngine()
        guard case let .pending(pending) = engine.handle(try token("g")) else {
            Issue.record("g must be pending")
            return
        }
        #expect(engine.handle(try token("x")) == .ignored(.invalidSequence))
        #expect(engine.pending == nil)
        #expect(engine.context == .navigation)
        #expect(engine.timeout(epoch: pending.epoch) == .ignored(.staleTimeout(pending.epoch)))

        _ = engine.changeContext(to: .pagePrompt)
        #expect(
            engine.handle(try token("<Esc>"))
                == .dispatch(KeyActionDispatch(actionID: .promptCancel))
        )
        #expect(engine.changeContext(to: .navigation) == .ignored(.invalidated(.contextChanged)))
    }

    @Test("U-SEQ-08 navigation has no implicit Vim count grammar")
    func noGeneralCounts() throws {
        var engine = try makeEngine()
        #expect(engine.handle(try token("1")) == .ignored(.noBinding))
        #expect(engine.handle(try token("0")) == .ignored(.noBinding))
        #expect(engine.handle(try token("j")) == .dispatch(KeyActionDispatch(actionID: .scrollDown)))
    }

    @Test("U-KEY-05 engine applies repeat policy without manufacturing multi-key input")
    func repeatPolicy() throws {
        var engine = try makeEngine()
        #expect(
            engine.handle(try token("j"), eventIsRepeat: true)
                == .dispatch(KeyActionDispatch(actionID: .scrollDown))
        )
        #expect(
            engine.handle(try token("G"), eventIsRepeat: true)
                == .ignored(.repeatSuppressed(.pageLast))
        )
        guard case let .pending(pending) = engine.handle(try token("g")) else {
            Issue.record("g must be pending")
            return
        }
        #expect(
            engine.handle(try token("g"), eventIsRepeat: true)
                == .ignored(.repeatDuringPrefix)
        )
        #expect(engine.pending == pending)
    }

    @Test("U-CTX-01 navigation printable bindings route through the trie")
    func navigationContext() throws {
        var engine = try makeEngine()
        let expectations: [(String, ActionID)] = [
            ("h", .scrollLeft), ("<Left>", .scrollLeft),
            ("j", .scrollDown), ("<Down>", .scrollDown),
            ("k", .scrollUp), ("<Up>", .scrollUp),
            ("l", .scrollRight), ("<Right>", .scrollRight),
            ("d", .scrollLargeDown), ("u", .scrollLargeUp),
            ("n", .pageNext), ("p", .pagePrevious),
            ("N", .tabNext), ("P", .tabPrevious),
            ("G", .pageLast), ("/", .searchPrompt),
            ("=", .viewZoomIn), ("-", .viewZoomOut),
            ("w", .viewFitWidth), ("f", .linkHint), ("F", .viewFitPage),
            ("<D-1>", .tabSelect1), ("<D-9>", .tabSelect9),
            ("<D-o>", .documentOpen), ("<D-w>", .documentClose), ("<D-p>", .documentPrint), ("<D-q>", .appQuit),
        ]
        for (source, action) in expectations {
            #expect(
                engine.handle(try token(source))
                    == .dispatch(KeyActionDispatch(actionID: action))
            )
        }

        #expect(engine.handle(try token("f")) != .dispatch(KeyActionDispatch(actionID: .viewFitPage)))
    }

    @Test("U-CTX-02 search prompt keeps literal, editing, dead-key, and IME input native")
    func searchPromptOwnership() throws {
        var engine = try makeEngine(context: .searchPrompt)
        for input in [try token("j"), try token("k"), try token("<BS>"), try token("<D-a>"), .deadKey, .imeComposition] {
            #expect(engine.handle(input) == .native(input))
            #expect(engine.pending == nil)
        }
        let systemOwned = try token("<D-S-q>")
        #expect(engine.handle(systemOwned) == .native(systemOwned))
        #expect(
            engine.handle(try token("<D-o>"))
                == .dispatch(KeyActionDispatch(actionID: .documentOpen))
        )
        #expect(
            engine.handle(try token("<Enter>"))
                == .dispatch(KeyActionDispatch(actionID: .promptCommit))
        )
        #expect(
            engine.handle(try token("<Esc>"))
                == .dispatch(KeyActionDispatch(actionID: .promptCancel))
        )
    }

    @Test("U-CTX-03 page prompt accepts ASCII digits and resolves one-based pages")
    func pagePromptOwnershipAndBuffer() throws {
        var engine = try makeEngine(context: .pagePrompt)
        let one = try token("1")
        #expect(engine.handle(one) == .native(one))
        #expect(engine.handle(try token("a")) == .ignored(.rejectedPagePromptText))
        #expect(engine.handle(.deadKey) == .native(.deadKey))
        #expect(engine.handle(.imeComposition) == .native(.imeComposition))
        #expect(
            engine.handle(try token("<Enter>"))
                == .dispatch(KeyActionDispatch(actionID: .promptCommit))
        )
        #expect(
            engine.handle(try token("<Esc>"))
                == .dispatch(KeyActionDispatch(actionID: .promptCancel))
        )

        var buffer = PageNumberInputBuffer()
        let oneWasAppended = buffer.append(one)
        #expect(oneWasAppended)
        let textWasAppended = buffer.append(try token("a"))
        #expect(!textWasAppended)
        #expect(buffer.resolve(maximumPageCount: 3) == .success(1))
        buffer.clear()
        #expect(buffer.resolve(maximumPageCount: 3) == .failure(.empty))

        var zero = PageNumberInputBuffer(digits: "0")
        #expect(zero.resolve(maximumPageCount: 3) == .failure(.zeroIsNotAPage))
        zero.clear()
        #expect(zero.digits.isEmpty)
        #expect(
            PageNumberInputBuffer(digits: "4").resolve(maximumPageCount: 3)
                == .failure(.outOfRange(requested: 4, maximum: 3))
        )
        #expect(
            PageNumberInputBuffer(digits: "1").resolve(maximumPageCount: 0)
                == .failure(.documentHasNoPages)
        )
        #expect(
            PageNumberInputBuffer(digits: String(repeating: "9", count: 100))
                .resolve(maximumPageCount: 300) == .failure(.numericOverflow)
        )
    }

    @Test("U-CTX-04 search-results actions and reader navigation share only declared context")
    func searchResultsContext() throws {
        var engine = try makeEngine(context: .searchResults)
        #expect(
            engine.handle(try token("<Enter>"))
                == .dispatch(KeyActionDispatch(actionID: .searchNext))
        )
        #expect(
            engine.handle(try token("<S-Enter>"))
                == .dispatch(KeyActionDispatch(actionID: .searchPrevious))
        )
        #expect(
            engine.handle(try token("<Esc>"))
                == .dispatch(KeyActionDispatch(actionID: .searchCancel))
        )
        #expect(
            engine.handle(try token("j"))
                == .dispatch(KeyActionDispatch(actionID: .scrollDown))
        )
    }

    @Test("U-CTX-05 identical sequences work only across disjoint contexts")
    func disjointContextReuse() throws {
        var bindings = BuiltInDefaults.keymap
        bindings[.pageNext] = [try sequence("<F12>")]
        bindings[.promptCommit] = [try sequence("<F12>")]
        let report = ActionBindingPolicy.evaluateEffective(bindings)
        #expect(report.isValid)
        let keymap = try #require(report.validatedKeymap)
        let trieReport = KeySequenceTrie.build(from: keymap)
        let trie = try #require(trieReport.trie)
        #expect(trieReport.diagnostics.isEmpty)

        var engine = KeySequenceEngine(
            trie: trie,
            context: .navigation,
            prefixTimeoutMilliseconds: 500
        )
        #expect(
            engine.handle(try token("<F12>"))
                == .dispatch(KeyActionDispatch(actionID: .pageNext))
        )
        _ = engine.changeContext(to: .pagePrompt)
        #expect(
            engine.handle(try token("<F12>"))
                == .dispatch(KeyActionDispatch(actionID: .promptCommit))
        )
        let pageMenu = MenuEquivalentPolicy.makeDescriptors(
            evaluatedBindings: report.evaluatedBindings
        ).first { $0.actionID == .pageNext }
        #expect(pageMenu?.keyEquivalent == nil)
    }

    @Test("U-CTX-06 context return invalidates prefixes and transient page input")
    func contextReturn() throws {
        var engine = try makeEngine()
        guard case let .pending(pending) = engine.handle(try token("g")) else {
            Issue.record("g must be pending")
            return
        }
        #expect(engine.changeContext(to: .pagePrompt) == .ignored(.invalidated(.contextChanged)))
        #expect(engine.pending == nil)
        #expect(engine.timeout(epoch: pending.epoch) == .ignored(.staleTimeout(pending.epoch)))

        var buffer = PageNumberInputBuffer(digits: "12")
        #expect(
            engine.handle(try token("<Esc>"))
                == .dispatch(KeyActionDispatch(actionID: .promptCancel))
        )
        buffer.clear()
        #expect(engine.changeContext(to: .navigation) == .ignored(.invalidated(.contextChanged)))
        #expect(buffer.digits.isEmpty)
    }


    @Test("help binding dispatches only outside prompt text entry")
    func helpBindingRespectsPromptContexts() throws {
        var navigation = try makeEngine()
        #expect(navigation.handle(try token("?")) == .dispatch(KeyActionDispatch(actionID: .helpShow)))

        var searchPrompt = try makeEngine(context: .searchPrompt)
        #expect(searchPrompt.handle(try token("?")) == .native(try token("?")))
        var pagePrompt = try makeEngine(context: .pagePrompt)
        // The page prompt is numeric-only by contract: '?' is rejected there, never help.
        #expect(pagePrompt.handle(try token("?")) == .ignored(.rejectedPagePromptText))

        // Navigation-only contract: in search results the key is not a help binding.
        var searchResults = try makeEngine(context: .searchResults)
        #expect(searchResults.handle(try token("?")) != .dispatch(KeyActionDispatch(actionID: .helpShow)))
    }
    @Test("history defaults and user remaps dispatch through the navigation trie")
    func historyDefaultsAndRemaps() throws {
        var defaults = try makeEngine()
        #expect(defaults.handle(try token("<C-o>")) == .dispatch(KeyActionDispatch(actionID: .historyBack)))
        #expect(defaults.handle(try token("<C-i>")) == .dispatch(KeyActionDispatch(actionID: .historyForward)))

        var bindings = BuiltInDefaults.keymap
        bindings[.historyBack] = [try sequence("x")]
        bindings[.historyForward] = [try sequence("y")]
        var remapped = try makeEngine(bindings: bindings)
        #expect(remapped.handle(try token("x")) == .dispatch(KeyActionDispatch(actionID: .historyBack)))
        #expect(remapped.handle(try token("y")) == .dispatch(KeyActionDispatch(actionID: .historyForward)))
        #expect(remapped.handle(try token("<C-o>")) == .ignored(.noBinding))
        #expect(remapped.handle(try token("<C-i>")) == .ignored(.noBinding))
    }

    @Test("history bindings are excluded outside navigation")
    func historyBindingsRespectNavigationOnlyScope() throws {
        for context in [InputContext.pagePrompt, .searchPrompt, .searchResults] {
            var engine = try makeEngine(context: context)
            #expect(engine.handle(try token("<C-o>")) == .ignored(.noBinding))
            #expect(engine.handle(try token("<C-i>")) == .ignored(.noBinding))
        }
    }

    @Test("control-I character token is distinct from Tab at the core level")
    func controlICharacterTokenIsDistinctFromTab() throws {
        let controlI = try token("<C-i>")
        let tab = try token("<Tab>")
        #expect(controlI == KeyToken(symbol: .character("i"), modifiers: [.control]))
        #expect(controlI != tab)
        #expect(controlI.description == "<C-i>")
        #expect(tab.description == "<Tab>")

        var engine = try makeEngine()
        #expect(engine.handle(controlI) == .dispatch(KeyActionDispatch(actionID: .historyForward)))
        #expect(engine.handle(tab) == .ignored(.noBinding))
    }

    @Test("history dispatch suppresses repeated key events")
    func historyRepeatSuppression() throws {
        var engine = try makeEngine()
        #expect(engine.handle(try token("<C-o>"), eventIsRepeat: true) == .ignored(.repeatSuppressed(.historyBack)))
        #expect(engine.handle(try token("<C-i>"), eventIsRepeat: true) == .ignored(.repeatSuppressed(.historyForward)))
    }

    private func makeEngine(
        context: InputContext = .navigation,
        bindings: [ActionID: [KeySequence]] = BuiltInDefaults.keymap,
        registry: ActionRegistry = .v1
    ) throws -> KeySequenceEngine {
        let result = try makeTrie(bindings: bindings, registry: registry)
        return KeySequenceEngine(
            trie: result.trie,
            context: context,
            prefixTimeoutMilliseconds: BuiltInDefaults.config.input.prefixTimeoutMilliseconds
        )
    }

    private func makeTrie(
        bindings: [ActionID: [KeySequence]] = BuiltInDefaults.keymap,
        registry: ActionRegistry = .v1
    ) throws -> (keymap: ValidatedKeymap, trie: KeySequenceTrie) {
        let policy = ActionBindingPolicy.evaluateEffective(bindings, registry: registry)
        #expect(policy.diagnostics.isEmpty)
        let keymap = try #require(policy.validatedKeymap)
        let trieReport = KeySequenceTrie.build(from: keymap, registry: registry)
        #expect(trieReport.diagnostics.isEmpty)
        return (keymap, try #require(trieReport.trie))
    }

    private func registryReplacing(
        _ actionID: ActionID,
        transform: (ActionDescriptor) -> ActionDescriptor
    ) -> ActionRegistry {
        ActionRegistry(
            descriptors: ActionRegistry.v1.descriptors.map { descriptor in
                descriptor.id == actionID ? transform(descriptor) : descriptor
            }
        )
    }

    private func token(_ source: String) throws -> KeyToken {
        try KeySequenceParser.parseSingleToken(source)
    }

    private func sequence(_ source: String) throws -> KeySequence {
        try KeySequenceParser.parse(source)
    }
}
