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

    @Test("presenting fixture links shows merged geometry and leaves fixture bytes unchanged")
    func presentShowsMergedHints() throws {
        try withLinkHarness { controller, _, _, url in
            let before = try PDFFixtureFactory.sha256(of: url)
            controller.presentLinkHints()
            let overlay = controller.rootView.linkHintOverlay

            #expect(!overlay.isHidden)
            #expect(overlay.visibleLabels.count == 5)
            #expect(overlay.hintRectCountsForTesting.filter { $0 == 2 }.count == 1)
            #expect(overlay.hintRectCountsForTesting.reduce(0, +) == 6)
            #expect(try PDFFixtureFactory.sha256(of: url) == before)
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

    @Test("two-character labels filter prefixes, backspace, reject misses, and block modifiers")
    func prefixAndModifierTransitions() throws {
        let overlay = LinkHintOverlayView(frame: .zero)
        overlay.present(hints: (0..<27).map { _ in (rects: [NSRect(x: 0, y: 0, width: 1, height: 1)], label: "") })
        // Present through the real label generator so the two-key transition is exercised, not a hand-written label table.
        overlay.dismiss()
        overlay.present(hints: LinkHintLabels.generate(count: 27).map { (rects: [NSRect(x: 0, y: 0, width: 1, height: 1)], label: $0) })
        var rejected = 0
        overlay.didRejectInputForTesting = { rejected += 1 }

        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "f"))))
        #expect(overlay.currentPrefix == "f")
        #expect(overlay.matchingLabelsForTesting.count > 1)
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "", keyCode: 51))))
        #expect(overlay.currentPrefix.isEmpty)
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "z"))))
        #expect(rejected == 1)
        #expect(overlay.currentPrefix.isEmpty)
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "w", modifiers: [.command]))))
        #expect(overlay.isPresenting)
        #expect(rejected == 2)
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "w", modifiers: [.control]))))
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

    @Test("geometry events dismiss before forwarding and resize dismisses")
    func geometryTransitions() throws {
        try withLinkHarness { controller, _, _, _ in
            let window = try #require(controller.window as? ReaderWindow)
            var visibilityAtForwarding: [Bool] = []
            window.geometryEventObserverForTesting = { _ in visibilityAtForwarding.append(controller.rootView.linkHintOverlay.isHidden) }

            controller.presentLinkHints()
            let scrollSource = try #require(CGEventSource(stateID: .hidSystemState))
            let scrollCGEvent = try #require(CGEvent(scrollWheelEvent2Source: scrollSource, units: .pixel, wheelCount: 2, wheel1: 1, wheel2: 0, wheel3: 0))
            window.sendEvent(try #require(NSEvent(cgEvent: scrollCGEvent)))
            #expect(visibilityAtForwarding == [true])

            controller.presentLinkHints()
            window.sendGeometryEventForTesting(.magnify)

            #expect(visibilityAtForwarding == [true, true])
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

    @Test("closed sessions expose no targets and ignore activation")
    func closedSessionGuards() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeLinkHintPDF(in: directory)
            let session = try PDFOpenService().open(url: url)
            let view = try #require(descendantReaderPDFViews(in: session.contentView).only)
            var followed = 0
            view.followLinkHandler = { _ in followed += 1 }
            let target = ReaderLinkTarget.url("https://example.invalid/link-hint")
            session.prepareForClose()

            #expect(session.linkTargets().isEmpty)
            session.activateLink(target)
            #expect(followed == 0)
            #expect(view.followedLinkCount == 0)
        }
    }

    private func withLinkHarness(_ body: (MainWindowController, ReaderSession, ReaderPDFView, URL) throws -> Void) throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeLinkHintPDF(in: directory)
            let session = try PDFOpenService().open(url: url)
            let coordinator = PaneCoordinator()
            let controller = MainWindowController(coordinator: coordinator, theme: AppKitTheme(themeID: .tokyoNight), actionHandler: { _ in })
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
