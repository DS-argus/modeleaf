import AppKit
import PDFKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("Link hint acceptance")
@MainActor
struct LinkHintAcceptanceTests {
    @Test("f displays labels, labels activate URL and GoTo targets, and Escape cancels deterministically")
    func keyboardEndToEnd() throws {
        try withLinkHarness { controller, session, view, _ in
            var opened: [URL] = []
            view.followLinkHandler = { opened.append($0) }
            let urlLabel = try #require(label(for: .url("https://example.invalid/link-hint"), in: session))
            let goToLabel = try #require(label(for: .goTo(pageIndex: 1, point: CGPoint(x: 48, y: 700)), in: session))

            #expect(route("f", through: controller))
            #expect(!controller.rootView.linkHintOverlay.isHidden)
            #expect(controller.rootView.linkHintOverlay.visibleLabels == LinkHintLabels.generate(count: 5))
            try type(urlLabel, through: controller)
            #expect(opened == [URL(string: "https://example.invalid/link-hint")!])
            #expect(view.followedLinkCount == 1)
            #expect(controller.rootView.linkHintOverlay.isHidden)

            #expect(route("f", through: controller))
            try type(goToLabel, through: controller)
            #expect(session.currentPageNumber == 2)
            #expect(view.followedLinkCount == 1)

            for _ in 0..<2 {
                #expect(session.goToPage(1))
                #expect(route("f", through: controller))
                #expect(route("", keyCode: 53, through: controller))
                #expect(controller.rootView.linkHintOverlay.isHidden)
                #expect(session.currentPageNumber == 1)
            }
        }
    }

    @Test("fixture keeps separate links separate, joins wrapped links, and never merges GoTo across pages")
    func fixtureGeometryAndPageBoundaries() throws {
        try withLinkHarness { controller, session, _, _ in
            let raw = session.linkTargets()
            let merged = LinkHintMerge.mergeLinks(raw)
            let goTo = try #require(merged.first { if case .goTo = $0.target { true } else { false } })

            #expect(raw.count == 6)
            #expect(merged.count == 5)
            #expect(merged.filter { $0.rects.count == 2 }.count == 1)
            #expect(merged.filter { $0.rects.count == 1 }.count == 4)
            #expect(goTo.sourcePageIndex == 0)
            #expect(goTo.target == .goTo(pageIndex: 1, point: CGPoint(x: 48, y: 700)))
            #expect(merged.filter { $0.target == .url("https://example.invalid/distant") }.count == 3)

            controller.presentLinkHints()
            #expect(controller.rootView.linkHintOverlay.visibleLabels.count == 5)
            #expect(controller.rootView.linkHintOverlay.hintRectCountsForTesting.filter { $0 == 2 }.count == 1)
        }
    }

    @Test("hints preserve source bytes, operate only in the active pane, and retain mouse URL routing")
    func readOnlyAndMultiPaneAcceptance() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeLinkHintPDF(in: directory)
            let before = try PDFFixtureFactory.sha256(of: url)
            let first = try PDFOpenService().open(url: url)
            let coordinator = PaneCoordinator()
            coordinator.configureDuplication { _ in try? PDFOpenService().open(url: url) }
            let controller = makeController(coordinator: coordinator)
            defer { controller.close(); while coordinator.closeActiveTab() {} }
            #expect(coordinator.insert(first, into: .createIfEmpty))
            let inactivePane = try #require(coordinator.activePaneID)
            let activePane = try #require(coordinator.split(direction: .sideBySide))
            let active = try #require(coordinator.activeSession as? ReaderSession)
            let inactiveView = try #require(descendantReaderPDFViews(in: first.contentView).only)
            let activeView = try #require(descendantReaderPDFViews(in: active.contentView).only)
            var opened: [URL] = []
            inactiveView.followLinkHandler = { opened.append($0) }
            activeView.followLinkHandler = { opened.append($0) }

            controller.rootView.layoutSubtreeIfNeeded()
            #expect(coordinator.activePaneID == activePane)
            #expect(route("f", through: controller))
            #expect(!controller.rootView.linkHintOverlay.isHidden)
            try type(try #require(label(for: .url("https://example.invalid/link-hint"), in: active)), through: controller)
            #expect(activeView.followedLinkCount == 1)
            #expect(inactiveView.followedLinkCount == 0)
            #expect(opened == [URL(string: "https://example.invalid/link-hint")!])

            #expect(coordinator.activatePane(inactivePane))
            #expect(controller.rootView.linkHintOverlay.isHidden)
            activeView.pdfViewWillClick(onLink: activeView, with: URL(string: "https://example.invalid/link-hint")!)
            #expect(activeView.followedLinkCount == 2)
            #expect(opened == [URL(string: "https://example.invalid/link-hint")!, URL(string: "https://example.invalid/link-hint")!])
            #expect(try PDFFixtureFactory.sha256(of: url) == before)
        }
    }

    private func makeController(coordinator: PaneCoordinator) -> MainWindowController {
        var dispatcher: ActionDispatcher?
        let controller = MainWindowController(coordinator: coordinator, theme: AppKitTheme(themeID: .tokyoNight), actionHandler: { dispatcher?.dispatch($0) })
        let actionDispatcher = ActionDispatcher(coordinator: coordinator, navigation: BuiltInDefaults.config.navigation)
        dispatcher = actionDispatcher
        actionDispatcher.presentation = controller
        return controller
    }

    private func withLinkHarness(_ body: (MainWindowController, ReaderSession, ReaderPDFView, URL) throws -> Void) throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeLinkHintPDF(in: directory)
            let session = try PDFOpenService().open(url: url)
            let coordinator = PaneCoordinator()
            let controller = makeController(coordinator: coordinator)
            defer { controller.close(); session.prepareForClose() }
            #expect(coordinator.insert(session, into: .createIfEmpty))
            controller.rootView.layoutSubtreeIfNeeded()
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            try body(controller, session, try #require(descendantReaderPDFViews(in: session.contentView).only), url)
        }
    }

    private func label(for target: ReaderLinkTarget, in session: ReaderSession) -> String? {
        let links = LinkHintMerge.mergeLinks(session.linkTargets())
        guard let index = links.firstIndex(where: { $0.target == target }) else { return nil }
        return LinkHintLabels.generate(count: links.count)[index]
    }

    private func type(_ label: String, through controller: MainWindowController) throws {
        for character in label { #expect(route(String(character), through: controller)) }
    }

    private func route(_ characters: String, keyCode: UInt16 = 0, through controller: MainWindowController) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return false }
        return controller.routeKeyEventForTesting(event)
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("link-hint-acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func descendantReaderPDFViews(in view: NSView) -> [ReaderPDFView] {
        ((view as? ReaderPDFView).map { [$0] } ?? []) + view.subviews.flatMap(descendantReaderPDFViews(in:))
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
