import AppKit
import PDFKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("TOC numeric routing integration")
@MainActor
struct TOCNumericRoutingTests {
    @Test("window routes a TOC selector before the normal input engine")
    func numericSelectorRoutesThroughWindow() async throws {
        let document = PDFDocument()
        for _ in 0..<3 { document.insert(PDFPage(), at: document.pageCount) }
        let root = PDFOutline()
        for index in 0..<3 {
            let item = PDFOutline()
            item.label = "Section \(index + 1)"
            let page = try #require(document.page(at: index))
            let y = index == 1 ? page.bounds(for: .mediaBox).maxY + 2.7 : 700
            item.destination = PDFDestination(page: page, at: CGPoint(x: 20, y: y))
            root.insertChild(item, at: index)
        }
        document.outlineRoot = root

        let session = ReaderSession(sourceURL: URL(fileURLWithPath: "/tmp/toc-numeric-routing.pdf"), document: document)
        let store = ReaderSessionStore()
        let coordinator = PaneCoordinator(initialStore: store)
        let config = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        let controller = MainWindowController(
            coordinator: coordinator,
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { _ in },
            keyDispatchHandler: { _ in },
            validatedConfig: config
        )
        #expect(store.insert(session))
        defer { controller.close() }

        controller.toggleTOCDrawer()
        #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "2"))))
        try await Task.sleep(for: .milliseconds(450))
        #expect(session.currentPageNumber == 2)

        #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "3"))))
        controller.presentPrompt(PromptPresentation(kind: .page, text: "", validationMessage: nil))
        try await Task.sleep(for: .milliseconds(450))
        #expect(session.currentPageNumber == 2)
        controller.dismissPromptAndRestoreFocus()

        #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "3"))))
        controller.presentHelp()
        try await Task.sleep(for: .milliseconds(450))
        #expect(session.currentPageNumber == 2)
        _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "", keyCode: 53)))

        #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "3"))))
        controller.applyConfig(config)
        try await Task.sleep(for: .milliseconds(450))
        #expect(session.currentPageNumber == 2)

        #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "3"))))
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        try await Task.sleep(for: .milliseconds(450))
        #expect(session.currentPageNumber == 2)
    }

    @Test("real Inference selector two reaches promoted Chapter 0")
    func realInferencePromotedSelectorTwo() async throws {
        guard let path = ProcessInfo.processInfo.environment["MODELEAF_INFERENCE_PDF"] else { return }
        let document = try #require(PDFDocument(url: URL(fileURLWithPath: path)))
        let session = ReaderSession(sourceURL: URL(fileURLWithPath: path), document: document)
        let store = ReaderSessionStore()
        let coordinator = PaneCoordinator(initialStore: store)
        let config = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        let controller = MainWindowController(coordinator: coordinator, theme: AppKitTheme(themeID: .tokyoNight), actionHandler: { _ in }, keyDispatchHandler: { _ in }, validatedConfig: config)
        #expect(store.insert(session))
        defer { controller.close() }
        controller.toggleTOCDrawer()
        #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "2"))))
        try await Task.sleep(for: .milliseconds(450))
        #expect(session.currentPageNumber == 17)
    }
}
