import AppKit
import PDFKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("Read-only PDF session lifecycle")
@MainActor
struct ReaderSessionTests {
    @Test("a newly mounted PDF opens on page one in continuous fit-width layout")
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
            #expect(session.viewMode == .fitWidth)
            #expect(view.displayMode == .singlePageContinuous)
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
                let navigation = try #require(NavigationSnapshot(pageIndex: 1, pageSpacePoint: CGPoint(x: 306, y: 396)))
                session.seedPendingPresentation(ReaderDuplicationSnapshot(sourceURL: sourceURL, navigation: navigation))
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

    @Test("page prompt, first, and last preserve the active presentation while committing actual landings")
    func pageJumpsPreservePresentation() throws {
        try withSession(pageCount: 3) { session, _ in
            session.contentView.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
            session.contentView.layoutSubtreeIfNeeded()
            session.fitWidth()

            #expect(session.goToLastPage())
            #expect(session.currentPageNumber == 3)
            #expect(session.viewMode == .fitWidth)
            #expect(session.goToFirstPage())
            #expect(session.currentPageNumber == 1)
            #expect(session.viewMode == .fitWidth)
            #expect(session.goBack() == .verifiedLanding)
            #expect(session.currentPageNumber == 3)
        }
    }

    @Test("first-page jump uses the continuous viewport when PDFKit currentPage is stale")
    func firstPageJumpAfterContinuousScrolling() throws {
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
            let initial = try #require(session.duplicationSnapshot?.navigation)
            #expect(session.currentPageNumber == 1)
            #expect(session.goToFirstPage())
            #expect(!session.canGoBack)

            for _ in 0..<4 {
                session.moveVertically(byPoints: 48)
            }
            view.layoutDocumentView()
            let scrolled = try #require(session.duplicationSnapshot?.navigation)
            #expect(session.currentPageNumber == 1)
            #expect(!scrolled.isSameLocation(as: initial))

            #expect(session.goToFirstPage())
            let firstPageLanding = try #require(session.duplicationSnapshot?.navigation)
            #expect(firstPageLanding.pageIndex == 0)
            #expect(
                abs(firstPageLanding.pageSpacePoint.y - initial.pageSpacePoint.y)
                    < abs(scrolled.pageSpacePoint.y - initial.pageSpacePoint.y)
            )
            #expect(session.canGoBack)
            #expect(session.goBack() == .verifiedLanding)
            let restored = try #require(session.duplicationSnapshot?.navigation)
            #expect(restored.isSameLocation(as: scrolled))
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
            #expect(session.statusSnapshot.mode.isEmpty)

            session.fitPage()
            #expect(session.viewMode == .fitPage)
            #expect(view.displayMode == .singlePage)
            #expect(view.autoScales)
            #expect(session.statusSnapshot.mode == "FIT PAGE")
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

    @Test("zoom exits fit-page into continuous manual layout while preserving the reading anchor")
    func zoomExitsFitPageIntoContinuousLayout() throws {
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
            #expect(session.goToPage(2))
            session.fitPage()
            let anchor = try #require(session.duplicationSnapshot?.navigation)

            session.zoom(by: 0.8)
            pdfView.layoutDocumentView()

            #expect(session.viewMode == .manual)
            #expect(pdfView.displayMode == .singlePageContinuous)
            #expect(session.statusSnapshot.mode.isEmpty)
            #expect(session.currentPageNumber == 2)
            let landing = try #require(session.duplicationSnapshot?.navigation)
            #expect(landing.pageIndex == anchor.pageIndex)
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

    @Test("rotation is in-memory, re-fits both fit modes, wraps, and stays pane-local")
    func rotationIsEphemeralAndPaneLocal() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 2)
            let sourceHash = try PDFFixtureFactory.sha256(of: url)

