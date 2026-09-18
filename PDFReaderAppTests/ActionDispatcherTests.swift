import AppKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("Viewer-first action dispatcher")
@MainActor
struct ActionDispatcherTests {
    @Test("path starts after final badge and stays anchored when copied")
    func pathLayoutStability() throws {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 960, height: 26))
        bar.apply(theme: AppKitTheme(themeID: .catppuccinLatte))
        let window = NSWindow(contentRect: bar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = bar
        defer { window.contentView = nil }
        func label(_ id: String, in view: NSView) -> NSTextField? {
            if view.accessibilityIdentifier() == id { return view as? NSTextField }
            return view.subviews.lazy.compactMap { label(id, in: $0) }.first
        }
        var state = StatusBarPresentation(page: "1 / 2", zoom: "100%", mode: "FIT WIDTH", isSearchMode: true, pendingPrefix: "y", documentPath: "/tmp/document.pdf", detail: "", tone: .normal)
        bar.render(state)
        bar.layoutSubtreeIfNeeded()
        let path = try #require(label("status.path", in: bar))
        let copied = try #require(label("status.copied", in: bar))
        let badge = try #require(label("status.searchMode", in: bar))
        let start = bar.convert(path.bounds, from: path).minX
        #expect(start > bar.convert(badge.bounds, from: badge).maxX)
        #expect(path.textColor == AppKitTheme(themeID: .catppuccinLatte)[.mutedText])
        state.transientNotice = "Copied!"
        bar.render(state)
        bar.layoutSubtreeIfNeeded()
        #expect(abs(bar.convert(path.bounds, from: path).minX - start) < 0.5)
        #expect(path.stringValue == "/tmp/document.pdf")
        #expect(copied.stringValue == "copied!")
        #expect(copied.textColor?.usingColorSpace(.sRGB) == NSColor.systemGreen.usingColorSpace(.sRGB))
    }
    @Test("path feedback replaces state and cancels stale expiry")
    func pathFeedbackReplacement() async throws {
        let root = ReaderRootView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        let path = "/tmp/Long folder/Document.pdf"
        root.setDocumentPath(path, dismissAfter: .milliseconds(40))
        #expect(root.statusBar.presentation.documentPath == path)
        #expect(root.statusBar.presentation.transientNotice.isEmpty)
        root.setDocumentPath(path, copied: true, dismissAfter: .seconds(120))
        try await Task.sleep(for: .milliseconds(80))
        #expect(root.statusBar.presentation.documentPath == path)
        #expect(root.statusBar.presentation.transientNotice == "Copied!")
        root.setDocumentPath(path, dismissAfter: .seconds(120))
        await Task.yield()
        #expect(root.statusBar.presentation.documentPath == path)
        #expect(root.statusBar.presentation.transientNotice.isEmpty)
        root.setPendingPrefix("")
        #expect(root.statusBar.presentation.documentPath == path)
        root.setDocumentPath(path, copied: true, dismissAfter: .milliseconds(20))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !root.statusBar.presentation.documentPath.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(root.statusBar.presentation.documentPath.isEmpty)
        #expect(root.statusBar.presentation.transientNotice.isEmpty)
        root.setDocumentPath(path, copied: true)
        root.clearDocumentPath()
        #expect(root.statusBar.presentation.documentPath.isEmpty)
        #expect(root.statusBar.presentation.transientNotice.isEmpty)
        root.showActionFeedback("Completed", isError: false, dismissAfter: .seconds(3))
        #expect(root.statusBar.presentation.transientNotice == "Completed")
        root.dismissTransientNotice()
    }
    @Test("responsive status keeps transient content and search/error priority across supported widths")
    func responsiveStatusLayout() throws {
        let longPath = "/Users/example/Documents/Research/2026/Very-long-folder-name/Another-folder/Reader-reference-document.pdf"
        let cases: [(width: CGFloat, state: StatusBarPresentation)] = [
            (
                480,
                StatusBarPresentation(
                    page: "300 / 300",
                    zoom: "125%",
                    mode: "FIT PAGE",
                    transientNotice: "Copied!",
                    pendingPrefix: "g",
                    documentPath: longPath,
                    detail: "Ready",
                    tone: .normal
                )
            ),
            (
                640,
                StatusBarPresentation(
                    page: "300 / 300",
                    zoom: "125%",
                    mode: "FIT WIDTH",
                    isSearchMode: true,
                    pendingPrefix: "",
                    detail: "No matches · “a deliberately long search query that should disappear”",
                    tone: .normal
                )
            ),
            (
                960,
                StatusBarPresentation(
                    page: "300 / 300",
                    zoom: "125%",
                    mode: "FIT PAGE",
                    pendingPrefix: "",
                    detail: "Could not open the selected PDF",
                    expandedDetail: String(repeating: "The complete diagnostic includes a long underlying parser explanation. ", count: 120),
                    tone: .error
                )
            ),
        ]

        func descendants(of view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants(of:))
        }

        func isEffectivelyVisible(_ view: NSView) -> Bool {
            guard !view.isHidden else { return false }
            var ancestor = view.superview
            while let parent = ancestor {
                if parent.isHidden { return false }
                ancestor = parent.superview
            }
            return true
        }

        for item in cases {
            let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: item.width, height: 26))
            bar.apply(theme: AppKitTheme(themeID: .tokyoNight))
            let window = NSWindow(contentRect: bar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = bar
            defer { window.contentView = nil }
            bar.render(item.state)
            bar.layoutSubtreeIfNeeded()

            #expect(!bar.hasAmbiguousLayout)
            for view in descendants(of: bar) where isEffectivelyVisible(view) {
                #expect(bar.bounds.contains(bar.convert(view.bounds, from: view)), "visible status item escaped \(item.width)pt bar")
                if let label = view as? NSTextField {
                    #expect(label.maximumNumberOfLines <= 1)
                    #expect(!label.stringValue.isEmpty)
                    if label.accessibilityIdentifier() != "status.path" {
                        #expect(label.frame.width + 0.5 >= label.intrinsicContentSize.width, "non-path labels must not be truncated")
                    }
                }
            }

            if item.width == 480 {
                #expect(bar.visibleStatusIdentifiersForTesting.contains("status.path"))
                #expect(bar.visibleStatusIdentifiersForTesting.contains("status.copied"))
                #expect(!bar.visibleStatusIdentifiersForTesting.contains("status.mode"))
                #expect(bar.copiedFrameForTesting.minX > bar.convert(NSRect(x: 0, y: 0, width: 1, height: 1), from: bar).minX)
            } else if item.width == 640 {
                let detail = try #require(descendants(of: bar).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "status.diagnostic" })
                #expect(!detail.stringValue.contains("“"))
                #expect(!detail.stringValue.contains("”"))
                #expect(detail.stringValue == "No matches")
            } else {
                #expect(!bar.errorButtonForTesting.isHidden)
                bar.performDiagnosticClickForTesting()
                #expect(bar.errorPopoverTextForTesting?.contains("complete diagnostic") == true)
                let scroll = try #require(bar.diagnosticContentForTesting)
                let text = try #require(scroll.documentView as? NSTextView)
                #expect(text.string == bar.errorPopoverTextForTesting)
                #expect(scroll.hasVerticalScroller)
                #expect(text.frame.height > scroll.contentSize.height)
            }
        }
    }

    @Test("responsive status evidence renders 480, 640, and 960 point bars when requested")
    func responsiveStatusEvidence() throws {
        guard let directory = ProcessInfo.processInfo.environment["PDF_READER_SNAPSHOT_DIR"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let longPath = "/Users/example/Documents/Research/2026/Very-long-folder-name/Another-folder/Reader-reference-document.pdf"
        let states: [(CGFloat, StatusBarPresentation)] = [
            (480, StatusBarPresentation(page: "300 / 300", zoom: "125%", mode: "FIT PAGE", transientNotice: "Copied!", pendingPrefix: "g", documentPath: longPath, detail: "Ready", tone: .normal)),
            (640, StatusBarPresentation(page: "300 / 300", zoom: "125%", mode: "FIT WIDTH", isSearchMode: true, pendingPrefix: "", detail: "Searching “a long query that should be shortened”… · 12 found", tone: .normal)),
            (960, StatusBarPresentation(page: "300 / 300", zoom: "125%", mode: "FIT PAGE", pendingPrefix: "", detail: "Could not open the selected PDF", expandedDetail: String(repeating: "The complete diagnostic includes a long underlying parser explanation. ", count: 12), tone: .error))
        ]
        for (width, state) in states {
            let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: width, height: 26))
            bar.apply(theme: AppKitTheme(themeID: .tokyoNight))
            let window = NSWindow(contentRect: bar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = bar
            bar.render(state)
            bar.layoutSubtreeIfNeeded()
            let representation = try #require(bar.bitmapImageRepForCachingDisplay(in: bar.bounds))
            bar.cacheDisplay(in: bar.bounds, to: representation)
            let png = try #require(representation.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("responsive-status-\(Int(width)).png"), options: .atomic)
            window.contentView = nil
        }
    }
    @Test("configured movement, page, and zoom actions call only the active session")
    func navigationValues() {
        let store = ReaderSessionStore()
        let first = RecordingReaderSession(title: "First.pdf", pageCount: 20)
        let active = RecordingReaderSession(title: "Active.pdf", pageCount: 20)
        #expect(store.insert(first))
        #expect(store.insert(active))
        let navigation = NavigationConfiguration(
            smallScrollPoints: 33,
            largeScrollViewportFraction: 0.65,
            zoomFactor: 1.25
        )
        let coordinator = PaneCoordinator(initialStore: store)
        let dispatcher = ActionDispatcher(coordinator: coordinator, navigation: navigation)

        for action in [
            ActionID.scrollLeft, .scrollDown, .scrollUp, .scrollRight,
            .scrollLargeDown, .scrollLargeUp,
            .pageNext, .pagePrevious, .pageFirst, .pageLast,
            .viewZoomIn, .viewZoomOut, .viewZoomReset, .viewFitWidth, .viewFitPage,
            .viewRotateLeft, .viewRotateRight,
        ] {
            dispatcher.dispatch(action)
        }

        #expect(first.events.isEmpty)
        #expect(active.events == [
            .scroll(x: -33, y: 0), .scroll(x: 0, y: 33),
            .scroll(x: 0, y: -33), .scroll(x: 33, y: 0),
            .viewport(0.65), .viewport(-0.65),
            .nextPage, .previousPage, .firstPage, .lastPage,
            .zoom(1.25), .zoom(0.8), .resetZoom, .fitWidth, .fitPage,
            .rotateLeft, .rotateRight,
        ])
    }

    @Test("TOC actions dispatch through the presentation surface without moving the document")
    func tocActionsDispatchToPresentationOnly() {
        let store = ReaderSessionStore()
        let session = RecordingReaderSession(title: "Reference.pdf")
        #expect(store.insert(session))
        let dispatcher = ActionDispatcher(coordinator: PaneCoordinator(initialStore: store), navigation: BuiltInDefaults.config.navigation)
        let presenter = PromptPresenterSpy()
        dispatcher.presentation = presenter

        dispatcher.dispatch(.tocToggle)
        dispatcher.dispatch(.tocScrollDown)
        dispatcher.dispatch(.tocScrollUp)

        #expect((presenter.tocToggleCount, presenter.tocScrollDownCount, presenter.tocScrollUpCount) == (1, 1, 1))
        #expect(session.events.isEmpty)
    }
    @Test("status priorities keep transient paths ahead of search and restore basics when widened")
    func responsivePriorityAndWidening() throws {
        let path = "/Users/example/Documents/Reader-reference-document.pdf"
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 480, height: 26))
        bar.apply(theme: AppKitTheme(themeID: .tokyoNight))
        let state = StatusBarPresentation(
            page: "3 / 12",
            zoom: "110%",
            mode: "FIT PAGE",
            isSearchMode: true,
            transientNotice: "Copied!",
            pendingPrefix: "g",
            documentPath: path,
            detail: "2 / 8 · “query”",
            tone: .normal
        )
        func label(_ id: String, in view: NSView) -> NSTextField? {
            if view.accessibilityIdentifier() == id { return view as? NSTextField }
            return view.subviews.lazy.compactMap { label(id, in: $0) }.first
        }
        bar.render(state)
        bar.layoutSubtreeIfNeeded()
        #expect(label("status.path", in: bar)?.isHidden == false)
        #expect(label("status.copied", in: bar)?.isHidden == false)
        #expect(!bar.visibleStatusIdentifiersForTesting.contains("status.searchMode"))
        #expect(label("status.diagnostic", in: bar)?.isHidden == true)
        #expect(label("status.page", in: bar)?.isHidden == true)

        bar.frame.size.width = 960
        bar.render(state)
        bar.layoutSubtreeIfNeeded()
        #expect(label("status.searchMode", in: bar)?.isHidden == false)
        #expect(label("status.diagnostic", in: bar)?.isHidden == false)
        #expect(label("status.page", in: bar)?.isHidden == false)
        #expect(label("status.mode", in: bar)?.isHidden == false)
        #expect(label("status.version", in: bar)?.isHidden == false)
        let version = try #require(label("status.version", in: bar))
        #expect(abs(version.frame.maxX - (bar.bounds.width - 12)) < 0.5)
    }

    @Test("error status uses a compact action when full details do not fit")
    func compactAndFullDiagnosticLayout() throws {
        let longDetail = String(repeating: "The complete diagnostic includes a long underlying parser explanation. ", count: 12)
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 480, height: 26))
        bar.apply(theme: AppKitTheme(themeID: .tokyoNight))
        func label(_ id: String, in view: NSView) -> NSTextField? {
            if view.accessibilityIdentifier() == id { return view as? NSTextField }
            return view.subviews.lazy.compactMap { label(id, in: $0) }.first
        }
        bar.render(StatusBarPresentation(page: "3 / 12", zoom: "110%", mode: "FIT PAGE", pendingPrefix: "", detail: "Could not open PDF", expandedDetail: longDetail, tone: .error))
        bar.layoutSubtreeIfNeeded()
        #expect(!bar.errorButtonForTesting.isHidden)
        #expect(label("status.diagnostic", in: bar)?.isHidden == true)
        bar.performDiagnosticClickForTesting()
        #expect(bar.errorPopoverTextForTesting?.contains("underlying parser") == true)

        bar.frame.size.width = 960
        bar.render(StatusBarPresentation(page: "3 / 12", zoom: "110%", mode: "FIT PAGE", pendingPrefix: "", detail: "Malformed PDF", expandedDetail: nil, tone: .error))
        bar.layoutSubtreeIfNeeded()
        #expect(bar.errorButtonForTesting.isHidden)
        #expect(label("status.diagnostic", in: bar)?.isHidden == false)
    }

    @Test("optional diagnostic, notice, and update never displace basic content")
    func optionalStatusPriority() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 480, height: 26))
        bar.apply(theme: AppKitTheme(themeID: .tokyoNight))
        bar.render(StatusBarPresentation(page: "3 / 12", zoom: "110%", mode: "FIT PAGE", transientNotice: "Notice", pendingPrefix: "", detail: "Info", tone: .normal))
        bar.presentUpdate("0.9.0 available → modeleaf update · Details [U]")
        bar.layoutSubtreeIfNeeded()
        #expect(!bar.visibleStatusIdentifiersForTesting.contains("status.update"))
        #expect(bar.visibleStatusIdentifiersForTesting.contains("status.page"))
        #expect(bar.visibleStatusIdentifiersForTesting.contains("status.zoom"))
        #expect(bar.visibleStatusIdentifiersForTesting.contains("status.mode"))
        #expect(bar.visibleStatusIdentifiersForTesting.contains("status.version"))
        #expect(bar.visibleStatusIdentifiersForTesting.contains("status.diagnostic"))
        #expect(bar.visibleStatusIdentifiersForTesting.contains("status.notice"))
    }

    @Test("TOC one-row actions remain presentation-only and repeatable")
    func tocOneRowActionsStayOutOfDocumentNavigation() {
        let store = ReaderSessionStore()
        let session = RecordingReaderSession(title: "Reference.pdf")
        #expect(store.insert(session))
        let dispatcher = ActionDispatcher(coordinator: PaneCoordinator(initialStore: store), navigation: BuiltInDefaults.config.navigation)
        let presenter = PromptPresenterSpy()
        dispatcher.presentation = presenter
        dispatcher.dispatch(.tocScrollDown)
        dispatcher.dispatch(.tocScrollDown)
        dispatcher.dispatch(.tocScrollUp)
        #expect((presenter.tocScrollDownCount, presenter.tocScrollUpCount) == (2, 1))
        #expect(session.events.isEmpty)
    }

    @Test("history actions target only the active session and empty dispatch is quiet")
    func historyActionsUseActiveSessionOnly() {
        let store = ReaderSessionStore()
        let first = RecordingReaderSession(title: "First.pdf")
        let active = RecordingReaderSession(title: "Active.pdf")
        #expect(store.insert(first))
        #expect(store.insert(active))
        let dispatcher = ActionDispatcher(coordinator: PaneCoordinator(initialStore: store), navigation: BuiltInDefaults.config.navigation)

        dispatcher.dispatch(.historyBack)
        dispatcher.dispatch(.historyForward)

        #expect(first.events.isEmpty)
        #expect(active.events == [.goBack, .goForward])

        let empty = ActionDispatcher(coordinator: PaneCoordinator(initialStore: ReaderSessionStore()), navigation: BuiltInDefaults.config.navigation)
        empty.dispatch(.historyBack)
        empty.dispatch(.historyForward)
    }


    @Test("file actions use only the active PDF and are inert without one")
    func fileActionsUseActivePDF() {
        let store = ReaderSessionStore()
        let first = RecordingReaderSession(title: "First.pdf")
        let active = RecordingReaderSession(title: "Active.pdf")
        #expect(store.insert(first))
        #expect(store.insert(active))
        var copiedPaths: [String] = []
        var revealedURLs: [URL] = []
        let dispatcher = ActionDispatcher(
            coordinator: PaneCoordinator(initialStore: store),
            navigation: BuiltInDefaults.config.navigation,
            clipboardWriter: { copiedPaths.append($0); return true },
            fileRevealer: { revealedURLs.append($0) }
        )
        let presenter = PromptPresenterSpy()
        dispatcher.presentation = presenter

        #expect(dispatcher.isActionEnabled(.documentCopyPath))
        #expect(dispatcher.isActionEnabled(.documentRevealInFinder))
        dispatcher.dispatch(.documentCopyPath)
        dispatcher.dispatch(.documentRevealInFinder)

        #expect(copiedPaths == [active.sourceURL.path])
        #expect(revealedURLs == [active.sourceURL])
        #expect(presenter.actionFeedback.map(\.0) == ["Copied PDF path"])
        #expect(presenter.actionFeedback.map(\.1) == [false])

        var emptySideEffectCount = 0
        let empty = ActionDispatcher(
            coordinator: PaneCoordinator(initialStore: ReaderSessionStore()),
            navigation: BuiltInDefaults.config.navigation,
            clipboardWriter: { _ in emptySideEffectCount += 1; return true },
            fileRevealer: { _ in emptySideEffectCount += 1 }
        )
        #expect(!empty.isActionEnabled(.documentCopyPath))
        #expect(!empty.isActionEnabled(.documentRevealInFinder))
        empty.dispatch(.documentCopyPath)
        empty.dispatch(.documentRevealInFinder)
        #expect(emptySideEffectCount == 0)
    }

    @Test("copy-path reports clipboard failure")
    func copyPathReportsClipboardFailure() {
        let store = ReaderSessionStore()
        #expect(store.insert(RecordingReaderSession(title: "Active.pdf")))
        let dispatcher = ActionDispatcher(
            coordinator: PaneCoordinator(initialStore: store),
            navigation: BuiltInDefaults.config.navigation,
            clipboardWriter: { _ in false }
        )
        let presenter = PromptPresenterSpy()
        dispatcher.presentation = presenter

        dispatcher.dispatch(.documentCopyPath)

        #expect(presenter.actionFeedback.map(\.0) == ["Could not copy PDF path"])
        #expect(presenter.actionFeedback.map(\.1) == [true])
    }
    @Test("print targets only the active document and is inert without one")
    func printUsesActiveDocumentOnly() {
        let store = ReaderSessionStore()
        let first = RecordingReaderSession(title: "First.pdf")
        let active = RecordingReaderSession(title: "Active.pdf")
        #expect(store.insert(first))
        #expect(store.insert(active))
        let dispatcher = ActionDispatcher(
            coordinator: PaneCoordinator(initialStore: store),
            navigation: BuiltInDefaults.config.navigation
        )
        let presenter = PromptPresenterSpy()
        dispatcher.presentation = presenter

        #expect(dispatcher.isActionEnabled(.documentPrint))
        dispatcher.dispatch(.documentPrint)

        #expect(first.events.isEmpty)
        #expect(active.events == [.printDocument])
        #expect(presenter.globalPreparationCount == 1)

        let empty = ActionDispatcher(
            coordinator: PaneCoordinator(initialStore: ReaderSessionStore()),
            navigation: BuiltInDefaults.config.navigation
        )
        #expect(!empty.isActionEnabled(.documentPrint))
        empty.dispatch(.documentPrint)
    }

    @Test("document.open presents the recent-files workflow instead of invoking the legacy open handler")
    func documentOpenPresentsRecentFiles() {
        let coordinator = PaneCoordinator(initialStore: ReaderSessionStore())
        var legacyOpenCount = 0
        let dispatcher = ActionDispatcher(
            coordinator: coordinator,
            navigation: BuiltInDefaults.config.navigation,
            openDocumentHandler: { legacyOpenCount += 1 }
        )
        let presenter = PromptPresenterSpy()
        dispatcher.presentation = presenter

        dispatcher.dispatch(.documentOpen)

        #expect(presenter.recentFilesOpenCount == 1)
        #expect(legacyOpenCount == 0)
    }
    @Test("help.show presents the keyboard help workflow")
    func helpShowPresentsHelp() {
        let dispatcher = ActionDispatcher(
            coordinator: PaneCoordinator(initialStore: ReaderSessionStore()),
            navigation: BuiltInDefaults.config.navigation
        )
        let presenter = PromptPresenterSpy()
        dispatcher.presentation = presenter

        dispatcher.dispatch(.helpShow)

        #expect(presenter.helpCount == 1)
    }

    @Test("link.hint presents link hints")
    func linkHintPresentsLinkHints() {
        let dispatcher = ActionDispatcher(
            coordinator: PaneCoordinator(initialStore: ReaderSessionStore()),
            navigation: BuiltInDefaults.config.navigation
        )
        let presenter = PromptPresenterSpy()
        dispatcher.presentation = presenter

        dispatcher.dispatch(.linkHint)

        #expect(presenter.linkHintsCount == 1)
    }


    @Test("app.new dispatches to the new-instance launcher only")
    func appNewLaunchesNewInstance() {
        let store = ReaderSessionStore()
        let session = RecordingReaderSession(title: "Doc.pdf")
        #expect(store.insert(session))
        var newInstanceCount = 0
        var quitCount = 0
        let coordinator = PaneCoordinator(initialStore: store)
        let dispatcher = ActionDispatcher(
            coordinator: coordinator,
            navigation: BuiltInDefaults.config.navigation,
            terminationHandler: { quitCount += 1 },
            newInstanceHandler: { newInstanceCount += 1 }
        )

        dispatcher.dispatch(.appNew)
        #expect(newInstanceCount == 1)
        #expect(quitCount == 0)
        #expect(store.activeSession?.id == session.id)
    }

    @Test("tab movement and close retain the store as the sole session owner")
    func tabActions() {
        let store = ReaderSessionStore()
        let first = RecordingReaderSession(title: "First.pdf")
        let second = RecordingReaderSession(title: "Second.pdf")
        let third = RecordingReaderSession(title: "Third.pdf")
        #expect(store.insert(first))
        #expect(store.insert(second))
        #expect(store.insert(third))
        let coordinator = PaneCoordinator(initialStore: store)
        let dispatcher = ActionDispatcher(coordinator: coordinator, navigation: BuiltInDefaults.config.navigation)

        dispatcher.dispatch(.tabPrevious)
        #expect(store.activeSession?.id == second.id)
        dispatcher.dispatch(.tabNext)
        #expect(store.activeSession?.id == third.id)
        dispatcher.dispatch(.tabSelect1)
        #expect(store.activeSession?.id == first.id)
        dispatcher.dispatch(.tabSelect9)
        #expect(store.activeSession?.id == first.id)
        dispatcher.dispatch(.documentClose)

        #expect(first.prepareForCloseCount == 1)
        #expect(store.activeSession?.id == second.id)
    }

    @Test("semantic page replay, validation, commit, and cancel restore reader focus")
    func pagePromptWorkflow() throws {
        let store = ReaderSessionStore()
        let session = RecordingReaderSession(title: "Reference.pdf", pageCount: 24)
        #expect(store.insert(session))
        let presenter = PromptPresenterSpy()
        let coordinator = PaneCoordinator(initialStore: store)
        let dispatcher = ActionDispatcher(coordinator: coordinator, navigation: BuiltInDefaults.config.navigation)
        dispatcher.presentation = presenter
        let one = try KeySequenceParser.parseSingleToken("1")

        dispatcher.dispatch(
            KeyActionDispatch(
                actionID: .pagePrompt,
                transitionedContext: .pagePrompt,
                semanticReplay: SemanticKeyReplay(
                    token: one,
                    tokenClass: .decimalDigit,
                    targetContext: .pagePrompt
                )
            )
        )
        #expect(presenter.presentation?.text == "1")

        presenter.promptText = "0"
        dispatcher.dispatch(.promptCommit)
        #expect(presenter.validationMessage == "Page numbers start at 1.")
        #expect(presenter.dismissReasons.isEmpty)

        presenter.promptText = "12"
        dispatcher.dispatch(.promptCommit)
        #expect(session.events.last == .goToPage(12))
        #expect(presenter.dismissReasons == [.promptCommitted])

        dispatcher.dispatch(.pagePrompt)
        dispatcher.dispatch(.promptCancel)
        #expect(presenter.dismissReasons == [.promptCommitted, .promptCancelled])
    }

    @Test("menu clicks and key events converge on the same dispatcher entry point")
    func menuAndKeyConvergence() throws {
        let validated = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        let store = ReaderSessionStore()
        let session = RecordingReaderSession(title: "Reference.pdf")
        #expect(store.insert(session))
        let coordinator = PaneCoordinator(initialStore: store)
        let dispatcher = ActionDispatcher(coordinator: coordinator, navigation: BuiltInDefaults.config.navigation)
        let menuBuilder = ValidatedMenuBuilder(descriptors: validated.menuDescriptors) {
            dispatcher.dispatch($0)
        }
        let menu = menuBuilder.makeMainMenu()
        let fitWidth = try #require(menu.descendantItem(title: "Fit Width"))
        let action = try #require(fitWidth.action)

        _ = fitWidth.target?.perform(action, with: fitWidth)
        dispatcher.dispatch(KeyActionDispatch(actionID: .viewFitWidth))

        #expect(session.events == [.fitWidth, .fitWidth])
    }

    @Test("prompt-safe globals discard marked composition and restore context before key or menu effects")
    func promptSafeGlobalLifecycle() throws {
        let validated = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        let store = ReaderSessionStore()
        let session = RecordingReaderSession(title: "Reference.pdf")
        var openCount = 0
        var quitCount = 0
        let coordinator = PaneCoordinator(initialStore: store)
        let dispatcher = ActionDispatcher(
            coordinator: coordinator,
            navigation: BuiltInDefaults.config.navigation,
            openDocumentHandler: { openCount += 1 },
            terminationHandler: { quitCount += 1 }
        )
        let controller = MainWindowController(
            coordinator: coordinator,
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { dispatcher.dispatch($0) },
            keyDispatchHandler: { dispatcher.dispatch($0) },
            validatedConfig: validated
        )
        dispatcher.presentation = controller
        #expect(store.insert(session))

        controller.presentPrompt(PromptPresentation(kind: .search, text: "", validationMessage: nil))
        let openEditor = try #require(
            controller.rootView.promptOverlay.textField.currentEditor() as? NSTextView
        )
        openEditor.setMarkedText(
            "조합",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(openEditor.hasMarkedText())

        #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(
            characters: "o",
            modifiers: [.command]
        ))))
        #expect(!controller.rootView.recentFilesOverlay.isHidden)
        #expect(!openEditor.hasMarkedText())
        #expect(!controller.rootView.promptOverlay.discardMarkedComposition())
        #expect(controller.rootView.promptOverlay.isHidden)
        #expect(controller.inputContextForTesting == .navigation)
        #expect(controller.window?.firstResponder === controller.rootView.recentFilesOverlay)

        controller.presentPrompt(PromptPresentation(kind: .page, text: "", validationMessage: nil))
        let quitEditor = try #require(
            controller.rootView.promptOverlay.textField.currentEditor() as? NSTextView
        )
        quitEditor.setMarkedText(
            "ㅎ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(quitEditor.hasMarkedText())

        let menuBuilder = ValidatedMenuBuilder(descriptors: validated.menuDescriptors) {
            dispatcher.dispatch($0)
        }
        let menu = menuBuilder.makeMainMenu()
        let quit = try #require(menu.descendantItem(title: "Quit Modeleaf"))
        let quitAction = try #require(quit.action)
        _ = quit.target?.perform(quitAction, with: quit)

        #expect(quitCount == 1)
        #expect(!quitEditor.hasMarkedText())
        #expect(!controller.rootView.promptOverlay.discardMarkedComposition())
        #expect(controller.rootView.promptOverlay.isHidden)
        #expect(controller.inputContextForTesting == .navigation)
        #expect(controller.window?.firstResponder === session.focusView)
    }

    @Test("remapped prompt-safe global uses Command-F12 and tears down marked composition")
    func remappedPromptSafeGlobalLifecycle() throws {
        let validated = try #require(ConfigValidator.validate(SparseAppConfig(
            keymap: [ActionID.documentOpen.rawValue: ["<D-F12>"]]
        )).validatedConfig)
        let store = ReaderSessionStore()
        let session = RecordingReaderSession(title: "Reference.pdf")
        var openCount = 0
        let coordinator = PaneCoordinator(initialStore: store)
        let dispatcher = ActionDispatcher(
            coordinator: coordinator,
            navigation: BuiltInDefaults.config.navigation,
            openDocumentHandler: { openCount += 1 }
        )
        let controller = MainWindowController(
            coordinator: coordinator,
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { dispatcher.dispatch($0) },
            keyDispatchHandler: { dispatcher.dispatch($0) },
            validatedConfig: validated
        )
        dispatcher.presentation = controller
        #expect(store.insert(session))

        controller.presentPrompt(PromptPresentation(kind: .search, text: "", validationMessage: nil))
        let editor = try #require(
            controller.rootView.promptOverlay.textField.currentEditor() as? NSTextView
        )
        editor.setMarkedText(
            "조합",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(editor.hasMarkedText())
        let f12 = try #require(UnicodeScalar(NSF12FunctionKey).map(String.init))

        #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(
            characters: f12,
            modifiers: [.command]
        ))))

        #expect(!controller.rootView.recentFilesOverlay.isHidden)
        #expect(!editor.hasMarkedText())
        #expect(!controller.rootView.promptOverlay.discardMarkedComposition())
        #expect(controller.rootView.promptOverlay.isHidden)
        #expect(controller.inputContextForTesting == .navigation)
        #expect(controller.window?.firstResponder === controller.rootView.recentFilesOverlay)
    }

    @Test("session changes discard marked composition before dismissing the prompt")
    func sessionChangeDiscardsMarkedComposition() throws {
        let validated = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        let store = ReaderSessionStore()
        let first = RecordingReaderSession(title: "First.pdf")
        let second = RecordingReaderSession(title: "Second.pdf")
        let coordinator = PaneCoordinator(initialStore: store)
        let dispatcher = ActionDispatcher(coordinator: coordinator, navigation: BuiltInDefaults.config.navigation)
        let controller = MainWindowController(
            coordinator: coordinator,
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { dispatcher.dispatch($0) },
            keyDispatchHandler: { dispatcher.dispatch($0) },
            validatedConfig: validated
        )
        dispatcher.presentation = controller
        #expect(store.insert(first))
        #expect(store.insert(second))
        #expect(store.activate(first.id))

        controller.presentPrompt(PromptPresentation(kind: .search, text: "", validationMessage: nil))
        let editor = try #require(
            controller.rootView.promptOverlay.textField.currentEditor() as? NSTextView
        )
        editor.setMarkedText(
            "조합",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(editor.hasMarkedText())

        #expect(store.activate(second.id))

        #expect(!editor.hasMarkedText())
        #expect(!controller.rootView.promptOverlay.discardMarkedComposition())
        #expect(controller.rootView.promptOverlay.isHidden)
        #expect(controller.inputContextForTesting == .navigation)
        #expect(controller.window?.firstResponder === second.focusView)
    }

    @Test("window input, page prompt status, commit, and focus restoration form one workflow")
    func integratedPagePromptAndFocus() throws {
        let validated = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        let store = ReaderSessionStore()
        let session = RecordingReaderSession(title: "Reference.pdf", pageCount: 24)
        let coordinator = PaneCoordinator(initialStore: store)
        let dispatcher = ActionDispatcher(coordinator: coordinator, navigation: BuiltInDefaults.config.navigation)
        let controller = MainWindowController(
            coordinator: coordinator,
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { dispatcher.dispatch($0) },
            keyDispatchHandler: { dispatcher.dispatch($0) },
            validatedConfig: validated
        )
        dispatcher.presentation = controller
        #expect(store.insert(session))

        #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "g"))))
        #expect(controller.rootView.statusBar.presentation.pendingPrefix == "g")
        #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "1"))))
        #expect(controller.rootView.promptOverlay.activeText == "1")
        #expect(controller.inputContextForTesting == .pagePrompt)
        #expect(controller.rootView.statusBar.presentation.pendingPrefix.isEmpty)

        controller.rootView.promptOverlay.textField.stringValue = "12"
        #expect(controller.routeKeyEventForTesting(
            try #require(makeKeyEvent(characters: "\r", keyCode: 36))
        ))

        #expect(session.events.last == .goToPage(12))
        #expect(controller.rootView.promptOverlay.isHidden)
        #expect(controller.inputContextForTesting == .navigation)
        #expect(controller.window?.firstResponder === session.focusView)
    }

    @Test("page input in an empty window cannot leave an invisible PAGE context")
    func emptyPagePromptReturnsToNavigation() throws {
        let validated = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        let store = ReaderSessionStore()
        let coordinator = PaneCoordinator(initialStore: store)
        let dispatcher = ActionDispatcher(coordinator: coordinator, navigation: BuiltInDefaults.config.navigation)
        let controller = MainWindowController(
            coordinator: coordinator,
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { dispatcher.dispatch($0) },
            keyDispatchHandler: { dispatcher.dispatch($0) },
            validatedConfig: validated
        )
        dispatcher.presentation = controller

        #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "g"))))
        #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "1"))))

        #expect(controller.inputContextForTesting == .navigation)
        #expect(controller.rootView.promptOverlay.isHidden)
        #expect(controller.rootView.statusBar.presentation.pendingPrefix.isEmpty)
    }

    @Test("search is committed once, navigates results, and clears back to NORMAL")
    func committedSearchWorkflow() {
        let store = ReaderSessionStore()
        let session = RecordingReaderSession(title: "Reference.pdf")
        #expect(store.insert(session))
        let presenter = PromptPresenterSpy()
        let coordinator = PaneCoordinator(initialStore: store)
        let dispatcher = ActionDispatcher(coordinator: coordinator, navigation: BuiltInDefaults.config.navigation)
        dispatcher.presentation = presenter

        dispatcher.dispatch(.searchPrompt)
        #expect(presenter.presentation?.kind == .search)
        #expect(session.events.isEmpty)

        presenter.promptText = "   "
        dispatcher.dispatch(.promptCommit)
        #expect(presenter.validationMessage == "Enter text to search.")
        #expect(session.events.isEmpty)

        presenter.promptText = "  needle  "
        dispatcher.dispatch(.promptCommit)
        #expect(session.events == [.beginSearch("needle")])
        #expect(presenter.dismissContexts.last == .searchResults)

        dispatcher.dispatch(.searchNext)
        dispatcher.dispatch(.searchPrevious)
        dispatcher.dispatch(.searchCancel)
        #expect(session.events == [
            .beginSearch("needle"), .nextSearchResult, .previousSearchResult, .clearSearch,
        ])
        #expect(presenter.dismissContexts.last == .navigation)
    }

    @Test("slash prompt, result keys, focus, and per-tab SEARCH context remain isolated")
    func integratedSearchFocusAndTabIsolation() throws {
        let validated = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        let store = ReaderSessionStore()
        let first = RecordingReaderSession(title: "First.pdf")
        let second = RecordingReaderSession(title: "Second.pdf")
        let coordinator = PaneCoordinator(initialStore: store)
        let dispatcher = ActionDispatcher(coordinator: coordinator, navigation: BuiltInDefaults.config.navigation)
        let controller = MainWindowController(
            coordinator: coordinator,
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { dispatcher.dispatch($0) },
            keyDispatchHandler: { dispatcher.dispatch($0) },
            validatedConfig: validated
        )
        dispatcher.presentation = controller
        #expect(store.insert(first))
        #expect(store.insert(second))
        #expect(store.activate(first.id))

        #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "/"))))
        #expect(controller.inputContextForTesting == .searchPrompt)
        #expect(
            controller.window?.firstResponder
                === controller.rootView.promptOverlay.textField.currentEditor()
        )
        controller.rootView.promptOverlay.textField.stringValue = "needle"
        #expect(controller.routeKeyEventForTesting(
            try #require(makeKeyEvent(characters: "\r", keyCode: 36))
        ))

        #expect(first.searchSnapshot.query == "needle")
        #expect(second.searchSnapshot == .empty)
        #expect(controller.rootView.promptOverlay.isHidden)
        #expect(controller.inputContextForTesting == .searchResults)
        #expect(controller.window?.firstResponder === first.focusView)

        #expect(controller.routeKeyEventForTesting(
            try #require(makeKeyEvent(characters: "\r", keyCode: 36))
        ))
        #expect(controller.routeKeyEventForTesting(
            try #require(makeKeyEvent(
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                modifiers: [.shift],
                keyCode: 36
            ))
        ))
        #expect(first.events.suffix(2) == [.nextSearchResult, .previousSearchResult])

        #expect(store.activate(second.id))
        #expect(controller.inputContextForTesting == .navigation)
        #expect(store.activate(first.id))
        #expect(controller.inputContextForTesting == .searchResults)

        #expect(controller.routeKeyEventForTesting(
            try #require(makeKeyEvent(characters: "\u{1B}", keyCode: 53))
        ))
        #expect(first.searchSnapshot == .empty)
        #expect(controller.inputContextForTesting == .navigation)
        #expect(controller.window?.firstResponder === first.focusView)
    }
}

