import AppKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

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

        try type("fitw", into: controller)
        #expect(overlay.currentQuery == "fitw")
        #expect(overlay.selectedCommandID == .viewFitWidth)

        _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36)))
        #expect(overlay.isHidden)
        #expect(executed == [.viewFitWidth])
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
        #expect(executed.isEmpty)
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
