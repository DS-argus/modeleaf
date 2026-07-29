import AppKit
import PDFKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
import UniformTypeIdentifiers
@testable import PDFReaderApp

@Suite("Read-only PDF opening and external URL routing")
@MainActor
struct PDFOpenServiceTests {
    @Test("I-PDF-01 valid PDF creates one usable session with expected page count")
    func validPDFCreatesSession() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 3)
            let session = try PDFOpenService().open(url: url)

            #expect(session.title == "text-3-page.pdf")
            #expect(session.sourceURL == url.standardizedFileURL)
            #expect(session.pageCount == 3)
            #expect(session.currentPageNumber == 1)
            #expect(descendantPDFViews(in: session.contentView).count == 1)

            session.prepareForClose()
        }
    }

    @Test("I-PDF-02 missing, malformed, locked, and remote URLs map to stable errors")
    func invalidInputsMapToStableErrors() throws {
        try withTemporaryDirectory { directory in
            let service = PDFOpenService()
            let missing = directory.appendingPathComponent("missing.pdf")
            let malformed = try PDFFixtureFactory.makeMalformedPDF(in: directory)
            let locked = try PDFFixtureFactory.makeLockedPDF(in: directory)

            #expect(throws: PDFOpenError.missingFile(missing.path)) {
                try service.open(url: missing)
            }
            #expect(throws: PDFOpenError.malformedDocument(malformed.path)) {
                try service.open(url: malformed)
            }
            #expect(PDFDocument(url: locked)?.isLocked == true)
            #expect(throws: PDFOpenError.lockedDocument(locked.path)) {
                try service.open(url: locked)
            }
            #expect(throws: PDFOpenError.unsupportedLocation("https://example.invalid/file.pdf")) {
                try service.open(url: URL(string: "https://example.invalid/file.pdf")!)
            }

            #expect(PDFOpenError.lockedDocument(locked.path).presentation.contains("Password-protected"))
            #expect(!PDFOpenError.malformedDocument(malformed.path).presentation.isEmpty)
        }
    }

    @Test("native open panel is single-file, directory-free, and UTType.pdf filtered")
    func openPanelConfiguration() {
        let panel = NativePDFOpenPanelPresenter().makePanel()

        #expect(panel.allowedContentTypes == [.pdf])
        #expect(!panel.allowsMultipleSelection)
        #expect(!panel.canChooseDirectories)
        #expect(panel.canChooseFiles)
        #expect(panel.resolvesAliases)
    }

    @Test("picker and Finder/Open-With URLs converge on the same service and tab store")
    func pickerAndExternalURLsConverge() throws {
        try withTemporaryDirectory { directory in
            let pickerURL = try PDFFixtureFactory.makeTextPDF(in: directory, name: "picker.pdf", pageCount: 1)
            let externalURL = try PDFFixtureFactory.makeTextPDF(in: directory, name: "external.pdf", pageCount: 2)
            let store = ReaderSessionStore()
            let picker = ImmediatePDFOpenPanel(url: pickerURL)
            let missingConfig = directory.appendingPathComponent("missing-config.toml")
            let controller = ApplicationController(
                configService: ConfigService(source: ConfigFileSource(url: missingConfig)),
                sessionStore: store,
                openPanelPresenter: picker,
                themeStore: ThemeSelectionStore(fileURL: directory.appendingPathComponent("theme-state.json")),
                recentFilesStore: RecentFilesStore(fileURL: directory.appendingPathComponent("recent-state.json")),
                terminationHandler: {}
            )

            _ = controller.mainWindowController // window exists before dispatch (mirrors start())
            controller.dispatch(.documentOpen) // ⌘O now opens the unified overlay
            #expect(!controller.mainWindowController.rootView.recentFilesOverlay.isHidden)
            // Empty-query Enter commits the fixed Browse row -> native panel (stubbed).
            _ = controller.mainWindowController.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36)))
            #expect(store.sessionCount == 1)
            #expect(store.activeSession?.title == "picker.pdf")

            controller.openExternalDocuments([externalURL])
            #expect(store.sessionCount == 2)
            #expect(store.activeSession?.title == "external.pdf")

            while controller.coordinator.closeActiveTab() {}
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-reader-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func descendantPDFViews(in view: NSView) -> [PDFView] {
        let own = (view as? PDFView).map { [$0] } ?? []
        return own + view.subviews.flatMap(descendantPDFViews(in:))
    }
}

@MainActor
private final class ImmediatePDFOpenPanel: PDFOpenPanelPresenting {
    let url: URL?

    init(url: URL?) {
        self.url = url
    }

    func present(attachedTo window: NSWindow?, completion: @escaping (URL?) -> Void) {
        completion(url)
    }
}
