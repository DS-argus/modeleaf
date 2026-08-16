import AppKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp


@MainActor
final class HistoryAvailabilitySession: ReaderSessionPresenting, ReaderNavigationHistoryPresenting {
    let id = TabID()
    let title = "History.pdf"
    let sourceURL = URL(fileURLWithPath: "/tmp/History.pdf")
    var statusSnapshot: ReaderStatusSnapshot { .empty }
    func applyTheme(_ theme: AppKitTheme) {}
    let contentView: NSView = NSView()
    var canGoBack: Bool
    var canGoForward: Bool
    var navigationAvailabilityDetail: String
    let isNavigationHistoryHealthy: Bool
    var searchSnapshot = ReaderSearchSnapshot.empty
    private var presentationChangeHandler: (() -> Void)?

    func setPresentationChangeHandler(_ handler: (() -> Void)?) {
        presentationChangeHandler = handler
    }

    func publishPresentationChange() {
        presentationChangeHandler?()
    }

    init(canGoBack: Bool, canGoForward: Bool, healthy: Bool) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        isNavigationHistoryHealthy = healthy
        navigationAvailabilityDetail = healthy ? "History available" : "Navigation history unavailable"
    }

    func goBack() -> NavigationTransactionOutcome { canGoBack ? .verifiedLanding : .unavailable }
    func goForward() -> NavigationTransactionOutcome { canGoForward ? .verifiedLanding : .unavailable }
}
@Suite("Command palette integration")
@MainActor
struct CommandPaletteIntegrationTests {
    private func makeController(
        with store: ReaderSessionStore,
        _ executed: @escaping (ActionID) -> Void
    ) -> MainWindowController {
        MainWindowController(
            coordinator: PaneCoordinator(initialStore: store),
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: executed
        )
    }

