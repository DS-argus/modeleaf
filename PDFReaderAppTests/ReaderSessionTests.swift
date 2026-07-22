import AppKit
import PDFKit
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("Read-only PDF session lifecycle")
@MainActor
struct ReaderSessionTests {
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
            session.scrollBy(xPoints: 0, yPoints: 48)
            let afterPointScroll = scrollView.contentView.bounds.origin
            session.scrollVerticallyByViewportFraction(0.8)
            let afterViewportScroll = scrollView.contentView.bounds.origin

            #expect(afterPointScroll != initial)
            #expect(afterViewportScroll != afterPointScroll)
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

    private func withSession(pageCount: Int, body: (ReaderSession, URL) throws -> Void) throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: pageCount)
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
