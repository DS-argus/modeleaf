import AppKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("Viewer-first action dispatcher")
@MainActor
struct ActionDispatcherTests {
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
        ])
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
        #expect(openCount == 1)
        #expect(!openEditor.hasMarkedText())
        #expect(!controller.rootView.promptOverlay.discardMarkedComposition())
        #expect(controller.rootView.promptOverlay.isHidden)
        #expect(controller.inputContextForTesting == .navigation)
        #expect(controller.window?.firstResponder === session.focusView)

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

        #expect(openCount == 1)
        #expect(!editor.hasMarkedText())
        #expect(!controller.rootView.promptOverlay.discardMarkedComposition())
        #expect(controller.rootView.promptOverlay.isHidden)
        #expect(controller.inputContextForTesting == .navigation)
        #expect(controller.window?.firstResponder === session.focusView)
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
    case beginSearch(String)
    case nextSearchResult
    case previousSearchResult
    case clearSearch
}

@MainActor
private final class RecordingReaderSession: ReaderSessionPresenting {
    func applyTheme(_ theme: AppKitTheme) {}
    let id = TabID()
    let title: String
    let contentView: NSView = ActionDispatcherFocusableView()
    let pageCount: Int
    private(set) var events: [RecordingReaderEvent] = []
    private(set) var prepareForCloseCount = 0
    private(set) var searchSnapshot = ReaderSearchSnapshot.empty

    init(title: String, pageCount: Int = 10) {
        self.title = title
        self.pageCount = pageCount
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
    func goToPage(_ oneBasedPage: Int) -> Bool { events.append(.goToPage(oneBasedPage)); return true }
    func zoom(by factor: Double) { events.append(.zoom(factor)) }
    func resetZoom() { events.append(.resetZoom) }
    func fitWidth() { events.append(.fitWidth) }
    func fitPage() { events.append(.fitPage) }
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
    var presentation: PromptPresentation?
    var promptText = ""
    var validationMessage: String?
    var dismissReasons: [KeyInputInvalidationReason] = []
    var dismissContexts: [InputContext] = []
    var globalPreparationCount = 0

    var activePromptKind: ReaderPromptKind? { presentation?.kind }
    var activePromptText: String { promptText }

    func presentThemePicker() {}
    func presentPrompt(_ presentation: PromptPresentation) {
        self.presentation = presentation
        promptText = presentation.text
        validationMessage = presentation.validationMessage
    }

    func showPromptValidation(_ message: String) {
        validationMessage = message
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
