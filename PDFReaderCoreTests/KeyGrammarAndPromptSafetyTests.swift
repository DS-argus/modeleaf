import Foundation
import PDFReaderCore
import Testing

@Suite("Key grammar and prompt safety")
struct KeyGrammarAndPromptSafetyTests {
    @Test("U-KEY-01 logical character normalization")
    func logicalCharacters() throws {
        let sequence = try KeySequenceParser.parse("jG한é")
        #expect(sequence.tokens.count == 4)
        #expect(sequence.description == "jG한é")
        #expect(sequence.tokens[0] == KeyToken(symbol: .character("j")))
        #expect(sequence.tokens[1] == KeyToken(symbol: .character("G")))
        #expect(try KeySequenceParser.parse("<S-D-O>").description == "<D-S-o>")
        #expect(try KeySequenceParser.parse("<Backtab>").description == "<S-Tab>")
    }

    @Test("U-KEY-02 built-in and modifier grammar round-trips")
    func builtInGrammarRoundTrips() throws {
        let expected = [
            "<Esc>", "<CR>", "<S-CR>", "<D-o>", "<D-w>", "<D-q>", "<D-F12>",
            "<BS>", "<Del>", "<Tab>", "<Left>", "<Right>", "<Up>", "<Down>",
            "<Home>", "<End>", "<PageUp>", "<PageDown>", "<D-A-S-q>",
        ]
        for source in expected {
            #expect(try KeySequenceParser.parse(source).description == source)
        }
        for sequences in BuiltInDefaults.keymap.values {
            for sequence in sequences {
                #expect(try KeySequenceParser.parse(sequence.description) == sequence)
            }
        }
        for source in PromptNativeReservationV1.shared.normalizedEntries
            + SystemKeyReservationV1.shared.normalizedEntries
        {
            #expect(try KeySequenceParser.parseSingleToken(source).description == source)
        }
    }

    @Test("U-KEY-03 multi-key sequences preserve order")
    func multiKeySequences() throws {
        #expect(try KeySequenceParser.parse("gt").tokens.map(\.description) == ["g", "t"])
        #expect(try KeySequenceParser.parse("gT").tokens.map(\.description) == ["g", "T"])
        #expect(try KeySequenceParser.parse("gg").tokens.map(\.description) == ["g", "g"])
    }

