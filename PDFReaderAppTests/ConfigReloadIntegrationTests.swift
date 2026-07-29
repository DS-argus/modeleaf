import AppKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("Configuration reload integration")
@MainActor
struct ConfigReloadIntegrationTests {
    @Test("a valid generation replaces routing, displayed bindings, menu shortcuts, and navigation without changing reader state")
    func validGenerationReplacesRuntimeSurfaces() throws {
        try withTemporaryDirectory { directory in
            let configURL = directory.appendingPathComponent("config.toml")
            let store = ReaderSessionStore()
            let first = ReloadRecordingSession(title: "first.pdf")
            let second = ReloadRecordingSession(title: "second.pdf")
            #expect(store.insert(first))
            #expect(store.insert(second))
            let controller = makeController(configURL: configURL, store: store)
            #expect(store.activate(first.id))
            controller.start()
            defer { controller.mainWindowController.close() }
            controller.applyTheme(.dracula, persist: false)
            controller.dispatch(.paneSplitRight)
            let layoutBefore = controller.coordinator.snapshot.layout
            let tabsBefore = controller.coordinator.snapshot.tabs
            let activeBefore = controller.coordinator.snapshot.activeID

            try writeValidConfig(to: configURL)
            controller.reloadConfig()
            #expect(controller.mainWindowController.rootView.statusBar.presentation.detail == "Config reloaded")

            #expect(controller.mainWindowController.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "z"))))
            #expect(first.zoomFactors == [1.5])
            controller.mainWindowController.presentCommandPalette()
            #expect(controller.mainWindowController.rootView.commandPaletteOverlay.visibleCommandsForTesting.contains {
                $0.id == .viewZoomIn && $0.shortcut == "z"
            })
            controller.mainWindowController.dismissAllTransientOverlays()
            controller.mainWindowController.presentHelp()
            #expect(controller.mainWindowController.rootView.helpOverlay.visibleEntriesForTesting.contains { $0.0 == "z" && $0.1 == "Zoom In" })
            controller.mainWindowController.dismissAllTransientOverlays()
            #expect(menuItem(identifier: "menu.file.open", in: NSApp.mainMenu)?.keyEquivalent == "e")
            #expect(menuItem(identifier: "menu.file.open", in: NSApp.mainMenu)?.keyEquivalentModifierMask == [.command])