            for fitMode in [ReaderViewMode.fitWidth, .fitPage] {
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

                let originDocument = try #require(descendantPDFViews(in: origin.contentView).only?.document)
                let rotatedView = try #require(descendantPDFViews(in: rotated.contentView).only)
                let rotatedDocument = try #require(rotatedView.document)
                switch fitMode {
                case .fitWidth:
                    rotated.fitWidth()
                case .fitPage:
                    rotated.fitPage()
                default:
                    Issue.record("Unexpected non-fit mode")
                    continue
                }

                rotated.rotateRight()
                #expect(rotated.viewMode == fitMode)
                #expect(rotatedView.displayMode == (fitMode == .fitWidth ? .singlePageContinuous : .singlePage))
                #expect(rotatedView.autoScales)
                #expect((0..<rotatedDocument.pageCount).allSatisfy { rotatedDocument.page(at: $0)?.rotation == 90 })
                #expect((0..<originDocument.pageCount).allSatisfy { originDocument.page(at: $0)?.rotation == 0 })

                let freshSession = try PDFOpenService().open(url: url)
                defer { freshSession.prepareForClose() }
                let freshDocument = try #require(descendantPDFViews(in: freshSession.contentView).only?.document)
                #expect((0..<freshDocument.pageCount).allSatisfy { freshDocument.page(at: $0)?.rotation == 0 })

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
            }

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
            var session: ReaderSession? = ReaderSession(sourceURL: url, document: document, searchControllerFactory: { _, _ in search })
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

    @Test("meaningful jumps commit only verified landings while next and previous remain unrecorded")
    func readerOwnedNavigationHistory() throws {
        try withSession(pageCount: 3) { session, _ in
            #expect(!session.canGoBack)
            #expect(session.goToPage(2))
            #expect(session.canGoBack)
            #expect(session.goToNextPage())
            #expect(session.currentPageNumber == 3)
            #expect(session.goBack() == .verifiedLanding)
            #expect(session.currentPageNumber == 1)
            #expect(session.canGoForward)
            #expect(session.goForward() == .verifiedLanding)
            #expect(session.currentPageNumber == 3)
        }
    }

    @Test("duplicate snapshots contain position but never source history")
    func duplicationSnapshotContainsNavigationPosition() throws {
        try withSession(pageCount: 3) { session, sourceURL in
            #expect(session.goToPage(2))
            let snapshot = try #require(session.duplicationSnapshot)
            #expect(snapshot.sourceURL == sourceURL)
            #expect(snapshot.navigation.pageIndex == 1)
        }
    }

    @Test("search generation replacement retains the epoch boundary and ignores stale landings")
    func searchGenerationReplacement() throws {
        try withSession(pageCount: 3) { session, _ in
            #expect(session.activateSearchNavigation(searchGeneration: 1) == .armed)
            #expect(session.activateSearchNavigation(searchGeneration: 2) == .retagged)
            #expect(session.goToNextPage())
            #expect(session.recordVerifiedSearchLanding(searchGeneration: 1, landing: NavigationSnapshot(pageIndex: 1, pageSpacePoint: .zero)!) == .ignored)
            #expect(session.recordVerifiedSearchLanding(searchGeneration: 2, landing: NavigationSnapshot(pageIndex: 1, pageSpacePoint: .zero)!) == .firstCommitted)
            #expect(session.activateSearchNavigation(searchGeneration: 3) == .retagged)
            #expect(session.recordVerifiedSearchLanding(searchGeneration: 2, landing: NavigationSnapshot(pageIndex: 1, pageSpacePoint: .zero)!) == .ignored)
        }
    }

    @Test("duplicate initialization rejects an anchor outside the required source page")
    func duplicateInitializationRejectsInvalidAnchor() throws {
        try withSession(pageCount: 2) { session, sourceURL in
            let invalidAnchor = try #require(NavigationSnapshot(pageIndex: 1, pageSpacePoint: CGPoint(x: -1, y: -1)))
            session.seedPendingPresentation(ReaderDuplicationSnapshot(sourceURL: sourceURL, navigation: invalidAnchor))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = session.contentView
            session.contentView.frame = window.contentLayoutRect
            session.contentView.layoutSubtreeIfNeeded()
            #expect(session.isClosed)
            #expect(session.completedTeardownSteps == ReaderTeardownStep.allExpected)
        }
    }

    @Test("navigation adapter preflight rejection leaves history and presentation unchanged")
    func navigationAdapterPreflightRejection() throws {
        try withScriptedSession(captures: [nil], restores: []) { session, script in
            var publications = 0
            session.setPresentationChangeHandler { publications += 1 }
            let destination = try #require(NavigationSnapshot(pageIndex: 1, pageSpacePoint: .zero))
            #expect(session.performNavigation(.meaningfulJump(producer: .pagePrompt, destination: destination)) == .preflightRejected)
            #expect(session.isNavigationHistoryHealthy)
            #expect(!session.canGoBack && !session.canGoForward)
            #expect(publications == 0)
            #expect(script.restoreRequests.isEmpty)
        }
    }

