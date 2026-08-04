import AppKit
import Foundation
import PDFKit
import PDFReaderCore
import CryptoKit
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("N11 native navigation red team", .serialized)
@MainActor
struct N11NavigationRedTeamTests {
    @Test("N11 exact native navigation evidence")
    func nativeNavigationMatrix() throws {
        let sourceHash = try n11EvidenceSourceHash()
        try withTemporaryDirectory { directory in
            let sourceURL = try PDFFixtureFactory.makeTextPDF(in: directory, name: "n11-native.pdf", pageCount: 4)
            let sourceDocument = try #require(PDFDocument(url: sourceURL))
            let sourcePage = try #require(sourceDocument.page(at: 0))
            let targetPage = try #require(sourceDocument.page(at: 1))
            let link = PDFAnnotation(bounds: CGRect(x: 48, y: 700, width: 80, height: 12), forType: .link, withProperties: nil)
            link.action = PDFActionGoTo(destination: PDFDestination(page: targetPage, at: CGPoint(x: 48, y: 700)))
            sourcePage.addAnnotation(link)
            try #require(sourceDocument.write(to: sourceURL))
            let sourceBytes = try Data(contentsOf: sourceURL)
            let sourceDigest = try PDFFixtureFactory.sha256(of: sourceURL)
            var transcript: [N11TranscriptEvent] = []
            var cases: [N11CaseResult] = []

            // VE01: PDFKit's mouse GoTo path, then the complete browser-order branch.
            let mounted = try openMountedSession(url: sourceURL)
            let session = mounted.session
            defer { session.prepareForClose() }
            let view = try #require(descendantReaderPDFViews(in: session.contentView).only)
            let promptStore = ReaderSessionStore()
            let promptCoordinator = PaneCoordinator(initialStore: promptStore)
            var promptDispatcher: ActionDispatcher?
            let validated = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
            let promptController = MainWindowController(
                coordinator: promptCoordinator,
                theme: AppKitTheme(themeID: .tokyoNight),
                actionHandler: { action in promptDispatcher?.dispatch(action) },
                keyDispatchHandler: { dispatch in promptDispatcher?.dispatch(dispatch) },
                validatedConfig: validated
            )
            let dispatcher = ActionDispatcher(coordinator: promptCoordinator, navigation: validated.config.navigation)
            promptDispatcher = dispatcher
            dispatcher.presentation = promptController
            defer { promptController.close(); while promptCoordinator.closeActiveTab() {} }
            try #require(promptStore.insert(session))
            let destinationPage = try #require(view.document?.page(at: 1))
            view.perform(PDFActionGoTo(destination: PDFDestination(page: destinationPage, at: CGPoint(x: 48, y: 700))))
            try #require(session.currentPageNumber == 2)
            try #require(session.goBack() == .verifiedLanding)
            try #require(session.currentPageNumber == 1)
            try #require(session.goForward() == .verifiedLanding)
            try #require(session.currentPageNumber == 2)
            try #require(promptController.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "g"))))
            try #require(promptController.rootView.statusBar.presentation.pendingPrefix == "g")
            try #require(promptController.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "3"))))
            try #require(promptController.inputContextForTesting == .pagePrompt)
            try #require(promptController.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36))))
            try #require(session.currentPageNumber == 3 && promptController.inputContextForTesting == .navigation)
            try #require(session.currentPageNumber == 3)
            try #require(session.goBack() == .verifiedLanding)
            try #require(session.currentPageNumber == 2)
            try #require(session.goToFirstPage())
            try #require(session.currentPageNumber == 1)
            try #require(session.goToLastPage())
            try #require(session.currentPageNumber == 4)
            try #require(!session.canGoForward)
            try #require(view.blockedHistoryCount == 0)
            transcript.append(.init(id: "N11-VE01", operation: "mouseGoTo(2); Back; Forward; pagePrompt(3); Back; first; last(branch)", page: 4))
            cases.append(.passed("N11-VE01", "PDFActionGoTo mouse path and every approved traversal/branch assertion executed."))
            // VE02 needs deterministic, distinct A/S1/M/S2 landings rather than PDFKit timing.
            let navigation = N11SearchNavigation()
            let searchDriver = N11SearchDriver()
            let searchPresenter = N11SearchPresenter(navigation: navigation)
            var search: ReaderSearchCoordinator!
            let searchSession = ReaderSession(
                sourceURL: sourceURL,
                document: try #require(PDFDocument(url: sourceURL)),
                searchControllerFactory: { activate, reportOutcome in
                    let coordinator = ReaderSearchCoordinator(
                        driver: searchDriver,
                        presenter: searchPresenter,
                        scheduler: searchDriver,
                        activateNavigation: activate,
                        reportNavigationOutcome: reportOutcome
                    )
                    search = coordinator
                    return coordinator
                },
                navigationCapture: { navigation.capture() },
                navigationRestore: { destination in navigation.current = destination; return .verifiedLanding }
            )
            defer { searchSession.prepareForClose() }
            let a = navigation.position(0), s1 = navigation.position(1), s2 = navigation.position(2), m = navigation.position(3)
            search.request("alpha")
            let alpha = try #require(searchDriver.generations.last)
            searchPresenter.nextLanding = s1
            searchDriver.match(alpha); searchDriver.end(alpha)
            searchPresenter.nextLanding = s2
            try #require(search.selectNext())
            try #require(searchSession.goBack() == .verifiedLanding && navigation.current == a)
            try #require(searchSession.goForward() == .verifiedLanding && navigation.current == s2)
            try #require(searchSession.goBack() == .verifiedLanding && navigation.current == a)
            search.request("branch")
            let branch = try #require(searchDriver.generations.last)
            searchPresenter.nextLanding = s1
            searchDriver.match(branch); searchDriver.end(branch)
            try #require(!searchSession.canGoForward)
            try #require(search.selectNext())
            try #require(!searchSession.canGoForward)
            search.request("pending")
            let pending = try #require(searchDriver.generations.last)
            try #require(searchSession.performNavigation(.meaningfulJump(producer: .pagePrompt, destination: m)) == .verifiedLanding)
            searchDriver.end(pending)
            search.request("beta")
            let beta = try #require(searchDriver.generations.last)
            searchPresenter.nextLanding = s2
            searchDriver.match(beta); searchDriver.end(beta)
            try #require(searchSession.goBack() == .verifiedLanding && navigation.current == m)
            try #require(searchSession.goBack() == .verifiedLanding && navigation.current == s1)
            try #require(searchSession.goBack() == .verifiedLanding && navigation.current == a)
            try #require(searchSession.goForward() == .verifiedLanding && navigation.current == s1)
            try #require(searchSession.goForward() == .verifiedLanding && navigation.current == m)
            try #require(searchSession.goForward() == .verifiedLanding && navigation.current == s2)
            search.request("old")
            let old = try #require(searchDriver.generations.last)
            search.request("replacement")
            searchDriver.end(old); searchDriver.runNext()
            let replacement = try #require(searchDriver.generations.last)
            searchPresenter.nextLanding = s1
            searchDriver.match(old); searchDriver.end(old)
            searchDriver.match(replacement); searchDriver.end(replacement)
            let ignoredBeforeClear = search.ignoredCallbackCount
            searchSession.clearSearch()
            search.request("restart")
            searchDriver.match(replacement); searchDriver.end(replacement)
            let restart = try #require(searchDriver.generations.last)
            searchDriver.end(restart)
            try #require(search.ignoredCallbackCount >= ignoredBeforeClear + 2)
            transcript.append(.init(id: "N11-VE02", operation: "A/S1/S2; Back/Forward; M; S2; replacement; clear/restart", page: nil))
            cases.append(.passed("N11-VE02", "A/S1/M/S2 epoch, replacement stale callbacks, clear, restart, and branch traversals asserted."))

            // VE03: production key adaptation/routing plus every modal saved-context path.
            try assertN11InputRouting(url: sourceURL)
            transcript.append(.init(id: "N11-VE03", operation: "physical Ctrl+i versus Tab; default/remapped/repeat history; palette, prompts, recent/theme/help/link modal restoration", page: nil))
            cases.append(.passed("N11-VE03", "Physical Ctrl+i and hardware Tab tokens, default/remapped repeat-suppressed history routing, all non-navigation contexts, modal palette reasons, and saved-context restoration asserted."))

            // VE04: the routed first hint is the source PDF's internal GoTo target.
            try withLinkHarness(url: sourceURL) { controller, linkSession, linkView in
                let goToPage = try #require(linkView.document?.page(at: 1))
                let goTo = PDFActionGoTo(destination: PDFDestination(page: goToPage, at: CGPoint(x: 48, y: 700)))
                linkView.perform(goTo)
                try #require(linkSession.currentPageNumber == 2)
                try #require(linkSession.goBack() == .verifiedLanding && linkSession.currentPageNumber == 1)
                try #require(!linkSession.canGoBack && linkSession.canGoForward)
                controller.presentLinkHints()
                try #require(!controller.rootView.linkHintOverlay.isHidden)
                try #require(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "f"))))
                try #require(linkSession.currentPageNumber == 2)
                try #require(linkSession.goBack() == .verifiedLanding && linkSession.currentPageNumber == 1)
                try #require(!linkSession.canGoBack)
                try #require(linkSession.goForward() == .verifiedLanding && linkSession.currentPageNumber == 2)
                try #require(!linkSession.canGoForward && linkView.blockedActionCount == 0)
                let historyBeforeExcludedLinks = (linkSession.canGoBack, linkSession.canGoForward, linkSession.currentPageNumber)
                var opened: [URL] = []
                linkView.followLinkHandler = { opened.append($0) }
                linkView.perform(PDFActionURL(url: URL(string: "https://example.invalid/n11-external")!))
                try #require(opened == [URL(string: "https://example.invalid/n11-external")!])
                try #require((linkSession.canGoBack, linkSession.canGoForward, linkSession.currentPageNumber) == historyBeforeExcludedLinks)
                let foreignPage = PDFPage()
                linkView.perform(PDFActionGoTo(destination: PDFDestination(page: foreignPage, at: .zero)))
                try #require((linkSession.canGoBack, linkSession.canGoForward, linkSession.currentPageNumber) == historyBeforeExcludedLinks)
                try #require(linkView.followedLinkCount == 1 && linkView.blockedActionCount == 1)
            }
            transcript.append(.init(id: "N11-VE04", operation: "PDFActionGoTo; Back; routed f internal GoTo; Back/Forward single-entry convergence; external URL and unresolved GoTo preserve history", page: 2))
            cases.append(.passed("N11-VE04", "PDFActionGoTo and MainWindowController-routed f converge on the internal GoTo landing; Back/Forward proves exactly one history entry; external and unresolved targets are history-excluded."))

            // VE05: production sessions retain history per tab/pane, and duplicate/reopen sessions begin clean.
            let firstStore = ReaderSessionStore()
            let historyCoordinator = PaneCoordinator(initialStore: firstStore)
            let first = try PDFOpenService().open(url: sourceURL)
            let second = try PDFOpenService().open(url: sourceURL)
            defer { while historyCoordinator.closeActiveTab() {} }
            try #require(firstStore.insert(first) && firstStore.insert(second))
            try #require(historyCoordinator.activate(tab: first.id))
            try #require(first.goToPage(2) && first.goToPage(3))
            try #require(first.goBack() == .verifiedLanding && first.currentPageNumber == 2)
            try #require(historyCoordinator.activate(tab: second.id))
            try #require(second.goToPage(4) && second.canGoBack && !second.canGoForward)
            try #require(second.currentPageNumber == 4 && first.canGoBack)
            let historyWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
            historyCoordinator.onSnapshot = { snapshot in
                guard let content = snapshot.activeContentView else { return }
                historyWindow.contentView = content; content.frame = historyWindow.contentLayoutRect; content.layoutSubtreeIfNeeded()
            }
            historyCoordinator.configureDuplication { snapshot in
                let duplicate = try? PDFOpenService().open(url: snapshot.sourceURL)
                duplicate?.seedPendingPresentation(ReaderDuplicationSnapshot(sourceURL: snapshot.sourceURL, navigation: snapshot.navigation))
                return duplicate
            }
            try #require(historyCoordinator.activate(tab: second.id))
            let secondView = try #require(descendantReaderPDFViews(in: second.contentView).only)
            let anchoredPage = try #require(secondView.document?.page(at: 1))
            secondView.perform(PDFActionGoTo(destination: PDFDestination(page: anchoredPage, at: CGPoint(x: 48, y: 700))))
            let nonCenterAnchor = try #require(second.duplicationSnapshot?.navigation)
            try #require(nonCenterAnchor.pageIndex == 1)
            try #require(nonCenterAnchor.pageSpacePoint != CGPoint(x: 306, y: 396))
            let duplicatePane = try #require(historyCoordinator.split(direction: .sideBySide))
            let duplicate = try #require(historyCoordinator.activeSession as? ReaderSession)
            try #require(duplicate.id != second.id && !duplicate.canGoBack && !duplicate.canGoForward)
            try #require(historyCoordinator.activatePane(try #require(historyCoordinator.snapshot.layout.paneIDs.first { $0 != duplicatePane })))
            try #require(historyCoordinator.activate(tab: first.id) && first.goBack() == .verifiedLanding && first.currentPageNumber == 1)
            try #require(historyCoordinator.activatePane(duplicatePane) && duplicate.currentPageNumber == second.currentPageNumber)
            let duplicateAnchor = try #require(duplicate.duplicationSnapshot?.navigation)
            try #require(duplicateAnchor.isSameLocation(as: nonCenterAnchor))
            while historyCoordinator.closeActiveTab() {}
            let reopened = try PDFOpenService().open(url: sourceURL)
            try #require(historyCoordinator.insert(reopened, into: .createIfEmpty))
            try #require(!reopened.canGoBack && !reopened.canGoForward)
            transcript.append(.init(id: "N11-VE05", operation: "two real tabs; split seeded PDFOpenService duplicate; pane/tab switches; close all; reopen", page: nil))
            cases.append(.passed("N11-VE05", "Real ReaderSession/ReaderSessionStore histories stay independent across two tabs and split panes; seeded duplicate and fresh reopen have empty history."))

            let origin = try #require(NavigationSnapshot(pageIndex: 0, pageSpacePoint: .zero))
            let destination = try #require(NavigationSnapshot(pageIndex: 1, pageSpacePoint: .zero))
            // VE06: a post-attempt capture failure compensates successfully, while a failed compensation closes history.
            let compensated = N11NavigationScript(captures: [origin, nil], restores: [.verifiedLanding, .verifiedLanding])
            let compensatedSession = ReaderSession(sourceURL: sourceURL, document: try #require(PDFDocument(url: sourceURL)), navigationCapture: { compensated.capture() }, navigationRestore: { compensated.restore($0) })
            defer { compensatedSession.prepareForClose() }
            try #require(compensatedSession.performNavigation(.meaningfulJump(producer: .pagePrompt, destination: destination)) == .compensatedFailure)
            try #require(compensatedSession.isNavigationHistoryHealthy)
            try #require(!compensatedSession.canGoBack && !compensatedSession.canGoForward)
            try #require(compensated.requests == [destination, origin])
            let nestedFailure = N11NavigationScript(captures: [origin, nil], restores: [.verifiedLanding, .compensatedFailure])
            let failedSession = ReaderSession(sourceURL: sourceURL, document: try #require(PDFDocument(url: sourceURL)), navigationCapture: { nestedFailure.capture() }, navigationRestore: { nestedFailure.restore($0) })
            defer { failedSession.prepareForClose() }
            try #require(failedSession.performNavigation(.meaningfulJump(producer: .pagePrompt, destination: destination)) == .uncompensatedInvariantFailure(actualLanding: nil))
            try #require(!failedSession.isNavigationHistoryHealthy)
            try #require(!failedSession.canGoBack && !failedSession.canGoForward)
            try #require(nestedFailure.requests == [destination, origin])
            transcript.append(.init(id: "N11-VE06", operation: "post-attempt capture failure; restore origin compensation; nested compensation failure fail-closed", page: nil))
            cases.append(.passed("N11-VE06", "Post-attempt capture failure returns .compensatedFailure after origin restoration; nested compensation failure returns .uncompensatedInvariantFailure and disables history."))

            try #require(try Data(contentsOf: sourceURL) == sourceBytes)
            try #require(try PDFFixtureFactory.sha256(of: sourceURL) == sourceDigest)
            try writeEvidenceIfRequested(sourceHash: sourceHash, cases: cases, transcript: transcript, screenshots: [])
        }
    }

    @Test("N11 visual and containment evidence")
    func nativeVisualEvidence() throws {
        try withTemporaryDirectory { directory in
            let sourceHash = try n11EvidenceSourceHash()
            let sourceURL = try PDFFixtureFactory.makeTextPDF(in: directory, name: "n11-visual.pdf", pageCount: 4)
            let sourceBytes = try Data(contentsOf: sourceURL)
            let sourceDigest = try PDFFixtureFactory.sha256(of: sourceURL)
            let configRoot = directory.appendingPathComponent("config-root", isDirectory: true)
            let stateRoot = directory.appendingPathComponent("state-root", isDirectory: true)
            let applicationSupportRoot = directory.appendingPathComponent("Application Support", isDirectory: true)
            let configSentinel = ConfigFileSource.defaultURL(homeDirectory: configRoot)
            let stateSentinel = stateRoot.appendingPathComponent("modeleaf/state.json")
            let applicationSupportSentinel = applicationSupportRoot.appendingPathComponent("modeleaf/sentinel")
            try FileManager.default.createDirectory(at: configSentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: stateSentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: applicationSupportSentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("config sentinel".utf8).write(to: configSentinel)
            try Data("state sentinel".utf8).write(to: stateSentinel)
            try Data("application support sentinel".utf8).write(to: applicationSupportSentinel)
            _ = ConfigFileSource(url: configSentinel).read()
            _ = ThemeSelectionStore(fileURL: stateSentinel).load()
            _ = RecentFilesStore(fileURL: stateSentinel).load()
            let beforeInventory = try n11Inventory(in: directory)
            let mounted = try openMountedSession(url: sourceURL)
            let session = mounted.session
            defer { session.prepareForClose() }
            let requiresDistinctSnapshots = ProcessInfo.processInfo.environment["PDF_READER_SNAPSHOT_DIR"] != nil
            let first = try snapshotPNG(session.contentView, expectedPage: 1)
            try #require(session.goToLastPage() && session.currentPageNumber == 4)
            let last = try snapshotPNG(
                session.contentView,
                expectedPage: 4,
                excluding: requiresDistinctSnapshots ? [first] : []
            )
            try #require(session.goToPage(3) && session.currentPageNumber == 3)
            let prompt = try snapshotPNG(
                session.contentView,
                expectedPage: 3,
                excluding: requiresDistinctSnapshots ? [first, last] : []
            )
            if requiresDistinctSnapshots {
                try #require(Set([first, last, prompt]).count == 3)
            }
            let view = try #require(descendantReaderPDFViews(in: session.contentView).only)
            let scale = session.contentView.window?.backingScaleFactor ?? 1
            try assertN11PNG(first, expectedPage: 1, matching: session.contentView.bounds.size, scale: scale)
            try assertN11PNG(last, expectedPage: 4, matching: session.contentView.bounds.size, scale: scale)
            try assertN11PNG(prompt, expectedPage: 3, matching: session.contentView.bounds.size, scale: scale)
            var opened: [URL] = []
            view.followLinkHandler = { opened.append($0) }
            view.perform(PDFActionURL(url: URL(string: "https://example.invalid/n11")!))
            view.goBack(nil); view.goForward(nil)
            try #require(opened == [URL(string: "https://example.invalid/n11")!])
            try #require(view.blockedHistoryCount == 2)
            try #require(PDFCapabilityPolicy.disposition(for: .pageHistory) == .suppressed)
            try #require(PDFCapabilityPolicy.disposition(for: .linkActivation) == .allowed)
            try #require(try Data(contentsOf: sourceURL) == sourceBytes)
            try #require(try PDFFixtureFactory.sha256(of: sourceURL) == sourceDigest)
            session.beginSearch("N11")
            session.clearSearch()
            let afterInventory = try n11Inventory(in: directory)
            try #require(afterInventory == beforeInventory)
            try #require(try Data(contentsOf: configSentinel) == Data("config sentinel".utf8))
            try #require(try Data(contentsOf: stateSentinel) == Data("state sentinel".utf8))
            let cases = [
                N11CaseResult.passed("N11-VS01", "Complete relative inventory and SHA-256 fingerprints for source/config/state sentinels are identical after page, search-clear, URL-link, and history navigation; no files were created."),
                N11CaseResult.passed("N11-VS02", "Non-uniform PNGs plus blocked native goBack/goForward, URL follow policy, and capability dispositions asserted."),
            ]
            try #require(try Data(contentsOf: applicationSupportSentinel) == Data("application support sentinel".utf8))
            try writeEvidenceIfRequested(sourceHash: sourceHash, cases: cases, transcript: [
                .init(id: "N11-VS01", operation: "isolated config, state, Application Support, and source PDF inventories before/after page, search-clear, URL, and history actions", page: 3, beforeInventory: beforeInventory, afterInventory: afterInventory),
                .init(id: "N11-VS02", operation: "capture first/last/pagePrompt; URL; native goBack/goForward", page: 3),
            ], screenshots: [("n11-ve01-first.png", first), ("n11-ve02-last.png", last), ("n11-vs02-page-3.png", prompt)])
        }
    }

    private func assertN11InputRouting(url: URL) throws {
        let controlI = try #require(makeKeyEvent(characters: "\t", charactersIgnoringModifiers: "\t", modifiers: [.control], keyCode: 34))
        let tab = try #require(makeKeyEvent(characters: "\t", keyCode: 48))
        let controlO = try #require(makeKeyEvent(characters: "o", charactersIgnoringModifiers: "o", modifiers: [.control]))
        let repeatedControlO = try #require(makeKeyEvent(characters: "o", charactersIgnoringModifiers: "o", modifiers: [.control], isRepeat: true))
        try #require(AppKitKeyEventAdapter.tokens(for: controlI).map(\.description) == ["<C-i>"])
        try #require(AppKitKeyEventAdapter.tokens(for: tab).map(\.description) == ["<Tab>"])

        let defaults = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        for context in [InputContext.navigation, .pagePrompt, .searchPrompt, .searchResults] {
            var actions: [ActionID] = []
            let router = ReaderInputRouter(config: defaults, automaticallySchedulesTimeouts: false, pendingHandler: { _ in }, dispatchHandler: { actions.append($0.actionID) })
            router.synchronizeContext(context)
            try #require(router.handle(controlO) == (context == .navigation))
            try #require(router.handle(controlI) == (context == .navigation))
            try #require(actions == (context == .navigation ? [.historyBack, .historyForward] : []))
        }
        var repeatedActions: [ActionID] = []
        let repeatRouter = ReaderInputRouter(config: defaults, automaticallySchedulesTimeouts: false, pendingHandler: { _ in }, dispatchHandler: { repeatedActions.append($0.actionID) })
        repeatRouter.synchronizeContext(.navigation)
        try #require(repeatRouter.handle(controlO) && repeatRouter.handle(repeatedControlO))
        try #require(repeatedActions == [.historyBack])
        let remapped = try #require(ConfigValidator.validate(SparseAppConfig(keymap: [
            ActionID.historyBack.rawValue: ["x"],
            ActionID.historyForward.rawValue: ["y"],
        ])).validatedConfig)
        for context in [InputContext.navigation, .pagePrompt, .searchPrompt, .searchResults] {
            var actions: [ActionID] = []
            let router = ReaderInputRouter(config: remapped, automaticallySchedulesTimeouts: false, pendingHandler: { _ in }, dispatchHandler: { actions.append($0.actionID) })
            router.synchronizeContext(context)
            _ = router.handle(try #require(makeKeyEvent(characters: "x")))
            _ = router.handle(try #require(makeKeyEvent(characters: "y")))
            try #require(actions == (context == .navigation ? [.historyBack, .historyForward] : []))
        }

        let store = ReaderSessionStore()
        let coordinator = PaneCoordinator(initialStore: store)
        let session = try PDFOpenService().open(url: url)
        var dispatched: [ActionID] = []
        var dispatcher: ActionDispatcher?
        let controller = MainWindowController(coordinator: coordinator, theme: AppKitTheme(themeID: .tokyoNight), actionHandler: { action in dispatched.append(action); dispatcher?.dispatch(action) }, recentFilesProvider: { [] })
        let actionDispatcher = ActionDispatcher(coordinator: coordinator, navigation: defaults.config.navigation)
        dispatcher = actionDispatcher; actionDispatcher.presentation = controller
        defer { controller.close(); while coordinator.closeActiveTab() {} }
        try #require(store.insert(session))
        try #require(session.goToPage(2))
        controller.presentCommandPalette()
        let dispatchesBeforePaletteKeys = dispatched.count
        try #require(controller.routeKeyEventForTesting(controlO) && controller.routeKeyEventForTesting(controlI))
        try #require(dispatched.count == dispatchesBeforePaletteKeys)
        for character in "back" { _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: String(character)))) }
        try #require(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36))))
        try #require(dispatched == [.historyBack] && controller.rootView.commandPaletteOverlay.isHidden)
        try #require(session.currentPageNumber == 1)
        try #require(controller.inputContextForTesting == .navigation)

        let escape = try #require(makeKeyEvent(characters: "", keyCode: 53))
        let remappedBack = try #require(makeKeyEvent(characters: "x"))
        let remappedForward = try #require(makeKeyEvent(characters: "y"))
        let savedContexts: [InputContext] = [.navigation, .searchResults, .pagePrompt, .searchPrompt]
        let modalPresenters: [(name: String, present: () -> Void, isVisible: () -> Bool)] = [
            ("palette", { controller.presentCommandPalette() }, { !controller.rootView.commandPaletteOverlay.isHidden }),
            ("recent", { controller.presentRecentFilesOverlay() }, { !controller.rootView.recentFilesOverlay.isHidden }),
            ("theme", { controller.presentThemePicker() }, { !controller.rootView.themePickerOverlay.isHidden }),
            ("help", { controller.presentHelp() }, { !controller.rootView.helpOverlay.isHidden }),
        ]

        func prepare(_ context: InputContext) throws {
            controller.dismissAllTransientOverlays()
            controller.dismissPromptAndRestoreFocus(to: .navigation, reason: .explicitCancel)
            session.clearSearch()
            switch context {
            case .navigation:
                break
            case .searchResults:
                controller.presentPrompt(PromptPresentation(kind: .search, text: "", validationMessage: nil))
                controller.dismissPromptAndRestoreFocus(to: .searchResults, reason: .promptCommitted)
            case .pagePrompt:
                controller.presentPrompt(PromptPresentation(kind: .page, text: "", validationMessage: nil))
            case .searchPrompt:
                controller.presentPrompt(PromptPresentation(kind: .search, text: "", validationMessage: nil))
            default:
                Issue.record("Unexpected saved context in N11 modal matrix: \(context)")
            }
            try #require(controller.inputContextForTesting == context)
        }

        func assertModalMatrix(
            config: ValidatedAppConfig,
            back: NSEvent,
            forward: NSEvent
        ) throws {
            controller.applyConfig(config)
            for saved in savedContexts {
                for modal in modalPresenters {
                    try prepare(saved)
                    modal.present()
                    let dispatchCount = dispatched.count
                    try #require(modal.isVisible())
                    if modal.name == "palette", saved != .navigation {
                        let row = try #require(controller.rootView.commandPaletteOverlay.visibleCommandsForTesting.first { $0.id == .historyBack })
                        try #require(row.disabledReason == "Available in Navigation only")
                        for character in "back" {
                            try #require(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: String(character)))))
                        }
                        try #require(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36))))
                        try #require(dispatched.count == dispatchCount)
                        try #require(modal.isVisible())
                    }
                    try #require(controller.routeKeyEventForTesting(back))
                    try #require(controller.routeKeyEventForTesting(forward))
                    try #require(dispatched.count == dispatchCount)
                    try #require(modal.isVisible())
                    try #require(controller.routeKeyEventForTesting(escape))
                    try #require(!modal.isVisible())
                    try #require(controller.inputContextForTesting == saved)
                }
            }
            controller.dismissPromptAndRestoreFocus(to: .navigation, reason: .explicitCancel)
            controller.dismissAllTransientOverlays()
            try #require(controller.inputContextForTesting == .navigation)
        }

        try assertModalMatrix(config: defaults, back: controlO, forward: controlI)
        try assertModalMatrix(config: remapped, back: remappedBack, forward: remappedForward)
        controller.applyConfig(defaults)
        try #require(session.goToPage(2)); let dispatchesBeforeResume = dispatched.count; try #require(controller.routeKeyEventForTesting(controlO) && session.currentPageNumber == 1 && dispatched.count == dispatchesBeforeResume + 1)
        // Link-hint modal suppression preserves navigation for default and remapped history keys.
        try withLinkHarness(url: url) { hintController, hintSession, _ in
            try #require(hintSession.goToPage(2) && hintSession.goBack() == .verifiedLanding && hintSession.currentPageNumber == 1)
            hintController.presentLinkHints()
            try #require(!hintController.rootView.linkHintOverlay.isHidden)
            try #require(hintController.routeKeyEventForTesting(controlO))
            try #require(hintController.routeKeyEventForTesting(controlI))
            try #require(hintSession.currentPageNumber == 1)
            _ = hintController.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "", keyCode: 53)))
            try #require(hintController.inputContextForTesting == .navigation)

            hintController.applyConfig(remapped)
            hintController.presentLinkHints()
            try #require(!hintController.rootView.linkHintOverlay.isHidden)
            try #require(hintController.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "x"))))
            try #require(hintController.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "y"))))
            try #require(hintSession.currentPageNumber == 1)
            _ = hintController.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "", keyCode: 53)))
            try #require(hintController.inputContextForTesting == .navigation)
        }
    }

    private func n11Inventory(in directory: URL) throws -> [N11FileFingerprint] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        let urls = (enumerator?.allObjects as? [URL]) ?? []
        return try urls.compactMap { url in
            guard try url.resourceValues(forKeys: keys).isRegularFile == true else { return nil }
            let path = url.path.replacingOccurrences(of: directory.path + "/", with: "")
            return N11FileFingerprint(path: path, digest: try PDFFixtureFactory.sha256(of: url))
        }.sorted { $0.path < $1.path }
    }
    private func openMountedSession(url: URL) throws -> N11MountedSession {
        let session = ReaderSession(sourceURL: url, document: try #require(PDFDocument(url: url)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = session.contentView
        session.contentView.frame = window.contentLayoutRect
        session.contentView.layoutSubtreeIfNeeded()
        return N11MountedSession(session: session, window: window)
    }

    private func withLinkHarness(
        url: URL,
        body: (MainWindowController, ReaderSession, ReaderPDFView) throws -> Void
    ) throws {
        let session = try PDFOpenService().open(url: url)
        let coordinator = PaneCoordinator()
        var dispatcher: ActionDispatcher?
        let controller = MainWindowController(
            coordinator: coordinator,
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { action in dispatcher?.dispatch(action) }
        )
        let actionDispatcher = ActionDispatcher(coordinator: coordinator, navigation: BuiltInDefaults.config.navigation)
        dispatcher = actionDispatcher
        actionDispatcher.presentation = controller
        defer { controller.close(); session.prepareForClose() }
        try #require(coordinator.insert(session, into: .createIfEmpty))
        controller.rootView.layoutSubtreeIfNeeded()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        try body(controller, session, try #require(descendantReaderPDFViews(in: session.contentView).only))
    }

    private func snapshotPNG(
        _ view: NSView,
        expectedPage: Int,
        excluding priorSnapshots: [Data] = []
    ) throws -> Data {
        let reader = try #require(descendantReaderPDFViews(in: view).only)
        let page = try #require(reader.currentPage)
        let document = try #require(reader.document)
        try #require(document.index(for: page) + 1 == expectedPage)
        try #require((page.string ?? "").contains("Page \(expectedPage) unique-page-\(expectedPage)"))

        let deadline = Date(timeIntervalSinceNow: 2)
        repeat {
            reader.layoutDocumentView()
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            view.window?.displayIfNeeded()
            reader.documentView?.displayIfNeeded()
            let representation = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: representation)
            let png = try #require(representation.representation(using: .png, properties: [:]))
            if !priorSnapshots.contains(png) {
                return png
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        } while Date() < deadline

        Issue.record("Page \(expectedPage) did not produce a distinct rendered snapshot")
        return priorSnapshots.last ?? Data()
    }

    private func descendantReaderPDFViews(in view: NSView) -> [ReaderPDFView] {
        let own = (view as? ReaderPDFView).map { [$0] } ?? []
        return own + view.subviews.flatMap(descendantReaderPDFViews(in:))
    }
    private func assertN11PNG(
        _ data: Data,
        expectedPage: Int,
        matching size: CGSize,
        scale: CGFloat
    ) throws {
        let representation = try #require(NSBitmapImageRep(data: data))
        try #require(expectedPage >= 1 && expectedPage <= 4)
        try #require(representation.pixelsWide > 100 && representation.pixelsHigh > 100)
        try #require(abs(CGFloat(representation.pixelsWide) - size.width * scale) < 2)
        try #require(abs(CGFloat(representation.pixelsHigh) - size.height * scale) < 2)
        let bytes = try #require(representation.bitmapData)
        let stride = max(1, representation.bytesPerRow / 64)
        var samples = Set<UInt32>()
        for offset in Swift.stride(from: 0, to: representation.bytesPerRow * representation.pixelsHigh, by: stride) {
            guard offset + 3 < representation.bytesPerRow * representation.pixelsHigh else { continue }
            samples.insert(UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3]))
        }
        try #require(samples.count > 8)
    }

    private func n11EvidenceSourceHash() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PDF_READER_SNAPSHOT_DIR"] != nil else { return "sha256:local-unfrozen-test" }
        guard let sourceHash = environment["N11_SOURCE_HASH"],
              sourceHash.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil
        else { throw N11EvidenceError.malformedArtifact("missing or malformed N11_SOURCE_HASH for artifact-producing run") }
        guard let expectedSourceHash = environment["N11_EXPECTED_SOURCE_HASH"], expectedSourceHash == sourceHash else {
            throw N11EvidenceError.malformedArtifact("N11 source hash does not match frozen invocation identity")
        }
        return sourceHash
    }

    private func n11EvidenceRunID() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PDF_READER_SNAPSHOT_DIR"] != nil else { return "local-unfrozen-test" }
        guard let runID = environment["N11_RUN_ID"], !runID.isEmpty,
              runID.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
        else { throw N11EvidenceError.malformedArtifact("missing or unsafe N11_RUN_ID") }
        return runID
    }

    private func writeEvidenceIfRequested(
        sourceHash: String, cases: [N11CaseResult], transcript: [N11TranscriptEvent], screenshots: [(String, Data)]
    ) throws {
        guard let path = ProcessInfo.processInfo.environment["PDF_READER_SNAPSHOT_DIR"] else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let runID = try n11EvidenceRunID()
        let commandIdentity = "swift-testing:N11NavigationRedTeamTests"
        let veIDs = ["N11-VE01", "N11-VE02", "N11-VE03", "N11-VE04", "N11-VE05", "N11-VE06"]
        let vsIDs = ["N11-VS01", "N11-VS02"]
        let expectedIDs = veIDs + vsIDs
        let staging = root.appendingPathComponent(".staging", isDirectory: true).appendingPathComponent(runID, isDirectory: true)
        let finalRun = root.appendingPathComponent("runs", isDirectory: true).appendingPathComponent(runID, isDirectory: true)
        let reportURL = root.appendingPathComponent("n11-adversarial-test-report.json")
        let fragmentReport = staging.appendingPathComponent("n11-ve-fragment-report.json")
        let fragmentTranscript = staging.appendingPathComponent("n11-ve-fragment-transcript.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoder = JSONDecoder()
        let receivedIDs = cases.map(\.id)
        guard receivedIDs == transcript.map(\.id), Set(receivedIDs).count == receivedIDs.count else {
            throw N11EvidenceError.malformedArtifact("case/transcript identity mismatch")
        }

        if receivedIDs == veIDs {
            guard !FileManager.default.fileExists(atPath: staging.path), !FileManager.default.fileExists(atPath: finalRun.path) else {
                throw N11EvidenceError.malformedArtifact("pre-existing N11 run directory")
            }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let fragment = N11EvidenceManifest(sourceHash: sourceHash, runID: runID, commandIdentity: commandIdentity, expectedIDs: veIDs, cases: cases, artifacts: [])
            let fragmentEvents = N11TranscriptManifest(sourceHash: sourceHash, runID: runID, commandIdentity: commandIdentity, expectedIDs: veIDs, events: transcript)
            try encoder.encode(fragment).write(to: fragmentReport, options: .atomic)
            try encoder.encode(fragmentEvents).write(to: fragmentTranscript, options: .atomic)
            return
        }

        guard receivedIDs == vsIDs, FileManager.default.fileExists(atPath: staging.path),
              !FileManager.default.fileExists(atPath: finalRun.path),
              FileManager.default.fileExists(atPath: fragmentReport.path), FileManager.default.fileExists(atPath: fragmentTranscript.path)
        else { throw N11EvidenceError.malformedArtifact("missing fresh VE staging fragment") }
        let fragment = try decoder.decode(N11EvidenceManifest.self, from: Data(contentsOf: fragmentReport))
        let fragmentEvents = try decoder.decode(N11TranscriptManifest.self, from: Data(contentsOf: fragmentTranscript))
        try validateN11Evidence(fragment, expectedIDs: veIDs, sourceHash: sourceHash, runID: runID, commandIdentity: commandIdentity)
        try validateN11Transcript(fragmentEvents, expectedIDs: veIDs, sourceHash: sourceHash, runID: runID, commandIdentity: commandIdentity)
        try FileManager.default.removeItem(at: fragmentReport)
        try FileManager.default.removeItem(at: fragmentTranscript)
        let allCases = fragment.cases + cases
        let allEvents = fragmentEvents.events + transcript
        guard allCases.map(\.id) == expectedIDs, allEvents.map(\.id) == expectedIDs else {
            throw N11EvidenceError.malformedArtifact("incomplete exact contract set")
        }
        for (name, data) in screenshots {
            try data.write(to: staging.appendingPathComponent(name), options: .atomic)
        }
        let transcriptManifest = N11TranscriptManifest(sourceHash: sourceHash, runID: runID, commandIdentity: commandIdentity, expectedIDs: expectedIDs, events: allEvents)
        let transcriptName = "n11-native-automation-transcript.json"
        let transcriptData = try encoder.encode(transcriptManifest)
        try transcriptData.write(to: staging.appendingPathComponent(transcriptName), options: .atomic)
        var artifacts = screenshots.map { N11ArtifactDigest(path: "runs/\(runID)/\($0.0)", sha256: sha256(of: $0.1)) }
        artifacts.append(N11ArtifactDigest(path: "runs/\(runID)/\(transcriptName)", sha256: sha256(of: transcriptData)))
        artifacts.sort { $0.path < $1.path }
        let manifest = N11EvidenceManifest(sourceHash: sourceHash, runID: runID, commandIdentity: commandIdentity, expectedIDs: expectedIDs, cases: allCases, artifacts: artifacts)
        let runManifestName = "n11-run-manifest.json"
        try encoder.encode(manifest).write(to: staging.appendingPathComponent(runManifestName), options: .atomic)
        try FileManager.default.createDirectory(at: finalRun.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging, to: finalRun)
        try encoder.encode(manifest).write(to: reportURL, options: .atomic)
    }


    private func validateN11Evidence(
        _ manifest: N11EvidenceManifest, expectedIDs: [String], sourceHash: String, runID: String, commandIdentity: String
    ) throws {
        guard manifest.sourceHash == sourceHash, manifest.runID == runID, manifest.commandIdentity == commandIdentity,
              manifest.expectedIDs == expectedIDs, manifest.cases.map(\.id) == expectedIDs
        else { throw N11EvidenceError.malformedArtifact("report") }
    }

    private func validateN11Transcript(
        _ transcript: N11TranscriptManifest, expectedIDs: [String], sourceHash: String, runID: String, commandIdentity: String
    ) throws {
        guard transcript.sourceHash == sourceHash, transcript.runID == runID, transcript.commandIdentity == commandIdentity,
              transcript.expectedIDs == expectedIDs, transcript.events.map(\.id) == expectedIDs
        else { throw N11EvidenceError.malformedArtifact("transcript") }
    }

    private func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }


    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("n11-native-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private struct N11EvidenceManifest: Codable {
    let sourceHash: String
    let runID: String
    let commandIdentity: String
    let expectedIDs: [String]
    let cases: [N11CaseResult]
    let artifacts: [N11ArtifactDigest]
}