private enum RecordingReaderEvent: Equatable {
    case scroll(x: Double, y: Double)
    case viewport(Double)
    case nextPage
    case previousPage
    case firstPage
    case lastPage
    case goToPage(Int)
    case zoom(Double)
    case resetZoom
    case fitWidth
    case fitPage
    case rotateLeft
    case rotateRight
    case printDocument
    case goBack
    case goForward
    case beginSearch(String)
    case nextSearchResult
    case previousSearchResult
    case clearSearch
}

@MainActor
private final class RecordingReaderSession: ReaderSessionPresenting, ReaderNavigationHistoryPresenting {
    func applyTheme(_ theme: AppKitTheme) {}
    let id = TabID()
    let title: String
    let contentView: NSView = ActionDispatcherFocusableView()
    let pageCount: Int
    let sourceURL: URL
    private(set) var events: [RecordingReaderEvent] = []
    private(set) var prepareForCloseCount = 0
    private(set) var searchSnapshot = ReaderSearchSnapshot.empty
    var canGoBack: Bool { true }
    var canGoForward: Bool { true }
    var isNavigationHistoryHealthy: Bool { true }
    var navigationAvailabilityDetail: String { "History available" }

    init(title: String, pageCount: Int = 10) {
        self.title = title
        self.pageCount = pageCount
        self.sourceURL = URL(fileURLWithPath: "/tmp/\(title)")
    }

