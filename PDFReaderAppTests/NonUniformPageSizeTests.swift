import AppKit
import PDFKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("Documents with non-uniform page sizes")
@MainActor
struct NonUniformPageSizeTests {
    private static let commonSize = CGSize(width: 300, height: 400)
    private static let oversizedSize = CGSize(width: 1200, height: 1600)
    private static let oversizedPageNumber = 3
    private static let viewportWidth: CGFloat = 900
    private static let viewportHeight: CGFloat = 700

    /// Fit width targets the common page plus its scaled page-break margins.
    private static var expectedCommonPageWidth: CGFloat {
        viewportWidth * commonSize.width / (commonSize.width + 24)
    }

    @Test("fit width fits the common page size from every page")
    func fitWidthUsesTheRepresentativePageWidth() throws {
        try withMixedSizeSession { session, view, _ in
            let common = try #require(view.document?.page(at: 0))
            let oversized = try #require(view.document?.page(at: Self.oversizedPageNumber - 1))

            // Mounting already applies fit width.
            #expect(session.viewMode == .fitWidth)
            #expect(abs(view.displayedRect(of: common).width - Self.expectedCommonPageWidth) < 1)
            try expectCentred(view, pageIndex: 0)

            // PDFKit's own auto-scaling fits the oversized page instead.
            let widestPageFit = Self.viewportWidth / (Self.oversizedSize.width + 24)
            #expect(abs(view.scaleFactorForSizeToFit - widestPageFit) < 0.01)
            #expect(session.scaleFactor > Double(widestPageFit) * 3)

            let scaleFromCommonPage = session.scaleFactor
            #expect(session.goToPage(Self.oversizedPageNumber))
            session.fitWidth()
            #expect(abs(session.scaleFactor - scaleFromCommonPage) < 0.001)
            #expect(view.displayedRect(of: oversized).width > Self.viewportWidth)
        }
    }

