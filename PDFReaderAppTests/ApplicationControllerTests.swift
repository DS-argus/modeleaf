import Foundation
import AppKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("App lifecycle bootstrap")
@MainActor
struct AppLifecycleTests {
    @Test("SwiftPM launch installs the delegate before entering the AppKit run loop")
    func swiftPackageLaunchInstallsDelegateBeforeRunLoop() {
        let application = AppRuntimeApplicationStub()
        let delegate = AppDelegate()

        AppDelegate.runApplication(application: application, delegate: delegate)

        #expect(application.delegate === delegate)
        #expect(application.requestedActivationPolicy == .regular)
        #expect(application.runCount == 1)
        #expect(application.delegateWasInstalledWhenRun)
        #expect(application.activationPolicyWhenRun == .regular)
    }
}

@MainActor
private final class AppRuntimeApplicationStub: AppRuntimeApplication {
    var delegate: (any NSApplicationDelegate)?
    private(set) var requestedActivationPolicy: NSApplication.ActivationPolicy?
    private(set) var runCount = 0
    private(set) var delegateWasInstalledWhenRun = false
    private(set) var activationPolicyWhenRun: NSApplication.ActivationPolicy?

    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool {
        requestedActivationPolicy = activationPolicy
        return true
    }

    func run() {
        runCount += 1
        delegateWasInstalledWhenRun = delegate != nil
        activationPolicyWhenRun = requestedActivationPolicy
    }
}

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

    @Test("pane-scoped deferred open rejects a disappeared target without inserting elsewhere")
    func deferredPaneOpenRejectsDisappearedTarget() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 1)
            let store = ReaderSessionStore()
            #expect(store.insert(try PDFOpenService().open(url: url)))
            let metrics = ControllerRecordingMetrics()
            let openPanel = CapturingOpenPanelStub()
            let controller = ApplicationController(
                configService: ConfigService(source: ConfigFileSource(url: directory.appendingPathComponent("missing-config.toml"))),
                sessionStore: store,
                openMetrics: metrics,
                openPanelPresenter: openPanel,
                terminationHandler: {}
            )
            defer {
                while store.closeActive() {}
                controller.mainWindowController.close()
            }

            controller.dispatch(.paneSplitRight)
            let targetPane = try #require(descendantPaneViews(in: controller.mainWindowController.rootView).last)
            targetPane.tabBar.onNewTab?()
            #expect(openPanel.presentCount == 1)
            #expect(openPanel.capturedCompletion != nil)

            controller.dispatch(.paneFocusLeft)
            controller.dispatch(.paneUnsplit)
            #expect(store.sessionCount == 1)

            openPanel.complete(with: url)

            #expect(store.sessionCount == 1)
            #expect(controller.mainWindowController.rootView.statusBar.presentation.tone == .error)
            #expect(controller.mainWindowController.rootView.statusBar.presentation.detail.contains("Could not create a PDF tab"))
            #expect(metrics.events.suffix(3).map(\.signature) == [
                "session.closed.point.insertionRejected",
                "open.failed.point.insertionRejected",
                "open.total.end.insertionRejected",
            ])
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-reader-controller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func descendantPaneViews(in view: NSView) -> [PaneView] {
        let own = (view as? PaneView).map { [$0] } ?? []
        return own + view.subviews.flatMap(descendantPaneViews(in:))
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

@MainActor
private final class CapturingOpenPanelStub: PDFOpenPanelPresenting {
    private(set) var presentCount = 0
    private(set) var capturedCompletion: ((URL?) -> Void)?

    func present(attachedTo window: NSWindow?, completion: @escaping (URL?) -> Void) {
        presentCount += 1
        capturedCompletion = completion
    }

    func complete(with url: URL?) {
        let completion = capturedCompletion
        capturedCompletion = nil
        completion?(url)
    }
}

@MainActor
private final class ControllerRecordingMetrics: PDFOpenMetrics {
    private(set) var events: [PDFOpenMetricEvent] = []

    func record(_ event: PDFOpenMetricEvent) {
        events.append(event)
    }
}

private extension PDFOpenMetricEvent {
    var signature: String {
        "\(name.rawValue).\(boundary.rawValue).\(outcome?.rawValue ?? "-")"
    }
}
