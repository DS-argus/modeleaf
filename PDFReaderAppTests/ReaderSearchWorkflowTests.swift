import AppKit
import PDFKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("Committed PDFKit search workflow")
@MainActor
struct ReaderSearchWorkflowTests {
    @Test("I-SEARCH-05 committed embedded-text search highlights all matches and one active match")
    func pdfKitSearchAndHighlighting() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(
                in: directory,
                name: "searchable.pdf",
                pageCount: 3,
                repeatedText: "needle needle"
            )
            let originalHash = try PDFFixtureFactory.sha256(of: url)
            let document = try #require(PDFDocument(url: url))
            let session = ReaderSession(sourceURL: url, document: document)
            _ = session.contentView
            let theme = AppKitTheme(themeID: .tokyoNight)
            session.applyTheme(theme)

            session.beginSearch("needle")
            #expect(waitUntil {
                !session.searchSnapshot.isRunning && session.searchSnapshot.matchCount == 6
            })

            let pdfView = try #require(descendantPDFView(in: session.contentView))
            let highlighted = try #require(pdfView.highlightedSelections)
            #expect(highlighted.count == 6)
            #expect(pdfView.currentSelection != nil)
            #expect(session.searchSnapshot.activeMatchNumber == 1)
            #expect(session.preferredInputContext == .searchResults)
            #expect(session.statusSnapshot.detail.contains("1 / 6"))

            #expect(session.selectNextSearchResult())
            #expect(session.searchSnapshot.activeMatchNumber == 2)
            #expect(session.selectPreviousSearchResult())
            #expect(session.searchSnapshot.activeMatchNumber == 1)
            #expect(session.selectPreviousSearchResult())
            #expect(session.searchSnapshot.activeMatchNumber == 6)

            session.clearSearch()
            #expect(session.searchSnapshot == .empty)
            #expect(session.preferredInputContext == .navigation)
            #expect(pdfView.highlightedSelections == nil)
            #expect(pdfView.currentSelection == nil)
            #expect(try PDFFixtureFactory.sha256(of: url) == originalHash)

            session.prepareForClose()
        }
    }

    @Test("I-SEARCH-06 a completed no-match search remains clearable and never invokes OCR")
    func noMatchSearch() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(
                in: directory,
                name: "no-match.pdf",
                pageCount: 2,
                repeatedText: "embedded text only"
            )
            let document = try #require(PDFDocument(url: url))
            let session = ReaderSession(sourceURL: url, document: document)
            _ = session.contentView

            session.beginSearch("definitely absent")
            #expect(waitUntil { !session.searchSnapshot.isRunning })
            #expect(session.searchSnapshot.matchCount == 0)
            #expect(session.searchSnapshot.query == "definitely absent")
            #expect(session.searchSnapshot.emptyResult == .noMatch)
            #expect(session.statusSnapshot.detail.contains("No matches"))
            #expect(session.preferredInputContext == .searchResults)

            session.clearSearch()
            #expect(session.preferredInputContext == .navigation)
            session.prepareForClose()
        }
    }

    @Test("I-SRCH-05 image-only and empty PDFs report no searchable text without OCR or source mutation")
    func imageOnlyAndEmptySearch() throws {
        try withTemporaryDirectory { directory in
            let urls = try [
                PDFFixtureFactory.makeImageOnlyPDF(in: directory),
                PDFFixtureFactory.makeEmptyPDF(in: directory),
            ]

            for url in urls {
                let originalHash = try PDFFixtureFactory.sha256(of: url)
                let document = try #require(PDFDocument(url: url))
                #expect(document.selectionForEntireDocument?.string?.isEmpty != false)
                let session = ReaderSession(sourceURL: url, document: document)
                _ = session.contentView

                session.beginSearch("needle")
                #expect(waitUntil { !session.searchSnapshot.isRunning })
                #expect(session.searchSnapshot.matchCount == 0)
                #expect(session.searchSnapshot.emptyResult == .noSearchableText)
                #expect(session.statusSnapshot.detail.contains("No searchable text"))
                #expect(try PDFFixtureFactory.sha256(of: url) == originalHash)

                session.prepareForClose()
                #expect(try PDFFixtureFactory.sha256(of: url) == originalHash)
            }
        }
    }

    @Test("I-SEARCH-07 two tabs search independently and clearing one preserves the other")
    func perTabSearchIsolation() throws {
        try withTemporaryDirectory { directory in
            let firstURL = try PDFFixtureFactory.makeTextPDF(
                in: directory,
                name: "alpha.pdf",
                pageCount: 2,
                repeatedText: "alpha alpha"
            )
            let secondURL = try PDFFixtureFactory.makeTextPDF(
                in: directory,
                name: "beta.pdf",
                pageCount: 3,
                repeatedText: "beta"
            )
            let first = ReaderSession(
                sourceURL: firstURL,
                document: try #require(PDFDocument(url: firstURL))
            )
            let second = ReaderSession(
                sourceURL: secondURL,
                document: try #require(PDFDocument(url: secondURL))
            )
            _ = first.contentView
            _ = second.contentView
            let store = ReaderSessionStore()
            #expect(store.insert(first))
            #expect(store.insert(second))

            first.beginSearch("alpha")
            second.beginSearch("beta")
            #expect(waitUntil {
                !first.searchSnapshot.isRunning && !second.searchSnapshot.isRunning
            })
            #expect(first.searchSnapshot.matchCount == 4)
            #expect(second.searchSnapshot.matchCount == 3)
            #expect(first.searchSnapshot.query == "alpha")
            #expect(second.searchSnapshot.query == "beta")

            second.clearSearch()
            #expect(second.searchSnapshot == .empty)
            #expect(first.searchSnapshot.matchCount == 4)
            #expect(first.preferredInputContext == .searchResults)
            #expect(second.preferredInputContext == .navigation)

            #expect(store.close(second.id))
            #expect(store.close(first.id))
        }
    }

    @Test("I-SEARCH-08 production PDFKit replacement starts only the latest committed query")
    func productionReplacementIsSerialized() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(
                in: directory,
                name: "replacement.pdf",
                pageCount: 20,
                repeatedText: "needle gamma"
            )
            let session = ReaderSession(
                sourceURL: url,
                document: try #require(PDFDocument(url: url))
            )
            _ = session.contentView

            session.beginSearch("needle")
            session.beginSearch("definitely absent")
            session.beginSearch("gamma")

            #expect(waitUntil(timeout: 8) {
                session.searchSnapshot.query == "gamma"
                    && !session.searchSnapshot.isRunning
                    && session.searchSnapshot.matchCount == 20
            })
            #expect(session.searchSnapshot.query == "gamma")
            #expect(session.searchSnapshot.matchCount == 20)

            session.prepareForClose()
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func descendantPDFView(in view: NSView) -> PDFView? {
        if let pdfView = view as? PDFView { return pdfView }
        return view.subviews.lazy.compactMap(descendantPDFView(in:)).first
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-reader-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}