    @Test("a uniform document keeps PDFKit auto-scaling")
    func uniformDocumentKeepsAutoScaling() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 3)
            let session = try PDFOpenService().open(url: url)
            defer { session.prepareForClose() }
            let window = mount(session)
            #expect(window.contentView === session.contentView)

            let view = try readerView(in: session.contentView)
            session.fitWidth()

            #expect(session.viewMode == .fitWidth)
            #expect(view.autoScales)
            #expect(abs(view.scaleFactor - view.scaleFactorForSizeToFit) < 0.01)
        }
    }

    @Test("resizing the viewport keeps fit width on the common page size")
    func resizingReappliesFitWidth() throws {
        try withMixedSizeSession { session, view, _ in
            let common = try #require(view.document?.page(at: 0))
            #expect(abs(view.displayedRect(of: common).width - Self.expectedCommonPageWidth) < 1)

            let widened: CGFloat = 1300
            session.contentView.frame = NSRect(x: 0, y: 0, width: widened, height: Self.viewportHeight)
            session.contentView.needsLayout = true
            session.contentView.layoutSubtreeIfNeeded()

            let expected = widened * Self.commonSize.width / (Self.commonSize.width + 24)
            #expect(abs(view.displayedRect(of: common).width - expected) < 1)
            #expect(session.viewMode == .fitWidth)
        }
    }

    @Test("page jumps centre a destination page that fits the viewport")
    func pageJumpsCentreAFittingPage() throws {
        try withMixedSizeSession { session, view, _ in
            try pushHorizontallyOffCentre(session, view)

            #expect(session.goToPage(1))
            try expectCentred(view, pageIndex: 0)

            #expect(session.goToLastPage())
            try expectCentred(view, pageIndex: 4)

            #expect(session.goToFirstPage())
            try expectCentred(view, pageIndex: 0)

            #expect(session.goToNextPage())
            try expectCentred(view, pageIndex: 1)
        }
    }

    @Test("link jumps centre a fitting page and still commit a verified landing")
    func linkJumpsCentreAndVerify() throws {
        try withMixedSizeSession { session, view, _ in
            try pushHorizontallyOffCentre(session, view)

            let target = try #require(view.document?.page(at: 3))
            let bounds = target.bounds(for: .mediaBox)
            session.activateLink(.goTo(pageIndex: 3, point: CGPoint(x: bounds.minX + 20, y: bounds.maxY - 40)))

            #expect(session.currentPageNumber == 4)
            try expectCentred(view, pageIndex: 3)
            #expect(session.canGoBack)
            #expect(session.isNavigationHistoryHealthy)
            #expect(session.goBack() == .verifiedLanding)
            #expect(session.currentPageNumber == Self.oversizedPageNumber)
        }
    }

    @Test("search centres the found page when it fits the viewport")
    func searchCentresTheFoundPage() throws {
        try withMixedSizeSession { session, view, _ in
            try pushHorizontallyOffCentre(session, view)

            session.beginSearch("unique-page-4")
            #expect(waitUntil { !session.searchSnapshot.isRunning && session.searchSnapshot.matchCount == 1 })

            #expect(session.currentPageNumber == 4)
            try expectCentred(view, pageIndex: 3)
        }
    }

    @Test("horizontal scrolling stays inside the current page")
    func horizontalScrollingStaysInsideThePage() throws {
        try withMixedSizeSession { session, view, _ in
            let clipView = try #require(descendantScrollViews(in: view).first).contentView

            // A page that already fits cannot be pushed into the empty canvas the
            // oversized page reserves.
            let restingX = clipView.bounds.origin.x
            session.moveHorizontally(byPoints: 240)
            #expect(abs(clipView.bounds.origin.x - restingX) < 0.001)
            session.moveHorizontally(byPoints: -240)
            #expect(abs(clipView.bounds.origin.x - restingX) < 0.001)
            try expectCentred(view, pageIndex: 0)

            // The oversized page is wider than the viewport, so it still pans.
            #expect(session.goToPage(Self.oversizedPageNumber))
            let oversizedRestingX = clipView.bounds.origin.x
            session.moveHorizontally(byPoints: 240)
            #expect(clipView.bounds.origin.x > oversizedRestingX)

            // Panning stops at the page edge instead of running into empty canvas.
            for _ in 0..<40 { session.moveHorizontally(byPoints: 240) }
            let oversized = try #require(view.document?.page(at: Self.oversizedPageNumber - 1))
            #expect(view.displayedRect(of: oversized).maxX >= view.bounds.width - 1)
        }
    }

    private func pushHorizontallyOffCentre(_ session: ReaderSession, _ view: ReaderPDFView) throws {
        #expect(session.goToPage(Self.oversizedPageNumber))
        session.moveHorizontally(byPoints: 200)
        let oversized = try #require(view.document?.page(at: Self.oversizedPageNumber - 1))
        #expect(abs(view.displayedRect(of: oversized).midX - view.bounds.midX) > 1)
    }

    private func expectCentred(
        _ view: ReaderPDFView,
        pageIndex: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        view.layoutDocumentView()
        let page = try #require(view.document?.page(at: pageIndex), sourceLocation: sourceLocation)
        let rect = view.displayedRect(of: page)
        #expect(rect.width <= view.bounds.width + 0.5, sourceLocation: sourceLocation)
        #expect(abs(rect.midX - view.bounds.midX) < 1, sourceLocation: sourceLocation)
    }

    private func withMixedSizeSession(
        _ body: (ReaderSession, ReaderPDFView, URL) throws -> Void
    ) throws {
        try withTemporaryDirectory { directory in
            var sizes = Array(repeating: Self.commonSize, count: 5)
            sizes[Self.oversizedPageNumber - 1] = Self.oversizedSize
            let url = try PDFFixtureFactory.makeMixedPageSizePDF(in: directory, pageSizes: sizes)
            let session = try PDFOpenService().open(url: url)
            defer { session.prepareForClose() }
            let window = mount(session)
            #expect(window.contentView === session.contentView)

            let view = try readerView(in: session.contentView)
            try body(session, view, url)
        }
    }

    private func mount(_ session: ReaderSession) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.viewportWidth, height: Self.viewportHeight),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = session.contentView
        session.contentView.frame = window.contentLayoutRect
        session.contentView.layoutSubtreeIfNeeded()
        return window
    }

    private func waitUntil(timeout: TimeInterval = 5, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonuniform-pages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func readerView(in view: NSView) throws -> ReaderPDFView {
        let views = descendantPDFViews(in: view)
        #expect(views.count == 1)
        return try #require(views.first as? ReaderPDFView)
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
