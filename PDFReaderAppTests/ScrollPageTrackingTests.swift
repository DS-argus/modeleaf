import AppKit
import PDFKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("Current page follows scrolling")
@MainActor
struct ScrollPageTrackingTests {
    @Test("scrolling down moves the reported page forward")
    func scrollingUpdatesTheReportedPage() throws {
        try withMountedSession(pageCount: 5) { session, _ in
            #expect(session.currentPageNumber == 1)

            let reached = scrollUntilPage(session, target: 3)
            #expect(reached)
            #expect(session.currentPageNumber == 3)
            #expect(session.statusSnapshot.page == "3 / 5")

            while session.currentPageNumber != 1, session.moveVerticallyReportingMovement(-32) {}
            #expect(session.currentPageNumber == 1)
        }
    }

    @Test("next and previous page continue from where scrolling left the reader")
    func pageCommandsContinueFromTheScrolledPage() throws {
        try withMountedSession(pageCount: 5) { session, _ in
            #expect(scrollUntilPage(session, target: 3))

            #expect(session.goToNextPage())
            #expect(session.currentPageNumber == 4)

            #expect(session.goToPreviousPage())
            #expect(session.currentPageNumber == 3)
        }
    }

    @Test("the page indicator agrees with the navigation anchor after scrolling")
    func indicatorAgreesWithNavigationAnchor() throws {
        try withMountedSession(pageCount: 5) { session, _ in
            #expect(scrollUntilPage(session, target: 2))

            let anchor = try #require(session.duplicationSnapshot?.navigation)
            #expect(anchor.pageIndex + 1 == session.currentPageNumber)
        }
    }

    @Test("fit page keeps stepping one page per movement")
    func fitPageMovementIsUnchanged() throws {
        try withMountedSession(pageCount: 5) { session, _ in
            session.fitPage()
            #expect(session.currentPageNumber == 1)

            session.moveVertically(byPoints: 48)
            #expect(session.currentPageNumber == 2)
            session.moveVertically(byViewportFraction: 0.8)
            #expect(session.currentPageNumber == 3)
            session.moveVertically(byPoints: -48)
            #expect(session.currentPageNumber == 2)
        }
    }

    @Test("a document that fits the viewport keeps reporting its only page")
    func shortDocumentKeepsItsPage() throws {
        try withMountedSession(pageCount: 1) { session, _ in
            #expect(session.currentPageNumber == 1)
            session.moveVertically(byPoints: 32)
            session.moveVertically(byViewportFraction: 0.8)
            #expect(session.currentPageNumber == 1)
            #expect(!session.goToNextPage())
            #expect(session.currentPageNumber == 1)
        }
    }

    /// Scrolls in the reader's own small steps until the target page is reached.
    private func scrollUntilPage(_ session: ReaderSession, target: Int, limit: Int = 400) -> Bool {
        for _ in 0..<limit {
            if session.currentPageNumber == target { return true }
            guard session.moveVerticallyReportingMovement(32) else { return false }
        }
        return session.currentPageNumber == target
    }

    private func withMountedSession(
        pageCount: Int,
        body: (ReaderSession, ReaderPDFView) throws -> Void
    ) throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: pageCount)
            let session = try PDFOpenService().open(url: url)
            defer { session.prepareForClose() }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = session.contentView
            session.contentView.frame = window.contentLayoutRect
            session.contentView.layoutSubtreeIfNeeded()
            #expect(window.contentView === session.contentView)

            let views = descendantPDFViews(in: session.contentView)
            #expect(views.count == 1)
            try body(session, try #require(views.first as? ReaderPDFView))
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scroll-page-tracking-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func descendantPDFViews(in view: NSView) -> [PDFView] {
        let own = (view as? PDFView).map { [$0] } ?? []
        return own + view.subviews.flatMap(descendantPDFViews(in:))
    }
}

private extension ReaderSession {
    /// Moves vertically and reports whether the viewport actually moved.
    func moveVerticallyReportingMovement(_ points: Double) -> Bool {
        let before = currentPageNumber
        let anchorBefore = duplicationSnapshot?.navigation
        moveVertically(byPoints: points)
        return currentPageNumber != before || duplicationSnapshot?.navigation != anchorBefore
    }
}
