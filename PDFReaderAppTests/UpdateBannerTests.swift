import AppKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("Update banner UI + source detection")
@MainActor
struct UpdateBannerTests {
    @Test("presenting an update shows the banner text; clearing removes it")
    func presentAndClear() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 480, height: 24))
        bar.apply(theme: AppKitTheme(themeID: .tokyoNight))
        #expect(bar.updateText == nil)

        let text = "\u{2191} Modeleaf 0.3.0 available \u{2014} brew upgrade --cask modeleaf"
        bar.presentUpdate(text)
        #expect(bar.updateText == text)

        bar.presentUpdate(nil)
        #expect(bar.updateText == nil)
        bar.presentUpdate("   ")
        #expect(bar.updateText == nil) // whitespace-only is treated as no banner
    }

    @Test("clicking the banner fires the callback")
    func click() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 480, height: 24))
        var fired = 0
        bar.onUpdateClicked = { fired += 1 }
        bar.presentUpdate("\u{2191} update")
        bar.performUpdateClickForTesting()
        #expect(fired == 1)
    }

    @Test("the status bar preserves the actionable banner at minimum width")
    func unambiguousLayout() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 480, height: 24))
        bar.apply(theme: AppKitTheme(themeID: .tokyoNight))
        bar.render(StatusBarPresentation(page: "300 / 300", zoom: "125%", mode: "FIT PAGE", isSearchMode: true, pendingPrefix: "Ctrl+b", detail: "Ready", tone: .normal))
        let text = "↑ Modeleaf 0.9.0 available  [U]"
        bar.presentUpdate(text)
        bar.layoutSubtreeIfNeeded()
        #expect(!bar.hasAmbiguousLayout)
        #expect(!bar.updateIsTruncatedForTesting)
        #expect(bar.bounds.contains(bar.updateFrameForTesting))
        #expect(bar.updateToolTipForTesting == text)
    }

    @Test("install source follows the running bundle rather than stale Caskroom state")
    func installSource() {
        #expect(InstallSourceDetector.detect(bundleURL: URL(fileURLWithPath: "/Applications/Modeleaf.app")) == .manual)
        #expect(InstallSourceDetector.detect(bundleURL: URL(fileURLWithPath: "/opt/homebrew/Caskroom/modeleaf/0.9.0/Modeleaf.app")) == .homebrew)
        #expect(InstallSourceDetector.detect(bundleURL: URL(fileURLWithPath: "/usr/local/Caskroom/modeleaf/0.9.0/Modeleaf.app")) == .homebrew)
        #expect(InstallSourceDetector.detect(bundleURL: URL(fileURLWithPath: "/opt/homebrew/Caskroom/other/Modeleaf.app")) == .manual)
    }

    @Test("Homebrew update popup copies the normal command and keeps the popup open")
    func homebrewInstructions() throws {
        let overlay = UpdateInstructionsOverlayView()
        overlay.apply(theme: AppKitTheme(themeID: .tokyoNight))
        var copied: [String] = []
        overlay.copyHandler = { copied.append($0) }
        overlay.present(update: AvailableUpdate(version: try #require(AppVersion("0.9.0")), source: .homebrew))

        #expect(overlay.displayedCommandsForTesting == [
            "brew upgrade --cask modeleaf",
            "brew update --force && brew upgrade --cask modeleaf",
        ])
        overlay.copyForTesting()
        #expect(copied == ["brew upgrade --cask modeleaf"])
        #expect(overlay.copiedMessageForTesting == "Copied")
        #expect(!overlay.isHidden)
        #expect(overlay.keyHintForTesting.string.contains("Copy command"))
    }

    @Test("manual update popup routes to Releases and escape closes through its owner")
    func manualInstructions() throws {
        let overlay = UpdateInstructionsOverlayView()
        var opened = 0
        var cancelled = 0
        overlay.onOpenReleases = { opened += 1 }
        overlay.onCancel = { cancelled += 1 }
        overlay.present(update: AvailableUpdate(version: try #require(AppVersion("0.9.0")), source: .manual))

        #expect(overlay.displayedCommandsForTesting == ["github.com/DS-argus/modeleaf/releases/latest"])
        #expect(overlay.keyHintForTesting.string.contains("Copy Releases URL"))
        overlay.openReleasesForTesting()
        #expect(opened == 1)
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "", keyCode: 53))))
        #expect(cancelled == 1)
    }

    @Test("banner, shortcut, and palette converge on an available update")
    func discoverability() throws {
        let store = ReaderSessionStore()
        let coordinator = PaneCoordinator(initialStore: store)
        let controller = MainWindowController(
            coordinator: coordinator,
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { _ in }
        )
        defer { controller.close() }

        #expect(!controller.hasAvailableUpdate)
        let unavailable = PaletteAvailability.evaluate(
            .updateShow,
            state: PaletteContextState(hasActiveDocument: true, paneCount: 1, tabCount: 1, inSearchResults: false)
        )
        #expect(!unavailable.enabled)
        #expect(unavailable.reason == "No update available")

        controller.installAvailableUpdate(AvailableUpdate(version: try #require(AppVersion("0.9.0")), source: .homebrew))
        #expect(controller.rootView.statusBar.updateText == "↑ Modeleaf 0.9.0 available  [U]")
        #expect(BuiltInDefaults.keymap[.updateShow]?.map(\.description) == ["U"])
        controller.presentAvailableUpdate()
        let available = PaletteAvailability.evaluate(
            .updateShow,
            state: PaletteContextState(hasActiveDocument: true, paneCount: 1, tabCount: 1, inSearchResults: true, hasAvailableUpdate: true)
        )
        #expect(available.enabled)
        #expect(!controller.rootView.updateInstructionsOverlay.isHidden)
    }

    @Test("keyboard actions copy, open Releases, and preserve popup state")
    func keyboardActions() throws {
        let overlay = UpdateInstructionsOverlayView()
        var copied: [String] = []
        var opened = 0
        overlay.copyHandler = { copied.append($0) }
        overlay.onOpenReleases = { opened += 1 }
        overlay.present(update: AvailableUpdate(version: try #require(AppVersion("0.9.0")), source: .homebrew))

        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "\r", keyCode: 36))))
        #expect(copied == ["brew upgrade --cask modeleaf"])
        #expect(overlay.copiedMessageForTesting == "Copied")
        #expect(!overlay.isHidden)
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "o", keyCode: 31))))
        #expect(opened == 1)
    }

    @Test("popup fits the minimum reader window and excludes other transient overlays")
    func containmentAndMutualExclusion() throws {
        let store = ReaderSessionStore()
        let coordinator = PaneCoordinator(initialStore: store)
        let controller = MainWindowController(
            coordinator: coordinator,
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { _ in }
        )
        defer { controller.close() }
        controller.rootView.frame = NSRect(x: 0, y: 0, width: 480, height: 360)
        controller.installAvailableUpdate(AvailableUpdate(version: try #require(AppVersion("0.9.0")), source: .homebrew))
        controller.presentAvailableUpdate()
        controller.rootView.layoutSubtreeIfNeeded()

        #expect(!controller.rootView.hasAmbiguousLayout)
        #expect(controller.rootView.bounds.contains(controller.rootView.updateInstructionsOverlay.frame))
        controller.presentHelp()
        #expect(controller.rootView.updateInstructionsOverlay.isHidden)
        #expect(!controller.rootView.helpOverlay.isHidden)
    }

    @Test("closing update popup restores an underlying prompt")
    func promptFocusRestoration() throws {
        let coordinator = PaneCoordinator(initialStore: ReaderSessionStore())
        let controller = MainWindowController(
            coordinator: coordinator,
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { _ in }
        )
        defer { controller.close() }
        controller.presentPrompt(PromptPresentation(kind: .search, text: "query", validationMessage: nil))
        controller.installAvailableUpdate(AvailableUpdate(version: try #require(AppVersion("0.9.0")), source: .homebrew))
        controller.presentAvailableUpdate()
        #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "", keyCode: 53))))
        #expect(controller.rootView.updateInstructionsOverlay.isHidden)
        #expect(controller.rootView.promptOverlay.textField.currentEditor() === controller.window?.firstResponder)
    }

    @Test("render update popup visual evidence when requested")
    func visualEvidence() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["UPDATE_QA_IMAGE"] else { return }
        let store = ReaderSessionStore()
        let coordinator = PaneCoordinator(initialStore: store)
        let controller = MainWindowController(
            coordinator: coordinator,
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { _ in }
        )
        defer { controller.close() }
        let root = controller.rootView
        root.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        controller.installAvailableUpdate(AvailableUpdate(version: try #require(AppVersion("0.9.0")), source: .homebrew))
        controller.presentAvailableUpdate()
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        let representation = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: representation)
        let png = try #require(representation.representation(using: .png, properties: [:]))
        #expect(png.count > 10_000)
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}