    @Test("navigation adapter compensated failure preserves committed topology and epoch")
    func navigationAdapterCompensatedFailure() throws {
        let origin = try #require(NavigationSnapshot(pageIndex: 0, pageSpacePoint: .zero))
        let destination = try #require(NavigationSnapshot(pageIndex: 1, pageSpacePoint: .zero))
        try withScriptedSession(captures: [origin], restores: [.compensatedFailure]) { session, script in
            var publications = 0
            session.setPresentationChangeHandler { publications += 1 }
            #expect(session.performNavigation(.meaningfulJump(producer: .pagePrompt, destination: destination)) == .compensatedFailure)
            #expect(session.isNavigationHistoryHealthy)
            #expect(!session.canGoBack && !session.canGoForward)
            #expect(publications == 0)
            #expect(script.restoreRequests == [destination])
        }
    }

    @Test("missing post-attempt landing compensates instead of disabling history")
    func missingLandingCompensates() throws {
        let origin = try #require(NavigationSnapshot(pageIndex: 0, pageSpacePoint: .zero))
        let destination = try #require(NavigationSnapshot(pageIndex: 1, pageSpacePoint: .zero))
        try withScriptedSession(
            captures: [origin, nil],
            restores: [.verifiedLanding, .compensatedFailure]
        ) { session, script in
            #expect(
                session.performNavigation(.meaningfulJump(producer: .pagePrompt, destination: destination))
                    == .uncompensatedInvariantFailure(actualLanding: nil)
            )
            #expect(!session.isNavigationHistoryHealthy)
            #expect(!session.canGoBack && !session.canGoForward)
            #expect(script.restoreRequests == [destination, origin])
        }
    }

    @Test("navigation adapter invariant failure fails closed with final landing")
    func navigationAdapterUncompensatedFailure() throws {
        let origin = try #require(NavigationSnapshot(pageIndex: 0, pageSpacePoint: .zero))
        let final = try #require(NavigationSnapshot(pageIndex: 2, pageSpacePoint: CGPoint(x: 7, y: 9)))
        let destination = try #require(NavigationSnapshot(pageIndex: 1, pageSpacePoint: .zero))
        try withScriptedSession(captures: [origin], restores: [.uncompensatedInvariantFailure(actualLanding: final)]) { session, _ in
            var publications = 0
            session.setPresentationChangeHandler { publications += 1 }
            var outcomes: [NavigationTransactionOutcome] = []
            session.setNavigationOutcomeHandler { outcomes.append($0) }
            #expect(session.performNavigation(.meaningfulJump(producer: .pagePrompt, destination: destination)) == .uncompensatedInvariantFailure(actualLanding: final))
            #expect(!session.isNavigationHistoryHealthy)
            #expect(!session.canGoBack && !session.canGoForward)
            #expect(session.navigationAvailabilityDetail == "Navigation history unavailable")
            #expect(publications == 1)
            #expect(outcomes == [.uncompensatedInvariantFailure(actualLanding: final)])
        }
    }

    @Test("navigation adapter commits the verified actual landing")
    func navigationAdapterCommitsActualLanding() throws {
        let origin = try #require(NavigationSnapshot(pageIndex: 0, pageSpacePoint: .zero))
        let requested = try #require(NavigationSnapshot(pageIndex: 1, pageSpacePoint: .zero))
        let actual = try #require(NavigationSnapshot(pageIndex: 1, pageSpacePoint: CGPoint(x: 12, y: 18)))
        try withScriptedSession(captures: [origin, actual, actual], restores: [.verifiedLanding, .verifiedLanding]) { session, script in
            #expect(session.performNavigation(.meaningfulJump(producer: .pagePrompt, destination: requested)) == .verifiedLanding)
            #expect(session.goBack() == .verifiedLanding)
            #expect(script.restoreRequests == [requested, origin])
        }
    }

    private func withScriptedSession(
        captures: [NavigationSnapshot?],
        restores: [NavigationRestoreOutcome],
        body: (ReaderSession, NavigationScript) throws -> Void
    ) throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 3)
            let script = NavigationScript(captures: captures, restores: restores)
            let document = try #require(PDFDocument(url: url))
            let session = ReaderSession(sourceURL: url, document: document, navigationCapture: { script.capture() }, navigationRestore: { script.restore($0) })
            defer { session.prepareForClose() }
            try body(session, script)
        }
    }

    @Test("normal restore centers the page-space anchor without changing fit presentation")
    func normalRestorePreservesFitPresentationAndAnchor() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 2)
            let document = try #require(PDFDocument(url: url))
            let controller = PDFViewController(document: document, traceID: OpenTraceID(), metrics: NoopPDFOpenMetrics())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = controller.view
            controller.view.frame = window.contentLayoutRect
            controller.view.layoutSubtreeIfNeeded()
            let target = try #require(NavigationSnapshot(pageIndex: 1, pageSpacePoint: CGPoint(x: 306, y: 396)))
            #expect(controller.restoreNavigationSnapshot(target) == .verifiedLanding)
            let captured = try #require(controller.captureNavigationSnapshot())
            #expect(captured.isSameLocation(as: target))
            #expect(controller.viewMode == .fitWidth)
            let view = try #require(descendantPDFViews(in: controller.view).only)
            #expect(view.autoScales && view.displayMode == .singlePageContinuous)
        }
    }

    @Test("outline destination normalization repairs only near edges and rejects invalid locations")
    func outlineDestinationNormalization() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 1, pageSize: CGSize(width: 612, height: 676.3))
            let document = try #require(PDFDocument(url: url))
            let page = try #require(document.page(at: 0))
            let controller = PDFViewController(document: document, traceID: OpenTraceID(), metrics: NoopPDFOpenMetrics())
            let near = try #require(controller.navigationSnapshot(forOutlineDestination: PDFDestination(page: page, at: CGPoint(x: 42, y: 679))))
            #expect(near.pageSpacePoint.y == page.bounds(for: .mediaBox).maxY)
            #expect(controller.navigationSnapshot(forOutlineDestination: PDFDestination(page: page, at: CGPoint(x: 42, y: 690))) == nil)
            #expect(controller.navigationSnapshot(forOutlineDestination: PDFDestination(page: PDFPage(), at: .zero)) == nil)
        }
    }

    @Test("viewport epochs terminate once with changed or no-change provenance")
    func viewportMutationEpochsTerminateAtMostOnce() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 2)
            let document = try #require(PDFDocument(url: url))
            let controller = PDFViewController(document: document, traceID: OpenTraceID(), metrics: NoopPDFOpenMetrics())
            var terminals: [ReaderViewportMutationTerminal] = []
            controller.setViewportMutationHandler { terminals.append($0) }
            let epoch = controller.beginViewportMutation(.userAction)
            controller.finishViewportMutation(epoch)
            controller.finishViewportMutation(epoch)
            #expect(terminals.count == 1)
            if case let .noChange(result) = terminals[0] { #expect(result.id == epoch.id) } else { Issue.record("expected no-change terminal") }
            let stale = controller.beginViewportMutation(.tocActivation)
            let replacement = controller.beginViewportMutation(.system)
            controller.finishViewportMutation(stale)
            controller.finishViewportMutation(replacement)
            #expect(terminals.count == 3)
        }
    }

    @Test("search producer history matrix coalesces, branches, replaces, and ignores stale callbacks")
    func searchProducerHistoryMatrix() throws {
        try withSearchHistoryHarness { session, navigation, driver, coordinator, presenter in
            let a = navigation.position(0)
            let s1 = navigation.position(1)
            let s2 = navigation.position(2)
            let m = navigation.position(3)

            coordinator.request("alpha")
            let first = try #require(driver.generations.last)
            presenter.nextLanding = s1
            driver.match(generation: first)
            driver.end(generation: first)
            presenter.nextLanding = s2
            #expect(coordinator.selectNext()) // S1 → S2 coalesces.
            #expect(session.canGoBack)
            #expect(session.goBack() == .verifiedLanding)
            #expect(navigation.current == a)
            #expect(session.goForward() == .verifiedLanding)
            // A successful traversal ended the epoch; a new result branches.
            #expect(session.goBack() == .verifiedLanding)
            coordinator.request("branch")
            let branch = try #require(driver.generations.last)
            presenter.nextLanding = s1
            driver.match(generation: branch)
            driver.end(generation: branch)
            #expect(!session.canGoForward)
            #expect(coordinator.selectNext())
            #expect(!session.canGoForward)

            // Pending search followed by meaningful M splits the epoch.
            coordinator.request("pending")
            let pending = try #require(driver.generations.last)
            #expect(session.performNavigation(.meaningfulJump(producer: .pagePrompt, destination: m)) == .verifiedLanding)
            driver.end(generation: pending) // no result, cannot commit.

            coordinator.request("beta")
            let beta = try #require(driver.generations.last)
            presenter.nextLanding = s2
            driver.match(generation: beta)
            driver.end(generation: beta)
            #expect(session.goBack() == .verifiedLanding)
            #expect(navigation.current == m)
            #expect(session.goBack() == .verifiedLanding)
            #expect(navigation.current == s1)
            #expect(session.goBack() == .verifiedLanding)
            #expect(navigation.current == a)
            #expect(session.goForward() == .verifiedLanding)
            #expect(navigation.current == s1)
            #expect(session.goForward() == .verifiedLanding)
            #expect(navigation.current == m)
            #expect(session.goForward() == .verifiedLanding)
            #expect(navigation.current == s2)

            // Replacement retags; stale callbacks cannot alter history.
            coordinator.request("old")
            let old = try #require(driver.generations.last)
            coordinator.request("new")
            driver.end(generation: old)
            driver.runScheduled()
            let replacement = try #require(driver.generations.last)
            presenter.nextLanding = s1
            driver.match(generation: old)
            driver.end(generation: old)
            driver.match(generation: replacement)
            driver.end(generation: replacement)
            #expect(session.canGoBack)

            session.clearSearch()
            coordinator.request("none")
            let none = try #require(driver.generations.last)
            driver.end(generation: none)
            #expect(session.canGoBack) // no-result adds nothing.
            session.prepareForClose()
            let ignored = coordinator.ignoredCallbackCount
            driver.match(generation: replacement)
            driver.end(generation: replacement)
            #expect(coordinator.ignoredCallbackCount == ignored)
        }
    }

    @Test("same-generation result re-arms after Back and branches from the live origin")
    func sameGenerationResultAfterBackRearms() throws {
        try withSearchHistoryHarness { session, navigation, driver, coordinator, presenter in
            let a = navigation.position(0)
            let s1 = navigation.position(1)
            let s2 = navigation.position(2)
            coordinator.request("needle")
            let generation = try #require(driver.generations.last)
            presenter.nextLanding = s1
            driver.match(generation: generation)
            driver.match(generation: generation)
            driver.end(generation: generation)
            #expect(session.goBack() == .verifiedLanding)
            #expect(navigation.current == a)
            presenter.nextLanding = s2
            #expect(coordinator.selectNext())
            #expect(!session.canGoForward)
            #expect(session.goBack() == .verifiedLanding)
            #expect(navigation.current == a)
            #expect(session.goForward() == .verifiedLanding)
            #expect(navigation.current == s2)
        }
    }

    @Test("same-generation result after meaningful jump branches from that jump")
    func sameGenerationResultAfterMeaningfulJumpRearms() throws {
        try withSearchHistoryHarness { session, navigation, driver, coordinator, presenter in
            let a = navigation.position(0)
            let s1 = navigation.position(1)
            let s2 = navigation.position(2)
            let m = navigation.position(3)
            coordinator.request("needle")
            let generation = try #require(driver.generations.last)
            presenter.nextLanding = s1
            driver.match(generation: generation)
            driver.match(generation: generation)
            driver.end(generation: generation)
            #expect(session.performNavigation(.meaningfulJump(producer: .pagePrompt, destination: m)) == .verifiedLanding)
            presenter.nextLanding = s2
            #expect(coordinator.selectNext())
            #expect(!session.canGoForward)
            #expect(session.goBack() == .verifiedLanding)
            #expect(navigation.current == m)
            #expect(session.goBack() == .verifiedLanding)
            #expect(navigation.current == s1)
            #expect(session.goBack() == .verifiedLanding)
            #expect(navigation.current == a)
        }
    }
    @Test("search capture preflight preserves presentation and fails history closed after movement")
    func searchCapturePreflightFailsHistoryClosed() throws {
        try withSearchHistoryHarness { session, navigation, driver, coordinator, presenter in
            let s1 = navigation.position(1)
            let s2 = navigation.position(2)
            navigation.captureEnabled = false
            var outcomes: [NavigationTransactionOutcome] = []
            session.setNavigationOutcomeHandler { outcomes.append($0) }
            coordinator.request("needle")
            let generation = try #require(driver.generations.last)
            presenter.nextLanding = s1
            driver.match(generation: generation)
            driver.match(generation: generation)
            driver.end(generation: generation)
            #expect(coordinator.snapshot.activeMatchIndex == 0)
            #expect(navigation.current == s1)
            #expect(presenter.nextLanding == nil)
            presenter.nextLanding = s2
            #expect(coordinator.selectNext())
            #expect(navigation.current == s2)
            #expect(!session.canGoBack && !session.canGoForward)
            #expect(!session.isNavigationHistoryHealthy)
            #expect(outcomes == [.uncompensatedInvariantFailure(actualLanding: s1)])
        }
    }

    @Test("mounted search remains usable when shared navigation capture fails")
    func mountedSearchSurvivesSharedCaptureFailure() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 3)
            let document = try #require(PDFDocument(url: url))
            let session = ReaderSession(sourceURL: url, document: document, navigationCapture: { nil })
            defer { session.prepareForClose() }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = session.contentView
            session.contentView.frame = window.contentLayoutRect
            session.contentView.layoutSubtreeIfNeeded()

            session.beginSearch("needle")
            let deadline = Date().addingTimeInterval(2)
            while session.searchSnapshot.isRunning, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }

            try #require(!session.searchSnapshot.isRunning)
            try #require(session.searchSnapshot.matchCount == 3)
            try #require(session.searchSnapshot.activeMatchIndex == 0)
            try #require(session.currentPageNumber == 1)
            try #require(session.selectNextSearchResult())
            try #require(session.searchSnapshot.activeMatchIndex == 1)
            try #require(session.currentPageNumber == 2)
            try #require(!session.isNavigationHistoryHealthy)
            try #require(!session.canGoBack && !session.canGoForward)
        }
    }

    @Test("initial no-result and cancelled-before-first searches leave session history empty")
    func initialSearchWithoutLandingLeavesHistoryEmpty() throws {
        try withSearchHistoryHarness { session, _, driver, coordinator, _ in
            coordinator.request("none")
            let none = try #require(driver.generations.last)
            driver.end(generation: none)
            #expect(!session.canGoBack)
            coordinator.request("cancel")
            let cancelled = try #require(driver.generations.last)
            session.clearSearch()
            driver.match(generation: cancelled)
            driver.end(generation: cancelled)
            #expect(!session.canGoBack && !session.canGoForward)
        }
    }

    private func withSearchHistoryHarness(
        body: (ReaderSession, SearchNavigationScript, SessionSearchDriver, ReaderSearchCoordinator, SessionSearchPresenter) throws -> Void
    ) throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 4)
            let navigation = SearchNavigationScript()
            let driver = SessionSearchDriver()
            let presenter = SessionSearchPresenter(navigation: navigation)
            var coordinator: ReaderSearchCoordinator!
            let session = ReaderSession(
                sourceURL: url,
                document: try #require(PDFDocument(url: url)),
                searchControllerFactory: { activate, reportOutcome in
                    let value = ReaderSearchCoordinator(
                        driver: driver,
                        presenter: presenter,
                        scheduler: driver,
                        activateNavigation: activate,
                        reportNavigationOutcome: reportOutcome
                    )
                    coordinator = value
                    return value
                },
                navigationCapture: { navigation.capture() },
                navigationRestore: { destination in navigation.current = destination; return .verifiedLanding }
            )
            defer { session.prepareForClose() }
            try body(session, navigation, driver, coordinator, presenter)
        }
    }

    @Test("print delegates once while open and never after teardown")
    func printLifecycle() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 1)
            let document = try #require(PDFDocument(url: url))
            var printCount = 0
            let session = ReaderSession(
                sourceURL: url,
                document: document,
                printHandler: {
                    printCount += 1
                    return true
                }
            )

            #expect(session.printDocument())
            #expect(printCount == 1)
            session.prepareForClose()
            #expect(!session.printDocument())
            #expect(printCount == 1)
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
private final class SearchLifecycleSpy: ReaderSearchControlling {
    private(set) var events: [String] = []
    let snapshot = ReaderSearchSnapshot.empty