    var statusSnapshot: ReaderStatusSnapshot {
        ReaderStatusSnapshot(context: "NORMAL", page: "1 / \(pageCount)", zoom: "100%", detail: title)
    }

    func scrollBy(xPoints: Double, yPoints: Double) { events.append(.scroll(x: xPoints, y: yPoints)) }
    func scrollVerticallyByViewportFraction(_ fraction: Double) { events.append(.viewport(fraction)) }
    func goToNextPage() -> Bool { events.append(.nextPage); return true }
    func goToPreviousPage() -> Bool { events.append(.previousPage); return true }
    func goToFirstPage() -> Bool { events.append(.firstPage); return true }
    func goToLastPage() -> Bool { events.append(.lastPage); return true }
    func goBack() -> NavigationTransactionOutcome { events.append(.goBack); return .verifiedLanding }
    func goForward() -> NavigationTransactionOutcome { events.append(.goForward); return .verifiedLanding }
    func goToPage(_ oneBasedPage: Int) -> Bool { events.append(.goToPage(oneBasedPage)); return true }
    func zoom(by factor: Double) { events.append(.zoom(factor)) }
    func resetZoom() { events.append(.resetZoom) }
    func fitWidth() { events.append(.fitWidth) }
    func fitPage() { events.append(.fitPage) }
    func rotateLeft() { events.append(.rotateLeft) }
    func rotateRight() { events.append(.rotateRight) }
    func printDocument() -> Bool { events.append(.printDocument); return true }
    func beginSearch(_ query: String) {
        events.append(.beginSearch(query))
        searchSnapshot = ReaderSearchSnapshot(
            query: query,
            matchCount: 3,
            activeMatchIndex: 0,
            isRunning: false
        )
    }
    func selectNextSearchResult() -> Bool { events.append(.nextSearchResult); return true }
    func selectPreviousSearchResult() -> Bool { events.append(.previousSearchResult); return true }
    func clearSearch() { events.append(.clearSearch); searchSnapshot = .empty }
    func prepareForClose() { prepareForCloseCount += 1 }
}

