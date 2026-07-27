import AppKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("Link hint overlay integration")
@MainActor
struct LinkHintIntegrationTests {
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("modeleaf-link-hint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func mountedController(in directory: URL) throws -> (MainWindowController, ReaderSession) {
        let url = try PDFFixtureFactory.makeLinkedPDF(in: directory)
        let session = try PDFOpenService().open(url: url)
        let store = ReaderSessionStore()
        #expect(store.insert(session))
        let controller = MainWindowController(
            coordinator: PaneCoordinator(initialStore: store),
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { _ in }
        )
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 1100), display: false)
        controller.rootView.layoutSubtreeIfNeeded()
        _ = session.currentPageNumber
        return (controller, session)
    }

    @Test("f shows hints, a label navigates a destination, non-label keys are inert")
    func hintModeFlow() throws {
        try withTemporaryDirectory { directory in
            let (controller, session) = try mountedController(in: directory)
            defer { controller.close() }
            let overlay = controller.rootView.linkHintOverlay

            controller.presentLinkHints()
            #expect(overlay.isPresenting)
            #expect(overlay.visibleLabels.count == 3) // goto + external + wrapped(grouped)

            // Modal: a key that is not a hint label does nothing and keeps hints up.
            _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "z")))
            #expect(overlay.isPresenting)
            #expect(session.currentPageNumber == 1)

            // Type the destination link's label -> in-document jump to page 2.
            let provider = try #require(session as? ReaderLinkProviding)
            let targets = provider.linkTargets(in: overlay)
            let labels = LinkHintLabels.generate(count: targets.count)
            let destIndex = try #require(targets.firstIndex {
                if case .destination = $0.kind { return true }
                return false
            })
            for character in labels[destIndex] {
                _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: String(character))))
            }
            #expect(overlay.isHidden)
            #expect(session.currentPageNumber == 2)
        }
    }

    @Test("escape cancels hint mode without navigating")
    func escapeCancels() throws {
        try withTemporaryDirectory { directory in
            let (controller, session) = try mountedController(in: directory)
            defer { controller.close() }
            let overlay = controller.rootView.linkHintOverlay

            controller.presentLinkHints()
            #expect(overlay.isPresenting)
            _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "", keyCode: 53)))
            #expect(overlay.isHidden)
            #expect(session.currentPageNumber == 1)
        }
    }
}
