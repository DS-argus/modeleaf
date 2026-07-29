import AppKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("Keyboard help overlay integration")
@MainActor
struct HelpOverlayIntegrationTests {
    private func makeController() -> MainWindowController {
        MainWindowController(
            coordinator: PaneCoordinator(initialStore: ReaderSessionStore()),
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { _ in }
        )
    }

    @Test("help presents grouped bindings, fixed search keys, and compact default tab selection")
    func presentsSections() {
        let controller = makeController()
        defer { controller.close() }

        controller.presentHelp()
        let overlay = controller.rootView.helpOverlay

        #expect(!overlay.isHidden)
        #expect(overlay.visibleSectionsForTesting.contains("Application"))
        #expect(!overlay.visibleSectionsForTesting.contains("In overlays & prompts"))
        #expect(overlay.visibleEntriesForTesting.contains { $0.0 == "Cmd+1..9" && $0.1 == "Select tab 1-9" })
        #expect(overlay.visibleEntriesForTesting.contains { $0.0 == "Enter" && $0.1 == "Next search match" })
        #expect(overlay.visibleEntriesForTesting.contains { $0.0 == "Shift+Enter" && $0.1 == "Previous search match" })
        #expect(overlay.visibleEntriesForTesting.contains { $0.0 == "?" && $0.1 == "Keyboard Help" })
    }
    @Test("help rows use the validated rebinding")
    func usesReboundKeymap() throws {
        let validated = try #require(
            ConfigValidator.validate(SparseAppConfig(keymap: ["help.show": ["H"]])).validatedConfig
        )
        let controller = MainWindowController(
            coordinator: PaneCoordinator(initialStore: ReaderSessionStore()),
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { _ in },
            validatedConfig: validated
        )
        defer { controller.close() }

        controller.presentHelp()

        #expect(controller.rootView.helpOverlay.visibleEntriesForTesting.contains {
            $0.0 == "H" && $0.1 == "Keyboard Help"
        })
    }


    @Test("question mark and escape dismiss while other keys are ignored")
    func modalKeysDismissAndIgnoreOthers() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.presentHelp()

        #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "x"))))
        #expect(!controller.rootView.helpOverlay.isHidden)
        #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "?"))))
        #expect(controller.window?.firstResponder === controller.rootView.emptyState.openButton)
        #expect(controller.rootView.helpOverlay.isHidden)

        controller.presentHelp()
        #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "", keyCode: 53))))
        #expect(controller.rootView.helpOverlay.isHidden)
    }

    @Test("help replaces the command palette and remains bounded in a minimum window")
    func replacesPaletteAndScrollsWhenBounded() {
        let controller = makeController()
        defer { controller.close() }
        controller.window?.setContentSize(NSSize(width: 480, height: 360))
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        controller.presentCommandPalette()
        controller.presentHelp()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(controller.rootView.helpOverlayIsWithinContentBoundsForTesting)
        #expect(controller.rootView.commandPaletteOverlay.isHidden)
        #expect(!controller.rootView.helpOverlay.isHidden)
        #expect(controller.rootView.helpOverlay.isWithinBoundsForTesting)

        #expect(controller.rootView.helpOverlay.listRequiresScrollingForTesting)
    }
    @Test("help fits a standard window without scrolling")
    func fitsStandardWindow() {
        let controller = makeController()
        defer { controller.close() }
        controller.window?.setContentSize(NSSize(width: 1000, height: 700))
        controller.presentHelp()
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        #expect(!controller.rootView.helpOverlay.listRequiresScrollingForTesting)
        #expect(controller.rootView.helpOverlay.cardsHugContentForTesting)
        #expect(controller.rootView.helpOverlay.cardSpacingIsCompactForTesting)
    }

    @Test("rebound tab selection expands the compact default row")
    func expandsReboundTabSelection() throws {
        let validated = try #require(
            ConfigValidator.validate(SparseAppConfig(keymap: ["tab.select.1": ["x"]])).validatedConfig
        )
        let controller = MainWindowController(
            coordinator: PaneCoordinator(initialStore: ReaderSessionStore()),
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { _ in },
            validatedConfig: validated
        )
        defer { controller.close() }
        controller.presentHelp()

        let entries = controller.rootView.helpOverlay.visibleEntriesForTesting
        #expect(entries.contains { $0.0 == "x" && $0.1 == "Select Tab 1" })
        #expect(!entries.contains { $0.0 == "Cmd+1..9" && $0.1 == "Select tab 1-9" })
    }

    @Test("question mark remains native prompt text rather than presenting help")
    func questionMarkStaysNativeInPrompt() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.presentPrompt(PromptPresentation(kind: .search, text: "", validationMessage: nil))

        _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "?")))

        #expect(controller.rootView.helpOverlay.isHidden)
        #expect(controller.inputContextForTesting == .searchPrompt)
    }

}