private struct N11TranscriptManifest: Codable {
    let sourceHash: String
    let runID: String
    let commandIdentity: String
    let expectedIDs: [String]
    let events: [N11TranscriptEvent]
}

private struct N11ArtifactDigest: Codable {
    let path: String
    let sha256: String
}

private enum N11EvidenceError: Error {
    case malformedArtifact(String)
}
private struct N11CaseResult: Codable {
    let id: String
    let passed: Bool
    let expectedAssertions: String
    let observedAssertions: String
    static func passed(_ id: String, _ assertions: String) -> Self {
        Self(id: id, passed: true, expectedAssertions: assertions, observedAssertions: "All named assertions passed: \(assertions)")
    }
}
private struct N11FileFingerprint: Codable, Equatable {
    let path: String
    let digest: String
}
private struct N11TranscriptEvent: Codable {
    let id: String
    let operation: String
    let page: Int?
    let beforeInventory: [N11FileFingerprint]?
    let afterInventory: [N11FileFingerprint]?

    init(id: String, operation: String, page: Int?, beforeInventory: [N11FileFingerprint]? = nil, afterInventory: [N11FileFingerprint]? = nil) {
        self.id = id; self.operation = operation; self.page = page
        self.beforeInventory = beforeInventory; self.afterInventory = afterInventory
    }
}