    func setChangeHandler(_ handler: (() -> Void)?) {}
    func request(_ query: String) {}
    func selectNext() -> Bool { false }
    func selectPrevious() -> Bool { false }
    func clear() {}
    func requestCancellation() { events.append("cancel") }
    func detachCallbacks() { events.append("detach") }
    func clearHighlights() { events.append("clear") }
}
@MainActor
private final class NavigationScript {
    private var captures: [NavigationSnapshot?]
    private var restores: [NavigationRestoreOutcome]
    private(set) var restoreRequests: [NavigationSnapshot] = []

    init(captures: [NavigationSnapshot?], restores: [NavigationRestoreOutcome]) {
        self.captures = captures
        self.restores = restores
    }

    func capture() -> NavigationSnapshot? {
        captures.isEmpty ? nil : captures.removeFirst()
    }

    func restore(_ destination: NavigationSnapshot) -> NavigationRestoreOutcome {
        restoreRequests.append(destination)
        return restores.isEmpty ? .preflightRejected : restores.removeFirst()
    }
}


@MainActor
private final class WeakReaderSession {
    weak var value: ReaderSession?
    init(_ value: ReaderSession?) { self.value = value }
}

@MainActor
private final class SearchNavigationScript {
    var current: NavigationSnapshot = NavigationSnapshot(pageIndex: 0, pageSpacePoint: .zero)!
    var captureEnabled = true
    func capture() -> NavigationSnapshot? { captureEnabled ? current : nil }
    func position(_ pageIndex: Int) -> NavigationSnapshot { NavigationSnapshot(pageIndex: pageIndex, pageSpacePoint: .zero)! }
}

