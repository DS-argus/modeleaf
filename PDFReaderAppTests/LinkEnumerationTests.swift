import AppKit
import PDFKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("Link enumeration and activation")
@MainActor
struct LinkEnumerationTests {
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("modeleaf-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func mount(_ url: URL) throws -> (ReaderSession, ReaderLinkProviding) {
        let session = try PDFOpenService().open(url: url)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 1000),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = session.contentView
        _ = session.currentPageNumber
        window.contentView?.layoutSubtreeIfNeeded()
        let provider = try #require(session as? ReaderLinkProviding)
        return (session, provider)
    }

    @Test("annotation links group by target; a wrapped link is one hint with several outlines")
    func annotationGrouping() throws {
        try withTemporaryDirectory { directory in
            let (session, provider) = try mount(try PDFFixtureFactory.makeLinkedPDF(in: directory))
            defer { session.prepareForClose() }

            let targets = provider.linkTargets(in: session.contentView)
            #expect(targets.count == 3) // goto + external + wrapped (two annotations grouped)
            #expect(targets.filter { if case .destination = $0.kind { return true }; return false }.count == 1)
            let wrapped = try #require(targets.first {
                if case let .url(url) = $0.kind { return url.absoluteString.contains("wrapped") }
                return false
            })
            #expect(wrapped.rects.count == 2)
            #expect(targets.allSatisfy { !$0.rects.isEmpty && $0.rects.allSatisfy { $0.width > 0 && $0.height > 0 } })
        }
    }

    @Test("a destination navigates in-document; a URL is returned to the shell")
    func activate() throws {
        try withTemporaryDirectory { directory in
            let (session, provider) = try mount(try PDFFixtureFactory.makeLinkedPDF(in: directory))
            defer { session.prepareForClose() }

            let targets = provider.linkTargets(in: session.contentView)
            let destination = try #require(targets.first { if case .destination = $0.kind { return true }; return false })
            #expect(provider.activateLink(destination) == .navigatedInDocument)
            #expect(session.currentPageNumber == 2)

            let urlTarget = try #require(targets.first { if case .url = $0.kind { return true }; return false })
            guard case let .url(url) = urlTarget.kind else { return }
            #expect(provider.activateLink(urlTarget) == .openExternal(url))
        }
    }

    @Test("plain-text URLs are detected, and a URL wrapped after '_' is rejoined")
    func textURLs() throws {
        try withTemporaryDirectory { directory in
            let (session, provider) = try mount(try PDFFixtureFactory.makeTextURLPDF(in: directory))
            defer { session.prepareForClose() }

            let targets = provider.linkTargets(in: session.contentView)
            let urls = targets.compactMap { target -> String? in
                if case let .url(url) = target.kind { return url.absoluteString }
                return nil
            }
            #expect(urls.contains("https://example.com/single"))
            let wrapped = try #require(targets.first {
                if case let .url(url) = $0.kind { return url.absoluteString == "https://example.com/very_long_path_continues" }
                return false
            })
            #expect(wrapped.rects.count == 2) // spans two visual lines
        }
    }
}