    private func type(_ text: String, into controller: MainWindowController) throws {
        for character in text {
            _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: String(character))))
        }
    }

    @Test("opens, filters fuzzily, and dispatches the chosen command")
    func openFilterExecute() throws {
        var executed: [ActionID] = []
        let store = ReaderSessionStore()
        let controller = makeController(with: store) { executed.append($0) }
        defer { controller.close() }
        #expect(store.insert(StubReaderSession(id: TabID(), title: "A.pdf")))
        let overlay = controller.rootView.commandPaletteOverlay

        controller.presentCommandPalette()
        #expect(!overlay.isHidden)
        #expect(overlay.visibleCommandIDs.contains(.documentOpen))
        #expect(!overlay.visibleCommandIDs.contains(.paletteOpen)) // never lists itself
        #expect(overlay.keyHintForTesting == "⌃j / ⌃k  Move selection    ↩  Run    Esc  Close")
        #expect(overlay.keyHintIsWithinBoundsForTesting)
        #expect(overlay.visibleCommandsForTesting.first { $0.id == .viewFitWidth }?.shortcut == "w")

        try type("fitw", into: controller)
        #expect(overlay.currentQuery == "fitw")
        #expect(overlay.selectedCommandID == .viewFitWidth)

        _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36)))
        #expect(overlay.isHidden)
        #expect(executed == [.viewFitWidth])
    }
    @Test("mouse hover selects and click runs an enabled command")
    func pointerSelectsAndExecutes() throws {
        var executed: [ActionID] = []
        let store = ReaderSessionStore()
        let controller = makeController(with: store) { executed.append($0) }
        defer { controller.close() }
        #expect(store.insert(StubReaderSession(id: TabID(), title: "A.pdf")))
        let overlay = controller.rootView.commandPaletteOverlay
        controller.presentCommandPalette()

        let index = try #require(overlay.visibleCommandIDs.firstIndex(of: .viewFitWidth))
        overlay.pointerEnterRowForTesting(at: index)
        #expect(overlay.selectedCommandID == .viewFitWidth)
        overlay.pointerActivateRowForTesting(at: index)
        #expect(executed == [.viewFitWidth])
        #expect(overlay.isHidden)
    }

    @Test("escape cancels without dispatching")
    func escapeCancels() throws {
        var executed: [ActionID] = []
        let store = ReaderSessionStore()
        let controller = makeController(with: store) { executed.append($0) }
        defer { controller.close() }
        #expect(store.insert(StubReaderSession(id: TabID(), title: "A.pdf")))
        let overlay = controller.rootView.commandPaletteOverlay

        controller.presentCommandPalette()
        try type("open", into: controller)
        #expect(!overlay.isHidden)
        _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "", keyCode: 53)))
        #expect(overlay.isHidden)
        #expect(executed.isEmpty)
    }

    @Test("disabled commands are listed but inert")
    func disabledCommandsInert() throws {
        var executed: [ActionID] = []
        let store = ReaderSessionStore()
        let controller = makeController(with: store) { executed.append($0) }
        defer { controller.close() }
        // Single tab, single pane: "Next Tab" is listed but disabled.
        #expect(store.insert(StubReaderSession(id: TabID(), title: "Only.pdf")))
        let overlay = controller.rootView.commandPaletteOverlay

        controller.presentCommandPalette()
        try type("nexttab", into: controller)
        #expect(overlay.selectedCommandID == .tabNext)

        _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36)))
        #expect(!overlay.isHidden)     // inert commit keeps the palette open
        #expect(overlay.pointerEnabledRowsForTesting == [false])
        overlay.pointerActivateRowForTesting(at: 0)
        #expect(!overlay.isHidden)
        #expect(executed.isEmpty)
    }

    @Test("history palette rows report exact unavailable reasons and remain inert")
    func historyRowsUnavailableAndInert() throws {
        var executed: [ActionID] = []
        let controller = makeController(with: ReaderSessionStore()) { executed.append($0) }
        defer { controller.close() }
        let overlay = controller.rootView.commandPaletteOverlay

        controller.presentCommandPalette()
        let back = try #require(overlay.visibleCommandsForTesting.first { $0.id == .historyBack })
        let forward = try #require(overlay.visibleCommandsForTesting.first { $0.id == .historyForward })
        #expect(back.disabledReason == "No previous location")
        #expect(forward.disabledReason == "No next location")
        try type("back", into: controller)
        _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36)))
        #expect(!overlay.isHidden)
        #expect(executed.isEmpty)
    }

    @Test("palette history rows use saved non-navigation contexts and remain inert")
    func historyRowsRespectSavedPromptAndSearchContexts() throws {
        for presentation in [
            PromptPresentation(kind: .page, text: "", validationMessage: nil),
            PromptPresentation(kind: .search, text: "", validationMessage: nil),
        ] {
            var executed: [ActionID] = []
            let controller = makeController(with: ReaderSessionStore()) { executed.append($0) }
            defer { controller.close() }
            controller.presentPrompt(presentation)
            controller.presentCommandPalette()
            let overlay = controller.rootView.commandPaletteOverlay
            let back = try #require(overlay.visibleCommandsForTesting.first { $0.id == .historyBack })
            #expect(back.disabledReason == "Available in Navigation only")
            try type("back", into: controller)
            _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36)))
            #expect(!overlay.isHidden)
            #expect(executed.isEmpty)
            _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "", keyCode: 53)))
            #expect(controller.inputContextForTesting == (presentation.kind == .page ? .pagePrompt : .searchPrompt))
        }
    }

    @Test("history palette rows report empty and unhealthy reasons exactly")
    func historyRowsReportDirectionAndHealth() throws {
        for (session, action, reason) in [
            (HistoryAvailabilitySession(canGoBack: false, canGoForward: true, healthy: true), ActionID.historyBack, "No previous location"),
            (HistoryAvailabilitySession(canGoBack: true, canGoForward: false, healthy: true), ActionID.historyForward, "No next location"),
            (HistoryAvailabilitySession(canGoBack: true, canGoForward: true, healthy: false), ActionID.historyBack, "Navigation history unavailable"),
        ] {
            let store = ReaderSessionStore()
            #expect(store.insert(session))
            let controller = makeController(with: store) { _ in }
            defer { controller.close() }
            controller.presentCommandPalette()
            let row = try #require(controller.rootView.commandPaletteOverlay.visibleCommandsForTesting.first { $0.id == action })
            #expect(row.disabledReason == reason)
    }
        }

    @Test("remapped history is consumed over saved search and prompt contexts")
    func remappedHistoryStaysModalAcrossSavedContexts() throws {
        let validated = try #require(ConfigValidator.validate(SparseAppConfig(
            keymap: [ActionID.historyBack.rawValue: ["x"]]
        )).validatedConfig)
        for context in [InputContext.pagePrompt, .searchPrompt] {
            var dispatched: [ActionID] = []
            let controller = MainWindowController(
                coordinator: PaneCoordinator(initialStore: ReaderSessionStore()),
                theme: AppKitTheme(themeID: .tokyoNight),
                actionHandler: { dispatched.append($0) },
                validatedConfig: validated
            )
            defer { controller.close() }
            controller.presentPrompt(PromptPresentation(kind: context == .pagePrompt ? .page : .search, text: "", validationMessage: nil))
            controller.presentCommandPalette()
            #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "x"))))
            #expect(dispatched.isEmpty)
            #expect(!controller.rootView.commandPaletteOverlay.isHidden)
            #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "", keyCode: 53))))
            #expect(controller.inputContextForTesting == context)
        }

        var dispatched: [ActionID] = []
        let store = ReaderSessionStore()
        let session = HistoryAvailabilitySession(canGoBack: true, canGoForward: true, healthy: true)
        session.searchSnapshot = ReaderSearchSnapshot(
            query: "needle",
            matchCount: 1,
            activeMatchIndex: 0,
            isRunning: false,
            emptyResult: nil
        )
        #expect(store.insert(session))
        let controller = MainWindowController(
            coordinator: PaneCoordinator(initialStore: store),
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { dispatched.append($0) },
            validatedConfig: validated
        )
        defer { controller.close() }
        #expect(controller.inputContextForTesting == .searchResults)
        controller.presentCommandPalette()
        #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "x"))))
        #expect(dispatched.isEmpty)
        _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "", keyCode: 53)))
        #expect(controller.inputContextForTesting == .searchResults)
    }

    @Test("history actions are consumed while command palette owns routing")
    func historyActionsStayModal() throws {
        var executed: [ActionID] = []
        let controller = makeController(with: ReaderSessionStore()) { executed.append($0) }
        defer { controller.close() }
        controller.presentCommandPalette()
        #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(
            characters: "o", charactersIgnoringModifiers: "o", modifiers: [.control]
        ))))
        #expect(executed.isEmpty)
        #expect(!controller.rootView.commandPaletteOverlay.isHidden)
        #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "", keyCode: 53))))
        #expect(controller.rootView.commandPaletteOverlay.isHidden)
    }

    @Test("Ctrl+j and Ctrl+k navigate while Ctrl+n and Ctrl+p do nothing")
    func controlNavigationKeys() throws {
        let controller = makeController(with: ReaderSessionStore()) { _ in }
        defer { controller.close() }
        let overlay = controller.rootView.commandPaletteOverlay
        controller.presentCommandPalette()
        let initial = try #require(overlay.selectedCommandID)

        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "j", modifiers: [.control]))))
        let afterJ = try #require(overlay.selectedCommandID)
        #expect(afterJ != initial)
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "k", modifiers: [.control]))))
        #expect(overlay.selectedCommandID == initial)

        #expect(!overlay.handleKeyDown(try #require(makeKeyEvent(characters: "n", modifiers: [.control]))))
        #expect(overlay.selectedCommandID == initial)
        #expect(!overlay.handleKeyDown(try #require(makeKeyEvent(characters: "p", modifiers: [.control]))))
        #expect(overlay.selectedCommandID == initial)
    }

    @Test("arrow keys navigate the palette")
    func arrowNavigationKeys() throws {
        let controller = makeController(with: ReaderSessionStore()) { _ in }
        defer { controller.close() }
        let overlay = controller.rootView.commandPaletteOverlay
        controller.presentCommandPalette()
        let initial = try #require(overlay.selectedCommandID)

        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "", keyCode: 125))))
        #expect(overlay.selectedCommandID != initial)
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "", keyCode: 126))))
        #expect(overlay.selectedCommandID == initial)
    }

    @Test("scrolling reaches and executes commands after the twelve-row viewport")
    func scrollsToAndExecutesLastCommand() throws {
        var executed: [ActionID] = []
        let controller = makeController(with: ReaderSessionStore()) { executed.append($0) }
        defer { controller.close() }
        controller.window?.setContentSize(NSSize(width: 480, height: 360))
        let overlay = controller.rootView.commandPaletteOverlay
        let commands = Array(ActionID.allCases.prefix(13)).enumerated().map { index, id in
            PaletteCommand(id: id, title: "Command \(index)")
        }
        overlay.onCommit = { executed.append($0) }
        overlay.present(commands: commands)
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        #expect(overlay.visibleCommandIDs == commands.map(\.id))
        #expect(overlay.listRequiresScrollingForTesting)
        for _ in commands.indices.dropFirst() {
            #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "j", modifiers: [.control]))))
        }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(overlay.selectedCommandID == commands.last?.id)
        #expect(overlay.selectedRowIsVisibleForTesting)
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "\r", keyCode: 36))))
        #expect(executed == [try #require(commands.last?.id)])
    }

    @Test("empty queries group enabled commands first without changing group order")
    func emptyQueryGroupsEnabledCommandsFirst() {
        let overlay = CommandPaletteOverlayView()
        let commands: [PaletteCommand] = [
            PaletteCommand(id: .documentOpen, title: "Disabled first", isEnabled: false, disabledReason: "Unavailable"),
            PaletteCommand(id: .documentClose, title: "Enabled first"),
            PaletteCommand(id: .appQuit, title: "Disabled second", isEnabled: false, disabledReason: "Unavailable"),
            PaletteCommand(id: .appNew, title: "Enabled second"),
        ]

        overlay.present(commands: commands)
        #expect(overlay.visibleCommandIDs == [.documentClose, .appNew, .documentOpen, .appQuit])
    }

    @Test("fuzzy queries retain fuzzy score ordering")
    func fuzzyQueryRetainsScoreOrdering() throws {
        let overlay = CommandPaletteOverlayView()
        let commands: [PaletteCommand] = [
            PaletteCommand(id: .documentOpen, title: "Open Document", isEnabled: false, disabledReason: "Unavailable"),
            PaletteCommand(id: .documentClose, title: "Open", isEnabled: true),
            PaletteCommand(id: .appQuit, title: "Options", isEnabled: false, disabledReason: "Unavailable"),
        ]
        overlay.present(commands: commands)
        _ = overlay.handleKeyDown(try #require(makeKeyEvent(characters: "o")))
        _ = overlay.handleKeyDown(try #require(makeKeyEvent(characters: "p")))

        #expect(overlay.visibleCommandIDs == CommandPaletteFilter.rank(commands, query: "op").map(\.id))
    }
}