@MainActor
private final class ActionDispatcherFocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class PromptPresenterSpy: ReaderWorkflowPresenting {
    var linkHintsCount = 0
    var tocToggleCount = 0
    var tocScrollDownCount = 0
    var tocScrollUpCount = 0
    func presentLinkHints() { linkHintsCount += 1 }
    func presentHelp() { helpCount += 1 }
    var presentation: PromptPresentation?
    var helpCount = 0
    var promptText = ""
    var validationMessage: String?
    var dismissReasons: [KeyInputInvalidationReason] = []
    var dismissContexts: [InputContext] = []
    var globalPreparationCount = 0
    var actionFeedback: [(String, Bool)] = []

    var activePromptKind: ReaderPromptKind? { presentation?.kind }
    var recentFilesOpenCount = 0
    var activePromptText: String { promptText }

    func presentThemePicker() {}
    func toggleTOCDrawer() { tocToggleCount += 1 }
    func scrollTOCDrawerDown() { tocScrollDownCount += 1 }
    func scrollTOCDrawerUp() { tocScrollUpCount += 1 }
    func presentCommandPalette() {}
    func presentRecentFilesOpen() { recentFilesOpenCount += 1 }
    func presentPrompt(_ presentation: PromptPresentation) {
        self.presentation = presentation
        promptText = presentation.text
        validationMessage = presentation.validationMessage
    }

    func showPromptValidation(_ message: String) {
        validationMessage = message
    }
    func showActionFeedback(_ message: String, isError: Bool) {
        actionFeedback.append((message, isError))
    }

    func prepareForGlobalAction() {
        globalPreparationCount += 1
    }

    func dismissPromptAndRestoreFocus(
        to context: InputContext,
        reason: KeyInputInvalidationReason
    ) {
        presentation = nil
        promptText = ""
        validationMessage = nil
        dismissContexts.append(context)
        dismissReasons.append(reason)
    }
}

private extension NSMenu {
    func descendantItem(title: String) -> NSMenuItem? {
        for item in items {
            if item.title == title { return item }
            if let nested = item.submenu?.descendantItem(title: title) { return nested }
        }
        return nil
    }
}
