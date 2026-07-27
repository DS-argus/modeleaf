import PDFReaderCore
import Testing

@Suite("Command palette core: fuzzy ranking and availability")
struct CommandPaletteTests {
    private func command(_ id: ActionID, _ title: String, enabled: Bool = true) -> PaletteCommand {
        PaletteCommand(id: id, title: title, isEnabled: enabled)
    }

    @Test("empty query keeps every command in original order")
    func emptyQueryIsIdentity() {
        let commands = [
            command(.documentOpen, "Open PDF…"),
            command(.pageNext, "Next Page"),
            command(.paneSplitRight, "Split Right"),
        ]
        #expect(CommandPaletteFilter.rank(commands, query: "").map(\.id) == commands.map(\.id))
        #expect(CommandPaletteFilter.rank(commands, query: "   ").map(\.id) == commands.map(\.id))
    }

    @Test("non-subsequence queries are dropped; subsequence survives")
    func subsequenceFiltering() {
        #expect(CommandPaletteFilter.fuzzyScore(query: "op", candidate: "Open PDF…") != nil)
        #expect(CommandPaletteFilter.fuzzyScore(query: "pz", candidate: "Open PDF…") == nil)
        // case-insensitive
        #expect(CommandPaletteFilter.fuzzyScore(query: "OPEN", candidate: "Open PDF…") != nil)
    }

    @Test("word-boundary and consecutive matches outrank scattered ones")
    func rankingPrefersBoundaries() {
        let commands = [
            command(.paneFocusLeft, "Focus Left Pane"),
            command(.paneSplitRight, "Split Right"),
            command(.searchPrompt, "Find…"),
        ]
        // "sr" hits the start of Split + start of Right (two word boundaries),
        // and only appears scattered inside "Focus...". Split Right must rank first.
        let ranked = CommandPaletteFilter.rank(commands, query: "sr")
        #expect(ranked.first?.id == .paneSplitRight)

        // A clean prefix beats a mid-word subsequence of the same query.
        #expect(
            CommandPaletteFilter.fuzzyScore(query: "fin", candidate: "Find…")!
                > CommandPaletteFilter.fuzzyScore(query: "fin", candidate: "Fit Width in")!
        )
    }

    @Test("equal scores keep original order (stable)")
    func stableTieBreak() {
        let commands = [
            command(.tabSelect1, "Select Tab 1"),
            command(.tabSelect2, "Select Tab 2"),
        ]
        let ranked = CommandPaletteFilter.rank(commands, query: "select tab")
        #expect(ranked.map(\.id) == [.tabSelect1, .tabSelect2])
    }

    @Test("global lifecycle commands stay enabled with no open document")
    func lifecycleAlwaysEnabled() {
        let empty = PaletteContextState(hasActiveDocument: false, paneCount: 0, tabCount: 0, inSearchResults: false)
        for id in [ActionID.documentOpen, .appNew, .appQuit] {
            #expect(PaletteAvailability.evaluate(id, state: empty).enabled)
        }
        // Everything else is disabled until a document is open.
        let disabled = PaletteAvailability.evaluate(.pageNext, state: empty)
        #expect(!disabled.enabled)
        #expect(disabled.reason == "Open a PDF first")
    }

    @Test("tab, pane, split, and search availability track runtime state")
    func stateDependentAvailability() {
        let solo = PaletteContextState(hasActiveDocument: true, paneCount: 1, tabCount: 1, inSearchResults: false)
        #expect(!PaletteAvailability.evaluate(.tabNext, state: solo).enabled)
        #expect(!PaletteAvailability.evaluate(.paneFocusLeft, state: solo).enabled)
        #expect(!PaletteAvailability.evaluate(.paneUnsplit, state: solo).enabled)
        #expect(PaletteAvailability.evaluate(.paneSplitRight, state: solo).enabled)
        #expect(!PaletteAvailability.evaluate(.searchCancel, state: solo).enabled)
        #expect(PaletteAvailability.evaluate(.pageNext, state: solo).enabled)
        #expect(!PaletteAvailability.evaluate(.tabSelect3, state: solo).enabled)

        let rich = PaletteContextState(hasActiveDocument: true, paneCount: 4, tabCount: 3, inSearchResults: true)
        #expect(PaletteAvailability.evaluate(.tabNext, state: rich).enabled)
        #expect(PaletteAvailability.evaluate(.paneFocusLeft, state: rich).enabled)
        #expect(!PaletteAvailability.evaluate(.paneSplitRight, state: rich).enabled) // already at 4
        #expect(PaletteAvailability.evaluate(.searchCancel, state: rich).enabled)
        #expect(PaletteAvailability.evaluate(.tabSelect3, state: rich).enabled)
        #expect(!PaletteAvailability.evaluate(.tabSelect4, state: rich).enabled) // only 3 tabs
    }
}