@MainActor
private final class N11MountedSession {
    let session: ReaderSession
    let window: NSWindow

    init(session: ReaderSession, window: NSWindow) {
        self.session = session
        self.window = window
    }
}

@MainActor
private final class N11SearchDriver: ReaderSearchDriving, ReaderSearchReplacementScheduling {
    weak var sink: (any ReaderSearchDriverSink)?
    private(set) var generations: [UInt64] = []
    private var scheduled: [@MainActor @Sendable () -> Void] = []
    func begin(query: String, generation: UInt64) { generations.append(generation) }
    func cancel(generation: UInt64) {}
    func detach() { sink = nil }
    func match(_ generation: UInt64) { sink?.searchDriverDidMatch(PDFSelection(document: PDFDocument()), generation: generation) }
    func end(_ generation: UInt64) { sink?.searchDriverDidEnd(generation: generation) }
    func schedule(_ operation: @escaping @MainActor @Sendable () -> Void) { scheduled.append(operation) }
    func runNext() { guard !scheduled.isEmpty else { return }; scheduled.removeFirst()() }
}

@MainActor
private final class N11SearchPresenter: ReaderSearchResultPresenting {
    private let navigation: N11SearchNavigation
    var nextLanding: NavigationSnapshot?

    init(navigation: N11SearchNavigation) { self.navigation = navigation }

