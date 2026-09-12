import AppKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("Update banner UI")
@MainActor
struct UpdateBannerTests {
    @Test("presenting an update shows the full banner text; clearing removes it")
    func presentAndClear() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 480, height: 24))
        bar.apply(theme: AppKitTheme(themeID: .tokyoNight))
        #expect(bar.updateText == nil)

        let text = "0.3.0 available → modeleaf update · Details [U]"
        bar.presentUpdate(text)
        #expect(bar.updateText == text)

        bar.presentUpdate(nil)
        #expect(bar.updateText == nil)
        bar.presentUpdate("   ")
        #expect(bar.updateText == nil)
    }

    @Test("clicking the banner fires the callback")
    func click() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 480, height: 24))
        var fired = 0
        bar.onUpdateClicked = { fired += 1 }
        bar.presentUpdate("0.3.0 available → modeleaf update · Details [U]")
        bar.performUpdateClickForTesting()
        #expect(fired == 1)
    }

    @Test("the compact status bar retains the version and shortcut")
    func unambiguousLayout() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 480, height: 24))
        bar.apply(theme: AppKitTheme(themeID: .tokyoNight))
        bar.render(StatusBarPresentation(page: "300 / 300", zoom: "125%", mode: "FIT PAGE", isSearchMode: true, pendingPrefix: "Ctrl+b", detail: "Ready", tone: .normal))
        let text = "0.9.0 available → modeleaf update · Details [U]"
        bar.presentUpdate(text)
        bar.layoutSubtreeIfNeeded()
        #expect(!bar.hasAmbiguousLayout)
        #expect(!bar.updateIsTruncatedForTesting)
        #expect(bar.bounds.contains(bar.updateFrameForTesting))
        #expect(bar.updateToolTipForTesting == "View release details")
        #expect(bar.updateText == text)
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

        controller.installAvailableUpdate(AvailableUpdate(version: try #require(AppVersion("0.9.0"))))
        #expect(controller.rootView.statusBar.updateText == "0.9.0 available → modeleaf update · Details [U]")
        #expect(BuiltInDefaults.keymap[.updateShow]?.map(\.description) == ["U"])
        controller.presentAvailableUpdate()
        let available = PaletteAvailability.evaluate(
            .updateShow,
            state: PaletteContextState(hasActiveDocument: true, paneCount: 1, tabCount: 1, inSearchResults: true, hasAvailableUpdate: true)
        )
        #expect(available.enabled)
        #expect(!controller.rootView.updateInstructionsOverlay.isHidden)
    }

    @Test("the compact popup uses a summary header, inline actions, and no command block")
    func compactSummaryAndActions() throws {
        let overlay = UpdateInstructionsOverlayView(frame: NSRect(x: 0, y: 0, width: 410, height: 220))
        overlay.apply(theme: AppKitTheme(themeID: .tokyoNight))
        var copied: [String] = []
        var opened: [URL] = []
        overlay.copyHandler = { copied.append($0) }
        overlay.openHandler = { opened.append($0) }
        let releaseURL = try #require(URL(string: "https://github.com/DS-argus/modeleaf/releases/tag/v0.9.0"))
        let summary = "- Added `modeleaf update` support\n- Improved reader startup"
        overlay.present(update: AvailableUpdate(
            version: try #require(AppVersion("0.9.0")),
            highlights: summary,
            releaseURL: releaseURL
        ))
        overlay.layoutSubtreeIfNeeded()

        #expect(overlay.titleForTesting == "Update available")
        #expect(overlay.versionForTesting == "0.9.0")
        #expect(overlay.summaryForTesting == summary)
        #expect(overlay.summaryRenderedTextForTesting == "• Added modeleaf update support\n• Improved reader startup")
        #expect(!overlay.summaryIsHiddenForTesting)
        #expect(overlay.summaryScrollViewForTesting.borderType == .noBorder)
        #expect(!overlay.summaryScrollViewForTesting.drawsBackground)
        #expect(overlay.footerActionTitlesForTesting == [
            "↵ Copy update command",
            "⇧↵ Release notes",
            "Esc Close",
        ])
        #expect(overlay.copyButtonForTesting.isBordered == false)
        #expect(overlay.releaseNotesButtonForTesting.isBordered == false)
        #expect(overlay.closeButtonForTesting.isBordered == false)
        #expect(overlay.copyButtonForTesting.bezelStyle == .inline)
        #expect(overlay.releaseNotesButtonForTesting.bezelStyle == .inline)
        #expect(overlay.closeButtonForTesting.bezelStyle == .inline)
        #expect(overlay.releaseNotesEnabledForTesting)
        #expect(!accessibilityIdentifiers(in: overlay).contains("updateInstructions.command"))

        let codeRange = (overlay.summaryAttributedStringForTesting.string as NSString).range(of: "modeleaf update")
        let codeFont = overlay.summaryAttributedStringForTesting.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        #expect(codeFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)

        let copyWidth = overlay.copyButtonForTesting.frame.width
        overlay.copyForTesting()
        #expect(copied == ["modeleaf update"])
        #expect(overlay.copiedMessageForTesting == "Copied · Paste in Terminal")
        #expect(overlay.copyButtonForTesting.title == "Copied · Paste in Terminal")
        overlay.layoutSubtreeIfNeeded()
        #expect(overlay.copyButtonForTesting.frame.width == copyWidth)
        #expect(overlay.copyButtonForTesting.frame.width >= overlay.copyButtonForTesting.intrinsicContentSize.width - 0.5)
        #expect(overlay.footerIsWithinBoundsForTesting)
        overlay.present(update: AvailableUpdate(
            version: try #require(AppVersion("0.9.0")),
            highlights: summary,
            releaseURL: releaseURL
        ))
        #expect(overlay.copyButtonForTesting.title == "Copy update command")
        #expect(overlay.copiedMessageForTesting.isEmpty)

        overlay.openReleaseNotesForTesting()
        #expect(opened == [releaseURL])
        #expect(!overlay.isHidden)
    }

    @Test("summary layout stays unambiguous while hidden, shown, and after copying")
    func updateOverlayLayout() throws {
        let overlay = UpdateInstructionsOverlayView(frame: NSRect(x: 0, y: 0, width: 410, height: 220))
        overlay.apply(theme: AppKitTheme(themeID: .tokyoNight))
        overlay.layoutSubtreeIfNeeded()
        assertNoAmbiguousLayout(in: overlay)

        overlay.present(update: AvailableUpdate(
            version: try #require(AppVersion("0.9.0")),
            highlights: "- Faster search",
            releaseURL: URL(string: "https://github.com/DS-argus/modeleaf/releases/tag/v0.9.0")
        ))
        overlay.layoutSubtreeIfNeeded()
        assertNoAmbiguousLayout(in: overlay)
        #expect(overlay.footerIsWithinBoundsForTesting)

        overlay.copyForTesting()
        overlay.layoutSubtreeIfNeeded()
        assertNoAmbiguousLayout(in: overlay)
        #expect(overlay.footerIsWithinBoundsForTesting)

        overlay.dismiss()
        overlay.layoutSubtreeIfNeeded()
        assertNoAmbiguousLayout(in: overlay)
    }

    @Test("missing summary hides the body and missing URL disables release notes")
    func missingOptionalDetails() throws {
        let overlay = UpdateInstructionsOverlayView()
        overlay.apply(theme: AppKitTheme(themeID: .tokyoNight))
        overlay.present(update: AvailableUpdate(
            version: try #require(AppVersion("0.9.0")),
            highlights: "   \n",
            releaseURL: URL(string: "https://github.com/DS-argus/modeleaf/releases/tag/v0.9.0?unsafe=1")
        ))
        #expect(overlay.summaryForTesting == "   \n")
        #expect(overlay.summaryIsHiddenForTesting)
        #expect(!overlay.releaseNotesEnabledForTesting)
        #expect(overlay.summaryRenderedTextForTesting.isEmpty)

        var copied: [String] = []
        var opened = 0
        overlay.copyHandler = { copied.append($0) }
        overlay.openHandler = { _ in opened += 1 }
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "\r", keyCode: 36))))
        #expect(copied == ["modeleaf update"])
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "\r", modifiers: [.shift], keyCode: 36))))
        #expect(opened == 0)
        overlay.releaseNotesButtonForTesting.performClick(nil)
        #expect(opened == 0)
        #expect(!overlay.isHidden)
    }

    @Test("inline code keeps unmatched backticks while leading list markers become bullets")
    func markdownSummaryRendering() throws {
        let overlay = UpdateInstructionsOverlayView()
        overlay.apply(theme: AppKitTheme(themeID: .tokyoNight))
        overlay.present(update: AvailableUpdate(
            version: try #require(AppVersion("0.9.0")),
            highlights: "* Keep `modeleaf update` inline\n+ Preserve this `literal",
            releaseURL: nil
        ))
        #expect(overlay.summaryRenderedTextForTesting == "• Keep modeleaf update inline\n• Preserve this `literal")
    }

    @Test("Enter copies, Shift+Enter opens, modifiers never copy, and Esc cancels")
    func keyboardActions() throws {
        let overlay = UpdateInstructionsOverlayView()
        let releaseURL = try #require(URL(string: "https://github.com/DS-argus/modeleaf/releases/tag/v0.9.0"))
        var copied: [String] = []
        var opened: [URL] = []
        var cancelled = 0
        overlay.copyHandler = { copied.append($0) }
        overlay.openHandler = { opened.append($0) }
        overlay.onCancel = { cancelled += 1 }
        overlay.present(update: AvailableUpdate(
            version: try #require(AppVersion("0.9.0")),
            highlights: "- Faster search",
            releaseURL: releaseURL
        ))

        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "\r", keyCode: 36))))
        #expect(copied == ["modeleaf update"])
        #expect(overlay.copiedMessageForTesting == "Copied · Paste in Terminal")
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "\r", keyCode: 76))))
        #expect(copied == ["modeleaf update", "modeleaf update"])
        #expect(!overlay.isHidden)

        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "\r", modifiers: [.shift], keyCode: 36))))
        #expect(opened == [releaseURL])
        let blockedModifiers: [NSEvent.ModifierFlags] = [
            .command,
            .control,
            .option,
            [.shift, .command],
            [.shift, .control],
            [.shift, .option],
        ]
        for modifier in blockedModifiers {
            #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "\r", modifiers: modifier, keyCode: 36))))
        }
        #expect(copied == ["modeleaf update", "modeleaf update"])
        #expect(opened == [releaseURL])
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "", keyCode: 53))))
        #expect(cancelled == 1)

        overlay.closeButtonForTesting.performClick(nil)
        #expect(cancelled == 2)
    }

    @Test("long release summary scrolls while footer remains visible and untruncated")
    func longSummaryScrolls() throws {
        let overlay = UpdateInstructionsOverlayView(frame: NSRect(x: 0, y: 0, width: 410, height: 280))
        overlay.apply(theme: AppKitTheme(themeID: .tokyoNight))
        let summary = (1...24).map { "- Highlight \($0): improved `modeleaf update` behavior" }.joined(separator: "\n")
        overlay.present(update: AvailableUpdate(
            version: try #require(AppVersion("0.9.0")),
            highlights: summary,
            releaseURL: URL(string: "https://github.com/DS-argus/modeleaf/releases/tag/v0.9.0")
        ))
        overlay.layoutSubtreeIfNeeded()
        #expect(overlay.listRequiresScrollingForTesting)
        #expect(overlay.footerIsWithinBoundsForTesting)
        #expect(overlay.copyButtonForTesting.title == "Copy update command")
        #expect(overlay.copyButtonForTesting.frame.width >= overlay.copyButtonForTesting.intrinsicContentSize.width - 0.5)
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
        controller.installAvailableUpdate(AvailableUpdate(
            version: try #require(AppVersion("0.9.0")),
            highlights: "- Small, realistic update summary",
            releaseURL: URL(string: "https://github.com/DS-argus/modeleaf/releases/tag/v0.9.0")
        ))
        controller.presentAvailableUpdate()
        controller.rootView.layoutSubtreeIfNeeded()

        #expect(!controller.rootView.hasAmbiguousLayout)
        #expect(controller.rootView.bounds.contains(controller.rootView.updateInstructionsOverlay.frame))
        #expect(controller.rootView.updateInstructionsOverlay.footerIsWithinBoundsForTesting)
        #expect(controller.window?.firstResponder === controller.rootView.updateInstructionsOverlay)
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
        controller.installAvailableUpdate(AvailableUpdate(
            version: try #require(AppVersion("0.9.0")),
            highlights: "- Search improvements",
            releaseURL: URL(string: "https://github.com/DS-argus/modeleaf/releases/tag/v0.9.0")
        ))
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
        let update = AvailableUpdate(
            version: try #require(AppVersion("0.13.0")),
            highlights: "- See what changed before you update.\n- Copy the update command straight from this panel.\n- Open the full release notes with Shift+Enter.",
            releaseURL: try #require(URL(string: "https://github.com/DS-argus/modeleaf/releases/tag/v0.13.0"))
        )
        root.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        controller.installAvailableUpdate(update)
        controller.presentAvailableUpdate()
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        #expect(root.updateInstructionsOverlay.footerIsWithinBoundsForTesting)
        let fullURL = URL(fileURLWithPath: outputPath)
        let copiedURL = URL(fileURLWithPath: fullURL.deletingPathExtension().path + "-copied." + fullURL.pathExtension)
        let minimumURL = URL(fileURLWithPath: fullURL.deletingPathExtension().path + "-minimum." + fullURL.pathExtension)
        try writePNG(for: root, to: fullURL)

        root.updateInstructionsOverlay.copyForTesting()
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        #expect(root.updateInstructionsOverlay.footerIsWithinBoundsForTesting)
        try writePNG(for: root, to: copiedURL)

        root.updateInstructionsOverlay.present(update: update)
        root.frame = NSRect(origin: .zero, size: WindowVisualMetrics.minimumSize)
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        #expect(root.bounds.contains(root.updateInstructionsOverlay.frame))
        #expect(root.updateInstructionsOverlay.footerIsWithinBoundsForTesting)
        try writePNG(for: root, to: minimumURL)
    }

    private func writePNG(for view: NSView, to url: URL) throws {
        let representation = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let png = try #require(representation.representation(using: .png, properties: [:]))
        #expect(png.count > 10_000)
        try png.write(to: url, options: .atomic)
    }

    private func assertNoAmbiguousLayout(in view: NSView) {
        #expect(!view.hasAmbiguousLayout, "ambiguous \(type(of: view)) id=\(view.accessibilityIdentifier()) frame=\(view.frame)")
        guard !(view is NSScrollView) else { return }
        for subview in view.subviews {
            assertNoAmbiguousLayout(in: subview)
        }
    }

    private func accessibilityIdentifiers(in view: NSView) -> [String] {
        [view.accessibilityIdentifier()] + view.subviews.flatMap(accessibilityIdentifiers(in:))
    }
}
