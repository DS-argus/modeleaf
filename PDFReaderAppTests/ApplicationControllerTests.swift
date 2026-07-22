import Foundation
import AppKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("ApplicationController shell dispatch")
@MainActor
struct ApplicationControllerTests {
    @Test("dispatch covers open, close, tab movement, and quit without owning PDF state")
    func dispatchCoversShellActions() {
        let tempConfig = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let sessionStore = ReaderSessionStore()
        let first = ControllerStubSession(id: fixedID(1), title: "alpha.pdf")
        let second = ControllerStubSession(id: fixedID(2), title: "beta.pdf")
        _ = sessionStore.insert(first)
        _ = sessionStore.insert(second)
        let openPanel = ControllerOpenPanelStub()
        var quit = false
        let controller = ApplicationController(
            configService: ConfigService(source: ConfigFileSource(url: tempConfig)),
            sessionStore: sessionStore,
            openPanelPresenter: openPanel,
            terminationHandler: { quit = true }
        )

        controller.dispatch(.documentOpen)
        #expect(openPanel.presentCount == 1)
        controller.dispatch(.tabPrevious)
        #expect(sessionStore.activeSession?.id == first.id)
        controller.dispatch(.tabNext)
        #expect(sessionStore.activeSession?.id == second.id)
        controller.dispatch(.documentClose)
        #expect(second.prepareForCloseCount == 1)
        #expect(sessionStore.activeSession?.id == first.id)
        controller.dispatch(.appQuit)
        #expect(quit)
    }

    @Test("startup presents every configuration error and warning with actionable metadata")
    func startupPresentsAggregateConfigurationDiagnostics() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-reader-app-controller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let configURL = temporary.appendingPathComponent("config.toml")
        try Data(
            """
            [navigation]
            zoom_factor = 9

            [keymap]
            "prompt.commit" = []
            "prompt.cancel" = []
            "bookmark.toggle" = ["b"]
            """.utf8
        ).write(to: configURL)

        let controller = ApplicationController(
            configService: ConfigService(source: ConfigFileSource(url: configURL))
        )
        controller.start()
        defer { controller.mainWindowController.close() }

        let status = controller.mainWindowController.rootView.statusBar.presentation
        #expect(status.tone == .error)
        #expect(status.detail.contains("error"))
        #expect(status.detail.contains("warning"))
        #expect(status.detail.contains("built-in defaults active"))
        let details = try #require(status.expandedDetail)
        #expect(details.contains("[valueOutOfRange]"))
        #expect(details.contains("navigation.zoom_factor"))
        #expect(details.contains("[unknownAction]"))
        #expect(details.contains("bookmark.toggle"))
        #expect(details.contains("[promptLifecycleUnbound]"))
        #expect(details.contains("actions: prompt.commit, prompt.cancel"))
        #expect(details.contains("contexts: pagePrompt, searchPrompt"))
        #expect(details.contains(configURL.path))
        #expect(
            (controller.mainWindowController.rootView.statusBar.accessibilityValue() as? String)?
                .contains("promptLifecycleUnbound") == true
        )
    }

    @Test("warning-only configuration is visible without forcing fallback")
    func warningOnlyConfigurationIsVisible() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-reader-app-warning-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let configURL = temporary.appendingPathComponent("config.toml")
        try Data(
            """
            [keymap]
            "prompt.commit" = []
            "prompt.cancel" = []
            """.utf8
        ).write(to: configURL)

        let controller = ApplicationController(
            configService: ConfigService(source: ConfigFileSource(url: configURL))
        )
        controller.start()
        defer { controller.mainWindowController.close() }

        #expect(controller.configResult.origin == .userFile)
        #expect(!controller.configResult.usedFallback)
        let status = controller.mainWindowController.rootView.statusBar.presentation
        #expect(status.tone == .normal)
        #expect(status.detail == "Configuration: 1 warning")
        #expect(status.expandedDetail?.contains("promptLifecycleUnbound") == true)
    }

    private func fixedID(_ value: Int) -> TabID {
        TabID(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!)
    }
}

@MainActor
private final class ControllerOpenPanelStub: PDFOpenPanelPresenting {
    private(set) var presentCount = 0

    func present(attachedTo window: NSWindow?, completion: @escaping (URL?) -> Void) {
        presentCount += 1
        completion(nil)
    }
}

@MainActor
private final class ControllerStubSession: ReaderSessionPresenting {
    let id: TabID
    let title: String
    let contentView: NSView = NSView()
    private(set) var prepareForCloseCount = 0

    init(id: TabID, title: String) {
        self.id = id
        self.title = title
    }

    var statusSnapshot: ReaderStatusSnapshot {
        ReaderStatusSnapshot(context: "NORMAL", page: "1 / 1", zoom: "100%", detail: title)
    }

    func prepareForClose() {
        prepareForCloseCount += 1
    }
}
