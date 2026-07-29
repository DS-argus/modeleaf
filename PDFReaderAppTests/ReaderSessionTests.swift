import AppKit
import PDFKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("Read-only PDF session lifecycle")
@MainActor
struct ReaderSessionTests {
    @Test("a newly mounted PDF opens once on page one fitted inside the visible canvas")
    func initialPresentationFitsFirstPageOnce() throws {
        try withSession(pageCount: 3) { session, _ in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = session.contentView
            session.contentView.frame = window.contentLayoutRect
            session.contentView.layoutSubtreeIfNeeded()

            let view = try #require(descendantPDFViews(in: session.contentView).only)
            view.layoutDocumentView()

            #expect(session.initialPresentationState == .applied)
            #expect(session.currentPageNumber == 1)
            #expect(session.viewMode == .fitPage)
            #expect(view.displayMode == .singlePage)
            #expect(view.autoScales)
            #expect(abs(view.scaleFactor - view.scaleFactorForSizeToFit) < 0.01)

            session.zoom(by: 1.25)
            let manuallySelectedScale = session.scaleFactor
            session.contentView.needsLayout = true
            session.contentView.layoutSubtreeIfNeeded()

            #expect(session.initialPresentationState == .applied)
            #expect(session.viewMode == .manual)
            #expect(abs(session.scaleFactor - manuallySelectedScale) < 0.0001)
        }
    }

    @Test("an explicit view command before mounting supersedes the initial fit")
    func explicitViewCommandSupersedesInitialPresentation() throws {
        try withSession(pageCount: 2) { session, _ in
            session.fitWidth()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = session.contentView
            session.contentView.frame = window.contentLayoutRect
            session.contentView.layoutSubtreeIfNeeded()

            let view = try #require(descendantPDFViews(in: session.contentView).only)
            #expect(session.initialPresentationState == .supersededByUser)
            #expect(session.viewMode == .fitWidth)
            #expect(view.displayMode == .singlePageContinuous)
        }
    }


    @Test("seeded duplicate opens the source page fit-to-page regardless of window size")
    func seededDuplicatePresentation() throws {
        // The split-duplicate contract keeps the source's reading position but
        // always mounts fit-to-page in the new pane's own bounds; view mode and
        // zoom are not carried (ReaderDuplicationSnapshot).
        for size in [NSSize(width: 720, height: 480), NSSize(width: 360, height: 620)] {
            try withSession(pageCount: 3) { session, sourceURL in
                session.seedPendingPresentation(ReaderDuplicationSnapshot(sourceURL: sourceURL, oneBasedPage: 2))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = session.contentView
                session.contentView.frame = window.contentLayoutRect
                session.contentView.layoutSubtreeIfNeeded()
                #expect(session.initialPresentationState == .applied)
                #expect(session.currentPageNumber == 2)
                #expect(session.viewMode == .fitPage)
                let view = try #require(descendantPDFViews(in: session.contentView).only)
                #expect(view.autoScales)
                #expect(view.displayMode == .singlePage)
            }
        }
    }

    @Test("I-PDF-03 page navigation is one-based, directional, and explicit-range safe")
    func pageNavigation() throws {
        try withSession(pageCount: 3) { session, _ in
            #expect(session.currentPageNumber == 1)
            #expect(session.goToNextPage())
            #expect(session.currentPageNumber == 2)
            #expect(session.goToLastPage())
            #expect(session.currentPageNumber == 3)
            #expect(!session.goToPage(0))
            #expect(!session.goToPage(4))
            #expect(session.currentPageNumber == 3)
            #expect(!session.goToNextPage())
            #expect(session.goToPreviousPage())
            #expect(session.currentPageNumber == 2)
            #expect(session.goToFirstPage())
            #expect(session.currentPageNumber == 1)
            #expect(!session.goToPreviousPage())
        }
    }

    @Test("I-PDF-04 manual, actual-size, fit-width, and fit-page are distinct view states")
    func zoomAndFitStates() throws {
        try withSession(pageCount: 2) { session, _ in
            session.contentView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            session.contentView.layoutSubtreeIfNeeded()

            session.resetZoom()
            #expect(session.viewMode == .actualSize)
            #expect(abs(session.scaleFactor - 1) < 0.0001)

            session.zoom(by: 1.25)
            #expect(session.viewMode == .manual)
            #expect(session.scaleFactor > 1)

            session.fitWidth()
            #expect(session.viewMode == .fitWidth)
            let view = try #require(descendantPDFViews(in: session.contentView).only)
            #expect(view.displayMode == .singlePageContinuous)
            #expect(view.autoScales)

            session.fitPage()
            #expect(session.viewMode == .fitPage)
            #expect(view.displayMode == .singlePage)
            #expect(view.autoScales)
        }
    }