            controller.dispatch(.scrollDown)
            controller.dispatch(.scrollLargeDown)
            controller.dispatch(.viewZoomIn)
            #expect(first.verticalPointScrolls == [63])
            #expect(first.viewportScrolls == [0.35])
            #expect(first.zoomFactors == [1.5, 1.5])
            #expect(controller.coordinator.snapshot.layout == layoutBefore)
            #expect(controller.coordinator.snapshot.tabs == tabsBefore)
            #expect(controller.coordinator.snapshot.activeID == activeBefore)
            #expect(controller.currentThemeID == .dracula)
        }
    }

    @Test("a rejected generation remains pinned through reader activity and only a successful reload clears it")
    func rejectedGenerationPreservesPriorConfigAndPinnedDiagnostic() throws {
        try withTemporaryDirectory { directory in
            let configURL = directory.appendingPathComponent("config.toml")
            try writeValidConfig(to: configURL)
            let store = ReaderSessionStore()
            let first = ReloadRecordingSession(title: "first.pdf")
            let second = ReloadRecordingSession(title: "second.pdf")
            #expect(store.insert(first))
            #expect(store.activate(first.id))
            #expect(store.insert(second))
            let controller = makeController(configURL: configURL, store: store)
            #expect(store.activate(first.id))
            controller.start()
            defer { controller.mainWindowController.close() }
            let menuShortcut = menuItem(identifier: "menu.file.open", in: NSApp.mainMenu)?.keyEquivalent

            try Data("[keymap\n".utf8).write(to: configURL)
            controller.reloadConfig()
            let pinned = controller.mainWindowController.rootView.statusBar.presentation.detail
            #expect(pinned.contains("Configuration rejected"))
            #expect(controller.mainWindowController.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "z"))))
            #expect(first.zoomFactors == [1.5])
            controller.mainWindowController.presentCommandPalette()
            #expect(controller.mainWindowController.rootView.commandPaletteOverlay.visibleCommandsForTesting.contains { $0.id == .viewZoomIn && $0.shortcut == "z" })
            controller.mainWindowController.dismissAllTransientOverlays()
            #expect(menuItem(identifier: "menu.file.open", in: NSApp.mainMenu)?.keyEquivalent == menuShortcut)

            controller.dispatch(.pageNext)
            controller.dispatch(.tabNext)
            controller.dispatch(.searchPrompt)
            controller.mainWindowController.dismissPromptAndRestoreFocus()
            let document = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 1)
            #expect(controller.openDocument(at: document))
            #expect(controller.mainWindowController.rootView.statusBar.presentation.detail == pinned)

            try writeValidConfig(to: configURL)
            controller.reloadConfig()
            #expect(controller.mainWindowController.rootView.statusBar.presentation.detail == "Config reloaded")
        }
    }

    @Test("reload closes every transient overlay and retained menu items dispatch once")
    func installDismissesOverlaysAndRetainedMenuDispatches() throws {
        try withTemporaryDirectory { directory in
            let configURL = directory.appendingPathComponent("config.toml")
            let store = ReaderSessionStore()
            let session = ReloadRecordingSession(title: "reload.pdf")
            #expect(store.insert(session))
            let controller = makeController(configURL: configURL, store: store)
            controller.start()
            try writeValidConfig(to: configURL)
            let linkSession = try PDFOpenService().open(url: PDFFixtureFactory.makeLinkHintPDF(in: directory))
            #expect(store.insert(linkSession))

            defer { controller.mainWindowController.close(); linkSession.prepareForClose() }
            let overlays: [(String, () -> Void, () -> Bool)] = [
                ("palette", { controller.mainWindowController.presentCommandPalette() }, { controller.mainWindowController.rootView.commandPaletteOverlay.isHidden }),
                ("theme", { controller.mainWindowController.presentThemePicker() }, { controller.mainWindowController.rootView.themePickerOverlay.isHidden }),
                ("recent", { controller.mainWindowController.presentRecentFilesOverlay() }, { controller.mainWindowController.rootView.recentFilesOverlay.isHidden }),
                ("help", { controller.mainWindowController.presentHelp() }, { controller.mainWindowController.rootView.helpOverlay.isHidden }),
                ("link hints", {
                    #expect(store.activate(linkSession.id))
                    controller.mainWindowController.rootView.layoutSubtreeIfNeeded()
                    controller.mainWindowController.window?.contentView?.layoutSubtreeIfNeeded()
                    controller.mainWindowController.presentLinkHints()
                }, { controller.mainWindowController.rootView.linkHintOverlay.isHidden }),
            ]
            for (name, present, isHidden) in overlays {
                present()
                #expect(!isHidden(), "\(name) overlay did not open")
                controller.reloadConfig()
                #expect(isHidden(), "\(name) overlay survived reload")
                if name == "link hints" {
                    let overlay = controller.mainWindowController.rootView.linkHintOverlay
                    #expect(controller.mainWindowController.window?.firstResponder === linkSession.focusView)
                    #expect(!overlay.hasCallbacksForTesting)
                }
            }

            #expect(store.activate(session.id))
            let retained = try #require(menuItem(identifier: "menu.view.zoom-in", in: NSApp.mainMenu))
            let action = try #require(retained.action)
            #expect(NSApp.sendAction(action, to: retained.target, from: retained))
            #expect(session.zoomFactors == [1.5])
        }
    }

    @Test("palette commits and the default prefix key route both invoke config reload")
    func paletteAndKeyDispatchBothReload() throws {
        try withTemporaryDirectory { directory in
            let configURL = directory.appendingPathComponent("config.toml")
            try writeValidConfig(to: configURL)
            let store = ReaderSessionStore()
            #expect(store.insert(ReloadRecordingSession(title: "reload.pdf")))
            let controller = makeController(configURL: configURL, store: store)
            controller.start()
            defer { controller.mainWindowController.close() }

            controller.mainWindowController.presentCommandPalette()
            for character in "reload config" {
                _ = controller.mainWindowController.routeKeyEventForTesting(try #require(makeKeyEvent(characters: String(character))))
            }
            #expect(controller.mainWindowController.rootView.commandPaletteOverlay.selectedCommandID == .configReload)
            #expect(controller.mainWindowController.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36))))
            #expect(controller.configInstallGenerationCountForTesting == 1)

            #expect(controller.mainWindowController.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "b", modifiers: [.control]))))
            #expect(controller.mainWindowController.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "r"))))
            #expect(controller.configInstallGenerationCountForTesting == 2)
        }
    }

    @Test("pinned diagnostics reject every unpinned replacement but accept a newer pinned diagnostic")
    func pinnedDiagnosticOwnership() {
        let root = ReaderRootView()
        root.showDiagnostic("pinned config failure", expandedDetail: "original", isError: true, pinned: true)
        for message in [
            "No configuration file to reload.",
            "Default config written",
            "Could not open CONFIG.md",
            "Theme applied for this session but could not be saved",
            "PDF opened but recent-files list could not be saved",
        ] {
            root.showDiagnostic(message, isError: false)
            #expect(root.statusBar.presentation.detail == "pinned config failure")
            #expect(root.hasPinnedDiagnostic)
        }
        root.showDiagnostic("new pinned config failure", expandedDetail: "new", isError: true, pinned: true)
        #expect(root.statusBar.presentation.detail == "new pinned config failure")
        root.clearDiagnostic(force: true)
        #expect(!root.hasPinnedDiagnostic)
    }

    @Test("a reloaded custom prefix routes only the new reload binding and updates palette and help")
    func customPrefixReloadUpdatesAllKeySurfaces() throws {
        try withTemporaryDirectory { directory in
            let configURL = directory.appendingPathComponent("config.toml")
            try Data("""
            [input]
            prefix = "<C-a>"
            """.utf8).write(to: configURL)
            let controller = makeController(configURL: configURL, store: ReaderSessionStore())
            controller.start()
            defer { controller.mainWindowController.close() }

            controller.reloadConfig()
            #expect(!controller.mainWindowController.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "b", modifiers: [.control]))))
            #expect(controller.mainWindowController.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "a", modifiers: [.control]))))
            #expect(controller.mainWindowController.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "r"))))
            #expect(controller.configInstallGenerationCountForTesting == 2)

            controller.mainWindowController.presentCommandPalette()
            #expect(controller.mainWindowController.rootView.commandPaletteOverlay.visibleCommandsForTesting.contains { $0.id == .configReload && $0.shortcut == "Ctrl+a r" })
            controller.mainWindowController.dismissAllTransientOverlays()
            controller.mainWindowController.presentHelp()
            #expect(controller.mainWindowController.rootView.helpOverlay.visibleEntriesForTesting.contains { $0 == ("Ctrl+a r", "Reload Config") })
        }
    }

    @Test("help includes Reload Config in the Config card and missing reload leaves the generation unchanged")
    func helpAndMissingReload() throws {
        try withTemporaryDirectory { directory in
            let configURL = directory.appendingPathComponent("missing.toml")
            let controller = makeController(configURL: configURL, store: ReaderSessionStore())
            controller.start()
            defer { controller.mainWindowController.close() }
            let before = controller.mainWindowController.resolvedConfig

            controller.mainWindowController.presentHelp()
            #expect(controller.mainWindowController.rootView.helpOverlay.visibleSectionsForTesting.contains("Config"))
            #expect(controller.mainWindowController.rootView.helpOverlay.visibleEntriesForTesting.contains { $0.1 == "Reload Config" })
            controller.mainWindowController.dismissAllTransientOverlays()
            controller.reloadConfig()

            #expect(controller.mainWindowController.resolvedConfig.config == before.config)
            #expect(controller.mainWindowController.rootView.statusBar.presentation.detail == "No configuration file to reload.")
        }
    }

    private func makeController(configURL: URL, store: ReaderSessionStore) -> ApplicationController {
        ApplicationController(
            configService: ConfigService(source: ConfigFileSource(url: configURL)),
            sessionStore: store,
            themeStore: ThemeSelectionStore(fileURL: configURL.deletingLastPathComponent().appendingPathComponent("theme-state.json")),
            recentFilesStore: RecentFilesStore(fileURL: configURL.deletingLastPathComponent().appendingPathComponent("recent-state.json")),
            terminationHandler: {}
        )
    }

    private func writeValidConfig(to url: URL) throws {
        try Data("""
        [keymap]
        "view.zoomIn" = ["z"]
        "document.open" = ["<D-e>"]

        [navigation]
        small_scroll_points = 63
        large_scroll_viewport_fraction = 0.35
        zoom_factor = 1.5
        """.utf8).write(to: url)
    }

    private func menuItem(identifier: String, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.accessibilityIdentifier() == identifier { return item }
            if let found = menuItem(identifier: identifier, in: item.submenu) { return found }
        }
        return nil
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-reader-config-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}

@MainActor
private final class ReloadRecordingSession: ReaderSessionPresenting {
    let id = TabID()
    let title: String
    let contentView = NSView()
    private var presentationChangeHandler: (() -> Void)?
    private(set) var verticalPointScrolls: [Double] = []
    private(set) var viewportScrolls: [Double] = []
    private(set) var zoomFactors: [Double] = []

    init(title: String) {
        self.title = title
    }

    var statusSnapshot: ReaderStatusSnapshot {
        ReaderStatusSnapshot(context: "NORMAL", page: "1 / 1", zoom: "100%", detail: title)
    }

    func setPresentationChangeHandler(_ handler: (() -> Void)?) {
        presentationChangeHandler = handler
    }

    func applyTheme(_ theme: AppKitTheme) {}

    func moveVertically(byPoints points: Double) {
        verticalPointScrolls.append(points)
        presentationChangeHandler?()
    }

    func moveVertically(byViewportFraction fraction: Double) {

        viewportScrolls.append(fraction)
        presentationChangeHandler?()
    }


    func prepareForClose() {}
    func zoom(by factor: Double) {
        zoomFactors.append(factor)
        presentationChangeHandler?()
    }
}