    func presentSearchResults(_ selections: [PDFSelection], activeIndex: Int?) -> ReaderSearchResultDisplayOutcome {
        if let nextLanding { navigation.current = nextLanding; self.nextLanding = nil }
        return .displayedDistinct(landing: navigation.current)
    }

    func activateSearchResult(at index: Int) -> ReaderSearchResultDisplayOutcome {
        if let nextLanding { navigation.current = nextLanding; self.nextLanding = nil }
        return .displayedDistinct(landing: navigation.current)
    }

    func restoreSearchResultSelection(at index: Int?) {}
    func clearSearchResults() {}
}

@MainActor
private final class N11SearchNavigation {
    var current = NavigationSnapshot(pageIndex: 0, pageSpacePoint: .zero)!
    func capture() -> NavigationSnapshot? { current }
    func position(_ pageIndex: Int) -> NavigationSnapshot { NavigationSnapshot(pageIndex: pageIndex, pageSpacePoint: .zero)! }
}

@MainActor
private final class N11NavigationScript {
    private var captures: [NavigationSnapshot?]
    private var restores: [NavigationRestoreOutcome]
    private(set) var requests: [NavigationSnapshot] = []

    init(captures: [NavigationSnapshot?], restores: [NavigationRestoreOutcome]) { self.captures = captures; self.restores = restores }
    func capture() -> NavigationSnapshot? { captures.isEmpty ? nil : captures.removeFirst() }
    func restore(_ snapshot: NavigationSnapshot) -> NavigationRestoreOutcome {
        requests.append(snapshot)
        return restores.isEmpty ? .preflightRejected : restores.removeFirst()
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