    @Test("I-NAV-01 point and viewport scrolling move the real PDFKit document clip")
    func realPDFKitScrolling() throws {
        try withSession(pageCount: 5) { session, _ in
            session.fitWidth()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = session.contentView
            session.contentView.frame = window.contentLayoutRect
            session.contentView.layoutSubtreeIfNeeded()
            let pdfView = try #require(descendantPDFViews(in: session.contentView).only)
            pdfView.layoutDocumentView()
            let scrollView = try #require(
                descendantScrollViews(in: pdfView).first {
                    guard let documentView = $0.documentView else { return false }
                    return documentView.bounds.height > $0.contentView.bounds.height
                }
            )

            let initial = scrollView.contentView.bounds.origin
            session.moveVertically(byPoints: 48)
            let afterPointScroll = scrollView.contentView.bounds.origin
            session.moveVertically(byViewportFraction: 0.8)
            let afterViewportScroll = scrollView.contentView.bounds.origin

            #expect(afterPointScroll != initial)
            #expect(afterViewportScroll != afterPointScroll)
        }
    }

    @Test("fit-page followed by zoom-in scrolls an axis only when the page exceeds that viewport")
    func zoomedFitPageUsesScrollSemantics() throws {
        try withSession(pageCount: 3) { session, _ in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = session.contentView
            session.contentView.frame = window.contentLayoutRect
            session.contentView.layoutSubtreeIfNeeded()

            let pdfView = try #require(descendantPDFViews(in: session.contentView).only)
            session.fitPage()
            pdfView.layoutDocumentView()
            session.zoom(by: BuiltInDefaults.config.navigation.zoomFactor)

            let scrollView = try #require(
                descendantScrollViews(in: pdfView).first {
                    guard let documentView = $0.documentView else { return false }
                    return documentView.bounds.height > $0.contentView.bounds.height
                }
            )
            let documentView = try #require(scrollView.documentView)
            while documentView.bounds.height - scrollView.contentView.bounds.height
                < scrollView.contentView.bounds.height
            {
                session.zoom(by: BuiltInDefaults.config.navigation.zoomFactor)
            }
            let initialPage = session.currentPageNumber
            let initial = scrollView.contentView.bounds.origin

            session.moveVertically(byPoints: 48)
            let afterPointScroll = scrollView.contentView.bounds.origin
            session.moveVertically(byViewportFraction: 0.8)
            let afterViewportScroll = scrollView.contentView.bounds.origin

            #expect(session.viewMode == .manual)
            #expect(session.currentPageNumber == initialPage)
            #expect(afterPointScroll != initial)
            #expect(afterViewportScroll != afterPointScroll)
        }
    }

    @Test("a wide page directly exercises horizontal-only overflow at the minimum window size")
    func widePageFixtureUsesAxisBoundedMovement() throws {
        try withSession(
            pageCount: 3,
            pageSize: CGSize(width: 1_200, height: 240)
        ) { session, _ in
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: WindowVisualMetrics.minimumSize),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = session.contentView
            session.contentView.frame = window.contentLayoutRect
            session.contentView.layoutSubtreeIfNeeded()

            let pdfView = try #require(descendantPDFViews(in: session.contentView).only)
            session.fitPage()
            pdfView.layoutDocumentView()
            let fittedScale = session.scaleFactor
            session.zoom(by: BuiltInDefaults.config.navigation.zoomFactor)

            let scrollView = try #require(descendantScrollViews(in: pdfView).first)
            let clipView = scrollView.contentView
            let documentView = try #require(scrollView.documentView)
            #expect(documentView.bounds.width > clipView.bounds.width)
            #expect(documentView.bounds.height <= clipView.bounds.height)
            #expect(
                abs(
                    session.scaleFactor
                        - fittedScale * BuiltInDefaults.config.navigation.zoomFactor
                ) < 0.001
            )

            let initialPage = session.currentPageNumber
            let initial = clipView.bounds.origin
            session.moveVertically(byPoints: 48)
            session.moveVertically(byViewportFraction: 0.8)
            #expect(abs(clipView.bounds.origin.x - initial.x) < 0.001)
            #expect(abs(clipView.bounds.origin.y - initial.y) < 0.001)
            #expect(session.currentPageNumber == initialPage)

            session.moveHorizontally(byPoints: 48)
            #expect(clipView.bounds.origin.x != initial.x)

            while documentView.bounds.height <= clipView.bounds.height {
                session.zoom(by: BuiltInDefaults.config.navigation.zoomFactor)
            }
            let beforeVerticalMovement = clipView.bounds.origin
            session.moveVertically(byPoints: 48)
            #expect(clipView.bounds.origin.y != beforeVerticalMovement.y)
            #expect(session.currentPageNumber == initialPage)
        }
    }

    @Test("zoomed fit-page movement advances only after reaching a vertical page boundary")
    func zoomedFitPageAdvancesAtVerticalBoundary() throws {
        try withSession(pageCount: 3) { session, _ in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = session.contentView
            session.contentView.frame = window.contentLayoutRect
            session.contentView.layoutSubtreeIfNeeded()

            let pdfView = try #require(descendantPDFViews(in: session.contentView).only)
            session.fitPage()
            pdfView.layoutDocumentView()
            session.zoom(by: BuiltInDefaults.config.navigation.zoomFactor)

            let scrollView = try #require(
                descendantScrollViews(in: pdfView).first {
                    guard let documentView = $0.documentView else { return false }
                    return documentView.bounds.height > $0.contentView.bounds.height
                }
            )
            let clipView = scrollView.contentView

            session.moveVertically(byViewportFraction: 10)
            let bottomOrigin = clipView.bounds.origin
            #expect(session.currentPageNumber == 1)

            session.moveVertically(byPoints: 48)
            #expect(session.currentPageNumber == 2)

            let nextPageStart = clipView.bounds.origin
            session.moveVertically(byPoints: 48)
            #expect(session.currentPageNumber == 2)
            #expect(clipView.bounds.origin != nextPageStart)

            session.moveVertically(byViewportFraction: -10)
            let topOrigin = clipView.bounds.origin
            #expect(topOrigin != bottomOrigin)
            #expect(session.currentPageNumber == 2)

            session.moveVertically(byPoints: -48)
            #expect(session.currentPageNumber == 1)

            let previousPageEnd = clipView.bounds.origin
            session.moveVertically(byPoints: -48)
            #expect(session.currentPageNumber == 1)
            #expect(clipView.bounds.origin != previousPageEnd)
        }
    }

    @Test("f then zoom-in routes j k d u to scrolling when the page vertically overflows")
    func routedZoomedFitPageMovement() throws {
        try withSession(pageCount: 3) { session, _ in
            let validated = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
            let store = ReaderSessionStore()
            let coordinator = PaneCoordinator(initialStore: store)
            let dispatcher = ActionDispatcher(
                coordinator: coordinator,
                navigation: BuiltInDefaults.config.navigation
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
            defer { controller.close() }

            controller.rootView.layoutSubtreeIfNeeded()
            #expect(controller.routeKeyEventForTesting(
                try #require(makeKeyEvent(characters: "f"))
            ))
            #expect(controller.routeKeyEventForTesting(
                try #require(makeKeyEvent(characters: "=", keyCode: 24))
            ))

            let pdfView = try #require(descendantPDFViews(in: session.contentView).only)
            let scrollView = try #require(
                descendantScrollViews(in: pdfView).first {
                    guard let documentView = $0.documentView else { return false }
                    return documentView.bounds.height > $0.contentView.bounds.height
                }
            )
            let initial = scrollView.contentView.bounds.origin
            #expect(controller.routeKeyEventForTesting(
                try #require(makeKeyEvent(characters: "j", keyCode: 38))
            ))
            let afterJ = scrollView.contentView.bounds.origin
            #expect(controller.routeKeyEventForTesting(
                try #require(makeKeyEvent(characters: "k", keyCode: 40))
            ))
            let afterK = scrollView.contentView.bounds.origin
            #expect(controller.routeKeyEventForTesting(
                try #require(makeKeyEvent(characters: "d", keyCode: 2))
            ))
            let afterD = scrollView.contentView.bounds.origin
            #expect(controller.routeKeyEventForTesting(
                try #require(makeKeyEvent(characters: "u", keyCode: 32))
            ))
            let afterU = scrollView.contentView.bounds.origin

            #expect(session.viewMode == .manual)
            #expect(afterJ != initial)
            #expect(afterK != afterJ)
            #expect(afterD != afterK)
            #expect(afterU != afterD)
        }
    }

    @Test("fit-page vertical movement advances pages while horizontal movement stays bounded")
    func fitPageMovementUsesPageSemantics() throws {
        try withSession(pageCount: 3) { session, _ in
            session.fitPage()
            #expect(session.currentPageNumber == 1)

            session.moveHorizontally(byPoints: 48)
            #expect(session.currentPageNumber == 1)
            session.moveVertically(byPoints: 48)
            #expect(session.currentPageNumber == 2)
            session.moveVertically(byViewportFraction: 0.8)
            #expect(session.currentPageNumber == 3)
            session.moveVertically(byPoints: 48)
            #expect(session.currentPageNumber == 3)
            session.moveVertically(byViewportFraction: -0.8)
            #expect(session.currentPageNumber == 2)
            session.moveVertically(byPoints: -48)
            #expect(session.currentPageNumber == 1)
        }
    }

    @Test("rotation is in-memory, re-fits, wraps, and stays pane-local")
    func rotationIsEphemeralAndPaneLocal() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 2)
            let sourceHash = try PDFFixtureFactory.sha256(of: url)
            let origin = try PDFOpenService().open(url: url)
            let store = ReaderSessionStore()
            #expect(store.insert(origin))
            let coordinator = PaneCoordinator(initialStore: store)
            coordinator.configureDuplication { snapshot in
                try? PDFOpenService().open(url: snapshot.sourceURL)
            }
            _ = try #require(coordinator.split(direction: .sideBySide))
            let rotated = try #require(coordinator.activeSession as? ReaderSession)
            defer {
                origin.prepareForClose()
                rotated.prepareForClose()
            }

            let originView = try #require(descendantPDFViews(in: origin.contentView).only)
            let rotatedView = try #require(descendantPDFViews(in: rotated.contentView).only)
            let originDocument = try #require(originView.document)
            let rotatedDocument = try #require(rotatedView.document)
            rotated.fitWidth()

            rotated.rotateRight()
            #expect(rotated.viewMode == .fitWidth)
            #expect(rotatedView.displayMode == .singlePageContinuous)
            #expect(rotatedView.autoScales)
            #expect((0..<rotatedDocument.pageCount).allSatisfy { rotatedDocument.page(at: $0)?.rotation == 90 })
            #expect((0..<originDocument.pageCount).allSatisfy { originDocument.page(at: $0)?.rotation == 0 })

            rotated.rotateRight()
            #expect((0..<rotatedDocument.pageCount).allSatisfy { rotatedDocument.page(at: $0)?.rotation == 180 })
            rotated.rotateRight()
            #expect((0..<rotatedDocument.pageCount).allSatisfy { rotatedDocument.page(at: $0)?.rotation == 270 })
            rotated.rotateRight()
            #expect((0..<rotatedDocument.pageCount).allSatisfy { rotatedDocument.page(at: $0)?.rotation == 0 })
            rotated.rotateLeft()
            #expect((0..<rotatedDocument.pageCount).allSatisfy { rotatedDocument.page(at: $0)?.rotation == 270 })
            rotated.rotateRight()
            #expect((0..<rotatedDocument.pageCount).allSatisfy { rotatedDocument.page(at: $0)?.rotation == 0 })
            #expect(try PDFFixtureFactory.sha256(of: url) == sourceHash)
        }
    }

    @Test("each tab owns exactly one distinct PDFDocument and PDFView")
    func sessionIsolationUsesDistinctPDFKitObjects() throws {
        try withTemporaryDirectory { directory in
            let firstURL = try PDFFixtureFactory.makeTextPDF(in: directory, name: "first.pdf", pageCount: 1)
            let secondURL = try PDFFixtureFactory.makeTextPDF(in: directory, name: "second.pdf", pageCount: 2)
            let service = PDFOpenService()
            let first = try service.open(url: firstURL)
            let second = try service.open(url: secondURL)
            defer {
                first.prepareForClose()
                second.prepareForClose()
            }

            let firstView = try #require(descendantPDFViews(in: first.contentView).only)
            let secondView = try #require(descendantPDFViews(in: second.contentView).only)
            let firstDocument = try #require(firstView.document)
            let secondDocument = try #require(secondView.document)

            #expect(firstView !== secondView)
            #expect(firstDocument !== secondDocument)
            #expect(firstView.document === firstDocument)
            #expect(secondView.document === secondDocument)
        }
    }

    @Test("I-PDF-05 open, navigate, select, copy, fit, and close preserve source SHA-256")
    func workflowPreservesSourceHash() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 3)
            let before = try PDFFixtureFactory.sha256(of: url)
            var session: ReaderSession? = try PDFOpenService().open(url: url)
            let view = try #require(descendantPDFViews(in: session!.contentView).only)

            _ = session?.goToLastPage()
            session?.scrollBy(xPoints: 24, yPoints: 48)
            session?.scrollVerticallyByViewportFraction(0.8)
            session?.fitPage()
            session?.rotateLeft()
            session?.rotateRight()
            session?.fitWidth()
            session?.resetZoom()
            view.currentSelection = view.document?.selectionForEntireDocument
            view.copy(nil)
            session?.prepareForClose()
            session = nil

            #expect(try PDFFixtureFactory.sha256(of: url) == before)
        }
    }

    @Test("I-PDF-08 teardown is ordered, idempotent, detached, and releasable")
    func deterministicTeardown() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 1)
            let document = try #require(PDFDocument(url: url))
            let search = SearchLifecycleSpy()
            var session: ReaderSession? = ReaderSession(sourceURL: url, document: document, searchLifecycle: search)
            let weakSession = WeakReaderSession(session)
            let view = try #require(descendantPDFViews(in: session!.contentView).only)
            view.currentSelection = document.selectionForEntireDocument

            session?.prepareForClose()

            #expect(search.events == ["cancel", "detach", "clear"])
            #expect(session?.completedTeardownSteps == ReaderTeardownStep.allExpected)
            #expect(session?.isClosed == true)
            #expect(view.currentSelection == nil)
            #expect(view.document == nil)
            #expect(view.superview == nil)

            session?.prepareForClose()
            #expect(search.events == ["cancel", "detach", "clear"])
            session = nil
            #expect(weakSession.value == nil)
        }
    }

    @Test("I-PDF-10 a 300-page fixture supports last-page navigation and in-flight search teardown")
    func largeDocumentNavigationAndSearchTeardown() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(
                in: directory,
                name: "large-page-count.pdf",
                pageCount: 300,
                repeatedText: "large document needle"
            )
            let originalHash = try PDFFixtureFactory.sha256(of: url)
            let session = try PDFOpenService().open(url: url)
            _ = session.contentView

            #expect(session.pageCount == 300)
            #expect(session.goToLastPage())
            #expect(session.currentPageNumber == 300)
            session.beginSearch("needle")
            #expect(session.searchSnapshot.isRunning)

            session.prepareForClose()
            #expect(session.isClosed)
            #expect(try PDFFixtureFactory.sha256(of: url) == originalHash)
        }
    }

    private func withSession(
        pageCount: Int,
        pageSize: CGSize = CGSize(width: 612, height: 792),
        body: (ReaderSession, URL) throws -> Void
    ) throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(
                in: directory,
                pageCount: pageCount,
                pageSize: pageSize
            )
            let session = try PDFOpenService().open(url: url)
            defer { session.prepareForClose() }
            try body(session, url)
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-reader-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func descendantPDFViews(in view: NSView) -> [PDFView] {
        let own = (view as? PDFView).map { [$0] } ?? []
        return own + view.subviews.flatMap(descendantPDFViews(in:))
    }

    private func descendantScrollViews(in view: NSView) -> [NSScrollView] {
        let own = (view as? NSScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap(descendantScrollViews(in:))
    }
}

@MainActor
private final class SearchLifecycleSpy: ReaderSearchLifecycle {
    private(set) var events: [String] = []

    func requestCancellation() { events.append("cancel") }
    func detachCallbacks() { events.append("detach") }
    func clearHighlights() { events.append("clear") }
}

@MainActor
private final class WeakReaderSession {
    weak var value: ReaderSession?

    init(_ value: ReaderSession?) {
        self.value = value
    }
}

private extension ReaderTeardownStep {
    static let allExpected: [ReaderTeardownStep] = [
        .searchCancellationRequested,
        .callbacksAndDelegatesDetached,
        .notificationsDetached,
        .selectionAndHighlightsCleared,
        .documentDetached,
        .contentViewRemoved,
    ]
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