@MainActor
private final class SessionSearchDriver: ReaderSearchDriving, ReaderSearchReplacementScheduling {
    weak var sink: (any ReaderSearchDriverSink)?
    private(set) var generations: [UInt64] = []
    private var scheduled: [@MainActor @Sendable () -> Void] = []
    func begin(query: String, generation: UInt64) { generations.append(generation); sink?.searchDriverDidBegin(generation: generation) }
    func cancel(generation: UInt64) {}
    func detach() { sink = nil }
    func match(generation: UInt64) { sink?.searchDriverDidMatch(PDFSelection(document: PDFDocument()), generation: generation) }
    func end(generation: UInt64) { sink?.searchDriverDidEnd(generation: generation) }
    func schedule(_ operation: @escaping @MainActor @Sendable () -> Void) { scheduled.append(operation) }
    func runScheduled() { guard !scheduled.isEmpty else { return }; scheduled.removeFirst()() }
}

@MainActor
private final class SessionSearchPresenter: ReaderSearchResultPresenting {
    private let navigation: SearchNavigationScript
    var nextLanding: NavigationSnapshot?
    var presentationOutcomes: [ReaderSearchResultDisplayOutcome] = []
    var activationOutcomes: [ReaderSearchResultDisplayOutcome] = []
    private(set) var restoredIndices: [Int?] = []

    init(navigation: SearchNavigationScript) { self.navigation = navigation }

    @discardableResult
    func presentSearchResults(_ selections: [PDFSelection], activeIndex: Int?) -> ReaderSearchResultDisplayOutcome {
        if let nextLanding { navigation.current = nextLanding; self.nextLanding = nil }
        return presentationOutcomes.isEmpty ? .displayedDistinct(landing: navigation.current) : presentationOutcomes.removeFirst()
    }

    @discardableResult
    func activateSearchResult(at index: Int) -> ReaderSearchResultDisplayOutcome {
        if let nextLanding { navigation.current = nextLanding; self.nextLanding = nil }
        return activationOutcomes.isEmpty ? .displayedDistinct(landing: navigation.current) : activationOutcomes.removeFirst()
    }

    func restoreSearchResultSelection(at index: Int?) { restoredIndices.append(index) }
    func clearSearchResults() {}
}

private extension ReaderTeardownStep {
    static let allExpected: [ReaderTeardownStep] = [
        .searchCancellationRequested, .callbacksAndDelegatesDetached,
        .notificationsDetached, .selectionAndHighlightsCleared,
        .documentDetached, .contentViewRemoved,
    ]
}

private extension Array { var only: Element? { count == 1 ? self[0] : nil } }
