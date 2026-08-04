import AppKit
import Foundation
import PDFKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("Link hint fixture integration")
@MainActor
struct LinkHintIntegrationTests {
    @Test("link hint fixture persists URL, GoTo, and geometry annotations without mutating its bytes")
    func fixturePersistsLinkTargets() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeLinkHintPDF(in: directory)
            let before = try PDFFixtureFactory.sha256(of: url)
            let document = try #require(PDFDocument(url: url))
            let page = try #require(document.page(at: 0))
            #expect(page.annotations.count == 6)
            #expect(page.annotations.filter { $0.action is PDFActionURL }.count == 5)
            #expect(page.annotations.contains { $0.action is PDFActionGoTo })
            #expect(try PDFFixtureFactory.sha256(of: url) == before)
        }
    }

    @Test("presenting fixture links uses direct page-to-overlay geometry in single and multi-page views")
    func presentShowsMergedHints() throws {
        try withLinkHarness { controller, _, view, url in
            let before = try PDFFixtureFactory.sha256(of: url)
            view.displayMode = .singlePage
            view.layoutDocumentView()
            #expect(view.visiblePages.count == 1)
            controller.presentLinkHints()
            assertHintRectsMatchAnnotations(controller.rootView.linkHintOverlay, in: view)
            controller.dismissLinkHintsAndRestoreFocus()

            let window = try #require(controller.window)
            window.setContentSize(NSSize(width: 1_200, height: 1_800))
            view.displayMode = .singlePageContinuous
            controller.rootView.layoutSubtreeIfNeeded()
            view.layoutDocumentView()
            #expect(view.visiblePages.count >= 2)
            controller.presentLinkHints()
            assertHintRectsMatchAnnotations(controller.rootView.linkHintOverlay, in: view)
            #expect(try PDFFixtureFactory.sha256(of: url) == before)
        }
    }

    @Test("history actions are consumed while link hints own routing")
    func historyActionsStayModal() throws {
        try withLinkHarness { controller, _, _, _ in
            controller.presentLinkHints()
            #expect(!controller.rootView.linkHintOverlay.isHidden)
            let historyEvent = try #require(makeKeyEvent(
                characters: "o", charactersIgnoringModifiers: "o", modifiers: [.control]
            ))
            #expect(controller.routeKeyEventForTesting(historyEvent))
            let escapeEvent = try #require(makeKeyEvent(characters: "", keyCode: 53))
            #expect(controller.routeKeyEventForTesting(escapeEvent))
            #expect(controller.rootView.linkHintOverlay.isHidden)
        }
    }

    @Test("unique URL hint commits through the PDF view and dismisses")
    func uniqueURLCommit() throws {
        try withLinkHarness { controller, session, view, _ in
            var followed: URL?
            view.followLinkHandler = { followed = $0 }
            controller.presentLinkHints()

            let event = try #require(makeKeyEvent(characters: "f"))
            #expect(controller.routeKeyEventForTesting(event))
            #expect(followed == URL(string: "https://example.invalid/link-hint"))
            #expect(view.followedLinkCount == 1)
            #expect(controller.rootView.linkHintOverlay.isHidden)
            #expect(controller.window?.firstResponder === session.focusView)
        }
    }

    @Test("GoTo hint changes page without incrementing URL follow count")
    func uniqueGoToCommit() throws {
        try withLinkHarness { controller, session, view, _ in
            controller.presentLinkHints()

            let event = try #require(makeKeyEvent(characters: "k"))
            #expect(controller.routeKeyEventForTesting(event))
            #expect(session.currentPageNumber == 2)
            // GoTo navigation intentionally mirrors PDFKit mouse activation: it is not a URL follow.
            #expect(view.followedLinkCount == 0)
            #expect(controller.rootView.linkHintOverlay.isHidden)
        }
    }

    @Test("mouse GoTo and hint GoTo share one canonical history transaction")
    func mouseAndHintGoToConvergeOnce() throws {
        try withLinkHarness { controller, session, view, url in
            let before = try PDFFixtureFactory.sha256(of: url)
            let target = ReaderLinkTarget.goTo(pageIndex: 1, point: CGPoint(x: 48, y: 700))
            session.activateLink(target)
            #expect(session.currentPageNumber == 2)
            #expect(session.canGoBack)
            #expect(session.goBack() == .verifiedLanding)
            #expect(session.currentPageNumber == 1)
            let page = try #require(view.document?.page(at: 1))
            #expect(!session.canGoBack)
            view.perform(PDFActionGoTo(destination: PDFDestination(page: page, at: CGPoint(x: 48, y: 700))))
            #expect(session.currentPageNumber == 2)
            #expect(session.goBack() == .verifiedLanding)
            #expect(session.currentPageNumber == 1)
            #expect(!session.canGoBack)
            #expect(view.blockedHistoryCount == 0)
            #expect(try PDFFixtureFactory.sha256(of: url) == before)
            _ = controller
        }
    }
    @Test("same unresolved and URL targets never create internal-link history")
    func excludedLinkTargetsLeaveHistoryEmpty() throws {
        try withLinkHarness { _, session, view, _ in
            var opened: [URL] = []
            view.followLinkHandler = { opened.append($0) }
            session.activateLink(.url("https://example.invalid/link-hint"))
            session.activateLink(.goTo(pageIndex: 99, point: .zero))
            session.activateLink(.goTo(pageIndex: 0, point: CGPoint(x: 306, y: 396)))
            #expect(opened == [URL(string: "https://example.invalid/link-hint")!])
            #expect(session.currentPageNumber == 1)
            #expect(!session.canGoBack && !session.canGoForward)
            #expect(view.followedLinkCount == 1)
        }
    }



    @Test("two-character labels accept Shift and Caps Lock labels while rejecting command modifiers")
    func prefixAndModifierTransitions() throws {
        let overlay = LinkHintOverlayView(frame: .zero)
        overlay.present(hints: LinkHintLabels.generate(count: 27).map { (rects: [NSRect(x: 0, y: 0, width: 1, height: 1)], label: $0) })
        var rejected = 0
        var commits: [Int] = []
        overlay.didRejectInputForTesting = { rejected += 1 }
        overlay.onCommit = { commits.append($0) }

        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "F", charactersIgnoringModifiers: "f", modifiers: [.shift]))))
        #expect(overlay.currentPrefix == "f")
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "", keyCode: 51))))
        #expect(overlay.currentPrefix.isEmpty)
        overlay.dismiss()
        overlay.present(hints: [(rects: [.zero], label: "f")])
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "F", charactersIgnoringModifiers: "f", modifiers: [.capsLock]))))
        #expect(commits == [0])

        for modifier in [NSEvent.ModifierFlags.command, .control, .option] {
            #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "f", modifiers: [modifier]))))
        }
        #expect(overlay.isPresenting)
        #expect(rejected == 3)
    }

    @Test("escape and mouse down cancel hints, restore focus, and pass the click to the PDF view")
    func escapeAndMouseTransitions() throws {
        try withLinkHarness { controller, session, view, _ in
            controller.presentLinkHints()
            #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "", keyCode: 53))))
            #expect(controller.rootView.linkHintOverlay.isHidden)
            #expect(session.currentPageNumber == 1)
            #expect(controller.window?.firstResponder === session.focusView)
            controller.presentLinkHints()
            let point = controller.rootView.convert(NSPoint(x: controller.rootView.bounds.midX, y: controller.rootView.bounds.midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: controller.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            controller.window?.sendEvent(event)
            #expect(controller.rootView.linkHintOverlay.isHidden)
            #expect(controller.window?.firstResponder === session.focusView)
        }
    }

    @Test("geometry events dismiss before forwarding, forward scroll input, and resize dismisses")
    func geometryTransitions() throws {
        try withLinkHarness { controller, _, _, _ in
            let window = try #require(controller.window as? ReaderWindow)
            var visibilityAtForwarding: [Bool] = []
            window.geometryEventObserverForTesting = { _ in
                visibilityAtForwarding.append(controller.rootView.linkHintOverlay.isHidden)
            }

            controller.presentLinkHints()
            let scrollSource = try #require(CGEventSource(stateID: .hidSystemState))
            let scrollCGEvent = try #require(CGEvent(scrollWheelEvent2Source: scrollSource, units: .pixel, wheelCount: 2, wheel1: 1, wheel2: 0, wheel3: 0))
            window.sendEvent(try #require(NSEvent(cgEvent: scrollCGEvent)))
            // The observer is invoked only after ReaderWindow calls super.sendEvent.
            #expect(visibilityAtForwarding == [true])

            controller.presentLinkHints()
            window.sendGeometryEventForTesting(.magnify)
            #expect(controller.rootView.linkHintOverlay.isHidden)
            controller.presentLinkHints()
            controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
            #expect(controller.rootView.linkHintOverlay.isHidden)
        }
    }

    @Test("pane, close, resign-key, and transient-overlay transitions dismiss hints")
    func lifecycleTransitions() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeLinkHintPDF(in: directory)
            let session = try PDFOpenService().open(url: url)
            let coordinator = PaneCoordinator()
            coordinator.configureDuplication { _ in try? PDFOpenService().open(url: url) }
            let controller = MainWindowController(coordinator: coordinator, theme: AppKitTheme(themeID: .tokyoNight), actionHandler: { _ in })
            defer { controller.close(); while coordinator.closeActiveTab() {} }
            #expect(coordinator.insert(session, into: .createIfEmpty))
            controller.rootView.layoutSubtreeIfNeeded()

            let inactivePane = try #require(coordinator.activePaneID)
            let activePane = try #require(coordinator.split(direction: .sideBySide))
            controller.presentLinkHints()
            #expect(!controller.rootView.linkHintOverlay.isHidden)
            #expect(coordinator.activatePane(inactivePane))
            #expect(controller.rootView.linkHintOverlay.isHidden)
            #expect(coordinator.activePaneID == inactivePane)
            #expect(coordinator.activePaneID != activePane)

            controller.presentLinkHints()
            controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: controller.window))
            #expect(controller.rootView.linkHintOverlay.isHidden)
            controller.presentLinkHints()
            controller.presentCommandPalette()
            #expect(controller.rootView.linkHintOverlay.isHidden)
            #expect(!controller.rootView.commandPaletteOverlay.isHidden)

            controller.presentLinkHints()
            #expect(coordinator.closeActiveTab())
            #expect(controller.rootView.linkHintOverlay.isHidden)
        }
    }
    @Test("default f and F routes link hints and fit page, while search results leaves f unhandled")

    func defaultKeyRoutesLinkHintsAndFitPage() throws {
        try withLinkHarness { controller, session, _, _ in
            let hintKey = try #require(makeKeyEvent(characters: "f"))
            #expect(controller.routeKeyEventForTesting(hintKey))
            #expect(!controller.rootView.linkHintOverlay.isHidden)
            let escapeKey = try #require(makeKeyEvent(characters: "", keyCode: 53))
            #expect(controller.routeKeyEventForTesting(escapeKey))

            session.fitWidth()
            let fitPageKey = try #require(makeKeyEvent(characters: "F"))
            #expect(controller.routeKeyEventForTesting(fitPageKey))
            #expect(session.viewMode == .fitPage)

            let searchKey = try #require(makeKeyEvent(characters: "/"))
            #expect(controller.routeKeyEventForTesting(searchKey))
            controller.rootView.promptOverlay.textField.stringValue = "needle"
            let commitKey = try #require(makeKeyEvent(characters: "\r", keyCode: 36))
            #expect(controller.routeKeyEventForTesting(commitKey))
            #expect(controller.inputContextForTesting == .searchResults)
            let searchHintKey = try #require(makeKeyEvent(characters: "f"))
            #expect(!controller.routeKeyEventForTesting(searchHintKey))
            #expect(controller.rootView.linkHintOverlay.isHidden)
        }
    }
    @Test("closed sessions expose no targets and ignore activation")
    func closedSessionGuards() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeLinkHintPDF(in: directory)
            let session = try PDFOpenService().open(url: url)
            let view = try #require(descendantReaderPDFViews(in: session.contentView).only)
            var followed = 0
            view.followLinkHandler = { _ in followed += 1 }
            let target = ReaderLinkTarget.url("https://example.invalid/link-hint")
            let destinationPage = try #require(view.document?.page(at: 1))
            session.prepareForClose()

            #expect(session.linkTargets().isEmpty)
            session.activateLink(target)
            #expect(followed == 0)
            view.perform(PDFActionGoTo(destination: PDFDestination(page: destinationPage, at: CGPoint(x: 48, y: 700))))
            #expect(view.followedLinkCount == 0)
        }
    }

    private func assertHintRectsMatchAnnotations(_ overlay: LinkHintOverlayView, in view: ReaderPDFView) {
        let expected = view.visiblePages.flatMap { page in
            page.annotations.compactMap { annotation -> NSRect? in
                guard annotation.type == "Link" || annotation.action != nil || annotation.url != nil else { return nil }
                return view.convert(view.convert(annotation.bounds, from: page), to: overlay)
            }
        }
        let actual = overlay.hintRectsForTesting.flatMap { $0 }
        #expect(!overlay.isHidden)
        #expect(actual.count == expected.count)
        for rect in expected {
            #expect(actual.contains { matches(rect, within: 1, of: $0) })
        }
    }

    private func matches(_ lhs: NSRect, within tolerance: CGFloat, of rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func withLinkHarness(_ body: (MainWindowController, ReaderSession, ReaderPDFView, URL) throws -> Void) throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeLinkHintPDF(in: directory)
            let session = try PDFOpenService().open(url: url)
            let coordinator = PaneCoordinator()
            var dispatcher: ActionDispatcher?
            let controller = MainWindowController(
                coordinator: coordinator,
                theme: AppKitTheme(themeID: .tokyoNight),
                actionHandler: { action in dispatcher?.dispatch(action) }
            )
            let actionDispatcher = ActionDispatcher(
                coordinator: coordinator,
                navigation: BuiltInDefaults.config.navigation
            )
            dispatcher = actionDispatcher
            actionDispatcher.presentation = controller
            defer { controller.close(); session.prepareForClose() }
            #expect(coordinator.insert(session, into: .createIfEmpty))
            controller.rootView.layoutSubtreeIfNeeded()
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            let view = try #require(descendantReaderPDFViews(in: session.contentView).only)
            try body(controller, session, view, url)
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("link-hints-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func descendantReaderPDFViews(in view: NSView) -> [ReaderPDFView] {
        let own = (view as? ReaderPDFView).map { [$0] } ?? []
        return own + view.subviews.flatMap(descendantReaderPDFViews(in:))
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
