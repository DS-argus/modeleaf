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
    private func mountedLinkSession(in directory: URL) throws -> (ReaderSession, ReaderLinkProviding) {
        let url = try PDFFixtureFactory.makeLinkedPDF(in: directory)
        let session = try PDFOpenService().open(url: url)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 1000),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = session.contentView
        _ = session.currentPageNumber // force the view/document to load
        window.contentView?.layoutSubtreeIfNeeded()
        let provider = try #require(session as? ReaderLinkProviding)
        return (session, provider)
    }

    @Test("visible-page links enumerate with correct kinds, including wrapped links")
    func enumerate() throws {
        try withTemporaryDirectory { directory in
            let (session, provider) = try mountedLinkSession(in: directory)
            defer { session.prepareForClose() }

            let targets = provider.linkTargets(in: session.contentView)
            #expect(targets.count == 4) // goto + external + wrapA + wrapB (wrapped = two annotations)

            let destinations = targets.filter { if case .destination = $0.kind { return true }; return false }
            let urls = targets.compactMap { target -> URL? in
                if case let .url(url) = target.kind { return url }
                return nil
            }
            #expect(destinations.count == 1)
            #expect(urls.count == 3)
            #expect(urls.filter { $0.absoluteString == "https://example.invalid/wrapped" }.count == 2)
            #expect(targets.allSatisfy { $0.rect.width > 0 && $0.rect.height > 0 })
        }
    }

    @Test("a destination navigates in-document; a URL is returned to the shell")
    func activate() throws {
        try withTemporaryDirectory { directory in
            let (session, provider) = try mountedLinkSession(in: directory)
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
}