    @Test(
        "U-KEY-04 invalid grammar is rejected",
        arguments: ["", "<", "<>", "g>", "<Fn>", "<Globe>", "<MediaPlay>", "<Power>", "<F25>", "<D-D-o>", "<Hyper-o>", " "]
    )
    func invalidGrammar(_ source: String) {
        #expect(throws: KeySequenceParseError.self) {
            try KeySequenceParser.parse(source)
        }
    }

    @Test("U-KEY-05 repeat metadata follows descriptors")
    func repeatMetadata() throws {
        let scroll = try #require(ActionRegistry.v1.descriptor(for: .scrollDown))
        let close = try #require(ActionRegistry.v1.descriptor(for: .documentClose))
        #expect(ActionBindingPolicy.shouldDispatch(eventIsRepeat: true, action: scroll))
        #expect(!ActionBindingPolicy.shouldDispatch(eventIsRepeat: true, action: close))
        #expect(ActionBindingPolicy.shouldDispatch(eventIsRepeat: false, action: close))
    }

    @Test("U-KEY-06 every native reservation rejects prompt-active globals")
    func nativeReservationsRejectGlobals() throws {
        let global = try #require(ActionRegistry.v1.descriptor(for: .documentOpen))
        for token in PromptNativeReservationV1.shared.tokens {
            let decision = PromptSafeBindingPredicate.evaluate(
                action: global,
                activeContexts: global.activeContexts,
                sequence: KeySequence(tokens: [token])
            )
            #expect(!decision.isValid, "expected native reservation \(token) to reject")
        }
    }

    @Test("U-KEY-06 every system reservation rejects prompt-active globals")
    func systemReservationsRejectGlobals() throws {
        let global = try #require(ActionRegistry.v1.descriptor(for: .appQuit))
        for token in SystemKeyReservationV1.shared.tokens {
            let decision = PromptSafeBindingPredicate.evaluate(
                action: global,
                activeContexts: global.activeContexts,
                sequence: KeySequence(tokens: [token])
            )
            #expect(!decision.isValid, "expected system reservation \(token) to reject")
        }
    }

    @Test("U-KEY-06 action-aware prompt decision table")
    func promptDecisionTable() throws {
        let global = try #require(ActionRegistry.v1.descriptor(for: .documentOpen))
        let lifecycle = try #require(ActionRegistry.v1.descriptor(for: .promptCommit))
        let nonPrompt = try #require(ActionRegistry.v1.descriptor(for: .pageNext))

        #expect(decision(global, .empty).isValid)
        #expect(decision(global, try sequence("<D-o>")).isValid)
        #expect(decision(global, try sequence("<D-q>")).isValid)
        #expect(decision(global, try sequence("<D-F12>")).isValid)
        #expect(decision(global, try sequence("<F12>")).isValid)

        for source in ["o", "go", "1", "<Space>", "<C-o>", "<A-o>", "<S-o>", "<C-F12>", "<A-F12>", "<S-F12>"] {
            #expect(!decision(global, try sequence(source)).isValid, "expected \(source) to reject")
        }
        #expect(!decision(global, KeySequence(tokens: [.deadKey])).isValid)
        #expect(!decision(global, KeySequence(tokens: [.imeComposition])).isValid)

        #expect(decision(lifecycle, try sequence("<CR>")).isValid)
        #expect(decision(lifecycle, try sequence("<Esc>")).isValid)
        #expect(!decision(global, try sequence("<CR>")).isValid)
        #expect(!decision(global, try sequence("<Esc>")).isValid)

        #expect(PromptSafeBindingPredicate.evaluate(
            action: nonPrompt,
            activeContexts: nonPrompt.activeContexts,
            sequence: try sequence("j")
        ).isValid)
        #expect(PromptSafeBindingPredicate.evaluate(
            action: global,
            activeContexts: [.navigation],
            sequence: try sequence("o")
        ).isValid)
    }

    @Test("pane descriptors exclude all prompt contexts while prompt-scoped multi-token variants are rejected")
    func panePromptSafetyBoundary() throws {
        let paneActions: [ActionID] = [
            .paneSplitRight, .paneSplitDown, .paneFocusLeft, .paneFocusDown,
            .paneFocusUp, .paneFocusRight, .paneUnsplit,
        ]
        let promptContexts: Set<InputContext> = [.pagePrompt, .searchPrompt]
        for actionID in paneActions {
            let descriptor = try #require(ActionRegistry.v1.descriptor(for: actionID))
            // Pane actions work while browsing search results (user review 1-6)
            // but remain excluded from every prompt (typing) context.
            #expect(descriptor.activeContexts == [.navigation, .searchResults])
            for context in promptContexts {
                #expect(PromptSafeBindingPredicate.evaluate(
                    action: descriptor,
                    activeContexts: [context],
                    sequence: try KeySequenceParser.parse("<C-Space>|")
                ) == .valid)
            }
        }

        let synthetic = ActionDescriptor(
            id: .paneSplitRight,
            title: "Synthetic prompt pane action",
            scope: .contexts([.pagePrompt]),
            repeatPolicy: .suppressed
        )
        let decision = PromptSafeBindingPredicate.evaluate(
            action: synthetic,
            activeContexts: [.pagePrompt],
            sequence: try KeySequenceParser.parse("<C-Space>|")
        )
        #expect(decision.failure?.violation == .multipleTokens)
    }

    @Test("Reservation tables match their independent v1 snapshots")
    func reservationSnapshots() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let promptSnapshot = try String(
            contentsOf: root.appendingPathComponent("Snapshots/PromptNativeReservationV1.txt"),
            encoding: .utf8
        ).split(separator: "\n").map(String.init)
        let systemSnapshot = try String(
            contentsOf: root.appendingPathComponent("Snapshots/SystemKeyReservationV1.txt"),
            encoding: .utf8
        ).split(separator: "\n").map(String.init)

        #expect(promptSnapshot.count == 88)
        #expect(systemSnapshot.count == 18)
        #expect(promptSnapshot == PromptNativeReservationV1.shared.normalizedEntries)
        #expect(systemSnapshot == SystemKeyReservationV1.shared.normalizedEntries)
    }

    private func sequence(_ source: String) throws -> KeySequence {
        try KeySequenceParser.parse(source)
    }

    private func decision(_ action: ActionDescriptor, _ sequence: KeySequence) -> PromptSafetyDecision {
        PromptSafeBindingPredicate.evaluate(
            action: action,
            activeContexts: action.activeContexts,
            sequence: sequence
        )
    }
}
