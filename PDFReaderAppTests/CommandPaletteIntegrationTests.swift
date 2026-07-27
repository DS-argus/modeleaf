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
}
