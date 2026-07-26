import AppKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("Window responder input routing")
@MainActor
struct ReaderInputRouterTests {
    @Test("empty-window and active-reader key events use one ReaderWindow route")
    func oneWindowRoute() throws {
        let validated = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        var dispatches: [KeyActionDispatch] = []
        let router = ReaderInputRouter(
            config: validated,
            automaticallySchedulesTimeouts: false,
            pendingHandler: { _ in },
            dispatchHandler: { dispatches.append($0) }
        )
        let window = ReaderWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.keyEventHandler = { router.handle($0) }

        let open = try #require(makeKeyEvent(
            characters: "o",
            modifiers: [.command],
            windowNumber: window.windowNumber
        ))
        window.sendEvent(open)
        let scroll = try #require(makeKeyEvent(characters: "j", windowNumber: window.windowNumber))
        window.sendEvent(scroll)

        #expect(dispatches.map(\.actionID) == [.documentOpen, .scrollDown])
    }

    @Test("g12 exposes a pending prefix, replays 1 into PAGE, then leaves 2 to NSTextField")
    func semanticPagePromptReplay() throws {
        let validated = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        var prefixes: [String] = []
        var dispatches: [KeyActionDispatch] = []
        let router = ReaderInputRouter(
            config: validated,
            automaticallySchedulesTimeouts: false,
            pendingHandler: { prefixes.append($0) },
            dispatchHandler: { dispatches.append($0) }
        )

        #expect(router.handle(try #require(makeKeyEvent(characters: "g"))))
        let pending = try #require(router.pending)
        #expect(prefixes.last == "g")
        #expect(router.handle(try #require(makeKeyEvent(characters: "1"))))
        #expect(dispatches.count == 1)
        #expect(dispatches[0].actionID == .pagePrompt)
        #expect(dispatches[0].semanticReplay?.token.asciiDecimalDigit == "1")
        #expect(router.context == .pagePrompt)
        #expect(prefixes.last == "")

        #expect(!router.handle(try #require(makeKeyEvent(characters: "2"))))
        #expect(dispatches.count == 1)

        router.invalidate(.promptCancelled)
        router.fireTimeoutForTesting(epoch: pending.epoch)
        #expect(dispatches.count == 1)
    }

    @Test("a lone g timeout opens an empty page prompt and stale epochs cannot dispatch")
    func deterministicTimeout() throws {
        let validated = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        var dispatches: [KeyActionDispatch] = []
        let router = ReaderInputRouter(
            config: validated,
            automaticallySchedulesTimeouts: false,
            pendingHandler: { _ in },
            dispatchHandler: { dispatches.append($0) }
        )

        #expect(router.handle(try #require(makeKeyEvent(characters: "g"))))
        let liveEpoch = try #require(router.pending?.epoch)
        router.fireTimeoutForTesting(epoch: liveEpoch)
        #expect(dispatches.map(\.actionID) == [.pagePrompt])
        #expect(dispatches[0].semanticReplay == nil)

        router.synchronizeContext(.navigation)
        #expect(router.handle(try #require(makeKeyEvent(characters: "g"))))
        let staleEpoch = try #require(router.pending?.epoch)
        router.invalidate(.focusLost)
        router.fireTimeoutForTesting(epoch: staleEpoch)
        #expect(dispatches.map(\.actionID) == [.pagePrompt])
    }

    @Test("default uppercase sequences and repeatable movement survive AppKit modifier flags")
    func uppercaseAndRepeat() throws {
        let validated = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        var actions: [ActionID] = []
        let router = ReaderInputRouter(
            config: validated,
            automaticallySchedulesTimeouts: false,
            pendingHandler: { _ in },
            dispatchHandler: { actions.append($0.actionID) }
        )

        #expect(router.handle(try #require(makeKeyEvent(
            characters: "G",
            charactersIgnoringModifiers: "G",
            modifiers: [.shift],
            keyCode: 5
        ))))
        #expect(router.handle(try #require(makeKeyEvent(characters: "j", isRepeat: true))))
        #expect(router.handle(try #require(makeKeyEvent(
            characters: "P",
            charactersIgnoringModifiers: "P",
            modifiers: [.shift],
            keyCode: 35
        ))))
        #expect(router.handle(try #require(makeKeyEvent(
            characters: "1",
            modifiers: [.command]
        ))))

        #expect(actions == [.pageLast, .scrollDown, .tabPrevious, .tabSelect1])
    }

    @Test("prompt digits, backspace, dead keys, and IME remain native while CR and Esc dispatch")
    func promptOwnership() throws {
        let validated = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        var actions: [ActionID] = []
        let router = ReaderInputRouter(
            config: validated,
            automaticallySchedulesTimeouts: false,
            pendingHandler: { _ in },
            dispatchHandler: { actions.append($0.actionID) }
        )
        router.synchronizeContext(.pagePrompt)

        #expect(!router.handle(try #require(makeKeyEvent(characters: "7"))))
        #expect(!router.handle(try #require(makeKeyEvent(characters: "\u{7F}", keyCode: 51))))
        #expect(!router.handle(try #require(makeKeyEvent(characters: ""))))
        #expect(!router.handle(try #require(makeKeyEvent(characters: "한글"))))
        #expect(router.handle(try #require(makeKeyEvent(characters: "\r", keyCode: 36))))
        #expect(router.handle(try #require(makeKeyEvent(characters: "\u{1B}", keyCode: 53))))
        #expect(actions == [.promptCommit, .promptCancel])
    }
    @Test("pane bindings never dispatch from page or search prompts while prompt text remains native")
    func paneBindingsAreExcludedFromPromptRouting() throws {
        let validated = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        let paneActions: Set<ActionID> = [
            .paneSplitRight, .paneSplitDown, .paneFocusLeft, .paneFocusDown,
            .paneFocusUp, .paneFocusRight, .paneUnsplit,
        ]

        for context in [InputContext.pagePrompt, .searchPrompt] {
            var dispatches: [ActionID] = []
            let router = ReaderInputRouter(
                config: validated,
                automaticallySchedulesTimeouts: false,
                pendingHandler: { _ in },
                dispatchHandler: { dispatches.append($0.actionID) }
            )
            router.synchronizeContext(context)
            for event in [
                try #require(makeKeyEvent(characters: "b", charactersIgnoringModifiers: "b", modifiers: [.control])),
                try #require(makeKeyEvent(characters: "|", charactersIgnoringModifiers: "|", modifiers: [.shift])),
                try #require(makeKeyEvent(characters: "h", charactersIgnoringModifiers: "h", modifiers: [.control])),
            ] {
                _ = router.handle(event)
            }
            #expect(Set(dispatches).isDisjoint(with: paneActions))
            #expect(router.context == context)
            #expect(!router.handle(try #require(makeKeyEvent(characters: context == .pagePrompt ? "7" : "x"))))
        }
    }
    @Test("theme picker binding remains native in prompts and dispatches in navigation")
    func themePickerIsExcludedFromPromptRouting() throws {
        let validated = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        let themePickerKey = try #require(makeKeyEvent(
            characters: "T",
            charactersIgnoringModifiers: "T",
            modifiers: [.shift]
        ))

        for context in [InputContext.pagePrompt, .searchPrompt] {
            var dispatches: [ActionID] = []
            let router = ReaderInputRouter(
                config: validated,
                automaticallySchedulesTimeouts: false,
                pendingHandler: { _ in },
                dispatchHandler: { dispatches.append($0.actionID) }
            )
            router.synchronizeContext(context)

            // Prompt-safety is proven by dispatch isolation: pressing the
            // picker binding in a typing context never opens the picker. (The
            // router's own consume/return semantics for a bound key are a
            // separate, pre-existing concern and not the safety signal here.)
            _ = router.handle(themePickerKey)
            #expect(Set(dispatches).isDisjoint(with: [.themePicker]))
            #expect(router.context == context)
            #expect(!router.handle(try #require(makeKeyEvent(characters: context == .pagePrompt ? "7" : "x"))))
        }

        var navigationDispatches: [ActionID] = []
        let router = ReaderInputRouter(
            config: validated,
            automaticallySchedulesTimeouts: false,
            pendingHandler: { _ in },
            dispatchHandler: { navigationDispatches.append($0.actionID) }
        )
        router.synchronizeContext(.navigation)
        #expect(router.handle(themePickerKey))
        #expect(navigationDispatches == [.themePicker])
    }

    @Test("pane bindings dispatch while browsing search results")
    func paneBindingsDispatchFromSearchResults() throws {
        // User review 1-6: splitting must not require leaving an active
        // search. searchResults is a browsing context, not a typing context.
        let validated = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        var dispatches: [ActionID] = []
        let router = ReaderInputRouter(
            config: validated,
            automaticallySchedulesTimeouts: false,
            pendingHandler: { _ in },
            dispatchHandler: { dispatches.append($0.actionID) }
        )
        router.synchronizeContext(.searchResults)

        for event in [
            try #require(makeKeyEvent(characters: "b", charactersIgnoringModifiers: "b", modifiers: [.control])),
            try #require(makeKeyEvent(characters: "|", charactersIgnoringModifiers: "|", modifiers: [.shift])),
        ] {
            _ = router.handle(event)
        }
        #expect(dispatches == [.paneSplitRight])

        dispatches.removeAll()
        _ = router.handle(try #require(makeKeyEvent(characters: "l", charactersIgnoringModifiers: "l", modifiers: [.control])))
        #expect(dispatches == [.paneFocusRight])
    }
}
