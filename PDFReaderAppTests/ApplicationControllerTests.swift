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
            themeStore: ThemeSelectionStore(fileURL: tempConfig.appendingPathExtension("theme-state")),
            recentFilesStore: RecentFilesStore(fileURL: tempConfig.appendingPathExtension("recent-state")),
            terminationHandler: { quit = true }
        )

        _ = controller.mainWindowController // start() creates the window before any dispatch in production
        controller.dispatch(.documentOpen)
        #expect(!controller.mainWindowController.rootView.recentFilesOverlay.isHidden)
        #expect(openPanel.presentCount == 0)
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

    @Test("successful opens record the absolute path for the recent-files overlay")
    func successfulOpenRecordsRecentFile() throws {
        try withTemporaryDirectory { directory in
            let document = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 1)
            let recentStore = RecentFilesStore(fileURL: directory.appendingPathComponent("state.json"))
            let controller = ApplicationController(
                configService: ConfigService(source: ConfigFileSource(url: directory.appendingPathComponent("missing-config.toml"))),
                themeStore: ThemeSelectionStore(fileURL: directory.appendingPathComponent("theme-state.json")),
                recentFilesStore: recentStore,
                terminationHandler: {}
            )
            defer { controller.mainWindowController.close() }

            #expect(controller.openDocument(at: document))
            #expect(recentStore.load().map(\.absolutePath) == [document.path])
        }
    }
    @Test("injected recent-files storage records opens without modifying the default state file")
    func injectedRecentFilesStoreIsolatedFromDefaultState() throws {
        try withTemporaryDirectory { directory in
            let document = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 1)
            let recentURL = directory.appendingPathComponent("recent-state.json")
            let defaultURL = ThemeSelectionStore.defaultFileURL
            let defaultData = try? Data(contentsOf: defaultURL)
            let defaultModificationDate = try? FileManager.default.attributesOfItem(atPath: defaultURL.path)[.modificationDate] as? Date

            let controller = ApplicationController(
                configService: ConfigService(source: ConfigFileSource(url: directory.appendingPathComponent("missing-config.toml"))),
                themeStore: ThemeSelectionStore(fileURL: directory.appendingPathComponent("theme-state.json")),
                recentFilesStore: RecentFilesStore(fileURL: recentURL),
                terminationHandler: {}
            )
            defer {
                while controller.coordinator.closeActiveTab() {}
                controller.mainWindowController.close()
            }

            #expect(controller.openDocument(at: document))
            #expect(RecentFilesStore(fileURL: recentURL).load().map(\.absolutePath) == [document.path])
            #expect((try? Data(contentsOf: defaultURL)) == defaultData)
            #expect((try? FileManager.default.attributesOfItem(atPath: defaultURL.path)[.modificationDate] as? Date) == defaultModificationDate)
        }
    }
    @Test("successful opens surface recent-files persistence failures without rejecting the PDF")
    func successfulOpenSurfacesRecentPersistenceFailure() throws {
        try withTemporaryDirectory { directory in
            let document = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 1)
            let stateURL = directory.appendingPathComponent("state.json")
            try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
            let controller = ApplicationController(
                configService: ConfigService(source: ConfigFileSource(url: directory.appendingPathComponent("missing-config.toml"))),
                themeStore: ThemeSelectionStore(fileURL: directory.appendingPathComponent("theme-state.json")),
                recentFilesStore: RecentFilesStore(fileURL: stateURL),
                terminationHandler: {}
            )
            defer { controller.mainWindowController.close() }
            #expect(controller.openDocument(at: document))
            #expect(controller.mainWindowController.rootView.statusBar.presentation.detail.contains("recent-files list could not be saved"))
        }
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
                themeStore: ThemeSelectionStore(fileURL: directory.appendingPathComponent("theme-state.json")),
                recentFilesStore: RecentFilesStore(fileURL: directory.appendingPathComponent("recent-state.json")),
                terminationHandler: {}
            )
            defer {
                while controller.coordinator.closeActiveTab() {}
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


    @Test("pane-scoped deferred open rejects removed four-pane targets across collapse and unsplit")
    func deferredPaneOpenRejectsRemovedFourPaneTargets() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 1)
            for removal in [DeferredPaneRemoval.bandMemberCollapse, .globalUnsplit] {
                let store = ReaderSessionStore()
                #expect(store.insert(try PDFOpenService().open(url: url)))
                let metrics = ControllerRecordingMetrics()
                let openPanel = CapturingOpenPanelStub()
                let controller = ApplicationController(
                    configService: ConfigService(source: ConfigFileSource(url: directory.appendingPathComponent("missing-config.toml"))),
                    sessionStore: store,
                    openMetrics: metrics,
                    openPanelPresenter: openPanel,
                    themeStore: ThemeSelectionStore(fileURL: directory.appendingPathComponent("theme-state.json")),
                    recentFilesStore: RecentFilesStore(fileURL: directory.appendingPathComponent("recent-state.json")),
                    terminationHandler: {}
                )
                defer {
                    while controller.coordinator.closeActiveTab() {}
                    controller.mainWindowController.close()
                }

                controller.dispatch(.paneSplitRight)
                let trailingTop = try #require(controller.coordinator.activePaneID)
                controller.dispatch(.paneFocusLeft)
                _ = try #require(controller.coordinator.activePaneID)
                controller.dispatch(.paneSplitDown)
                controller.dispatch(.paneFocusRight)
                #expect(controller.coordinator.activePaneID == trailingTop)
                controller.dispatch(.paneSplitDown)
                let target = try #require(controller.coordinator.activePaneID)
                #expect(controller.coordinator.snapshot.layout.paneIDs.count == 4)
                let targetView = try #require(descendantPaneViews(in: controller.mainWindowController.rootView).first { $0.id == target })

                metrics.reset()
                targetView.tabBar.onNewTab?()
                #expect(openPanel.presentCount == 1)
                #expect(openPanel.capturedCompletion != nil)

                switch removal {
                case .bandMemberCollapse:
                    #expect(controller.coordinator.closeActiveTab())
                    #expect(controller.coordinator.snapshot.layout.paneIDs.count == 3)
                case .globalUnsplit:
                    #expect(controller.coordinator.focus(.up))
                    #expect(controller.coordinator.activePaneID != target)
                    #expect(controller.coordinator.unsplit())
                    #expect(controller.coordinator.snapshot.layout.paneIDs.count == 1)
                }
                #expect(!controller.coordinator.snapshot.layout.contains(target))
                controller.coordinator.snapshot.assertCardinality()

                openPanel.complete(with: url)

                #expect(!controller.coordinator.snapshot.layout.contains(target))
                #expect(controller.coordinator.snapshot.panes.values.allSatisfy { $0.tabs.count == 1 })
                #expect(controller.mainWindowController.rootView.statusBar.presentation.tone == .error)
                #expect(metrics.events.suffix(3).map(\.signature) == [
                    "session.closed.point.insertionRejected",
                    "open.failed.point.insertionRejected",
                    "open.total.end.insertionRejected",
                ])
                controller.coordinator.snapshot.assertCardinality()
            }
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
            configService: ConfigService(source: ConfigFileSource(url: configURL)),
            themeStore: ThemeSelectionStore(fileURL: temporary.appendingPathComponent("theme-state.json")),
            recentFilesStore: RecentFilesStore(fileURL: temporary.appendingPathComponent("recent-state.json"))
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
        #expect(details.contains("[reservedAction]"))
        #expect(details.contains("actions: prompt.commit"))
        #expect(details.contains("actions: prompt.cancel"))
        #expect(details.contains(configURL.path))
        #expect(
            (controller.mainWindowController.rootView.statusBar.accessibilityValue() as? String)?
                .contains("reservedAction") == true
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
            configService: ConfigService(source: ConfigFileSource(url: configURL)),
            themeStore: ThemeSelectionStore(fileURL: temporary.appendingPathComponent("theme-state.json")),
            recentFilesStore: RecentFilesStore(fileURL: temporary.appendingPathComponent("recent-state.json"))
        )
        controller.start()
        defer { controller.mainWindowController.close() }

        #expect(controller.configResult.origin == .userFile)
        #expect(!controller.configResult.usedFallback)
        let status = controller.mainWindowController.rootView.statusBar.presentation
        #expect(status.tone == .normal)
        #expect(status.detail == "Configuration: 2 warnings")
        #expect(status.expandedDetail?.contains("reservedAction") == true)
    }

    @Test("controller split duplicates the source page fit-to-page and completes one post-commit open trace")
    func controllerSplitDuplicatesMountedPresentationAndCompletesMetricsOnce() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 3)
            let store = ReaderSessionStore()
            let metrics = ControllerRecordingMetrics()
            let controller = ApplicationController(
                configService: ConfigService(source: ConfigFileSource(url: directory.appendingPathComponent("missing-config.toml"))),
                sessionStore: store,
                openMetrics: metrics,
                themeStore: ThemeSelectionStore(fileURL: directory.appendingPathComponent("theme-state.json")),
                recentFilesStore: RecentFilesStore(fileURL: directory.appendingPathComponent("recent-state.json")),
                terminationHandler: {}
            )
            defer {
                while controller.coordinator.closeActiveTab() {}
                controller.mainWindowController.close()
            }


            _ = controller.mainWindowController
            #expect(controller.openDocument(at: url))
            metrics.reset()
            let source = try #require(store.activeSession as? ReaderSession)
            #expect(source.goToPage(2))
            source.zoom(by: 1.25)
            #expect(source.viewMode == .manual)
            controller.dispatch(.paneSplitRight)
            _ = controller.mainWindowController

            guard case let .split(_, _, .one(destination)) = controller.coordinator.snapshot.layout else {
                Issue.record("Expected a committed split")
                return
            }
            let duplicate = try #require(controller.coordinator.store(for: destination)?.activeSession as? ReaderSession)
            // Duplicate keeps the source's reading position but opens
            // fit-to-page in its own pane (not the source's manual zoom).
            #expect(duplicate.currentPageNumber == source.currentPageNumber)
            #expect(duplicate.viewMode == .fitPage)
            #expect(duplicate.contentView.window === controller.mainWindowController.window)
            #expect(metrics.events.filter { $0.name == .openReady && $0.outcome == .success }.count == 1)
            #expect(metrics.events.filter { $0.name == .openTotal && $0.boundary == .end && $0.outcome == .success }.count == 1)
        }
    }

    @Test("controller split reopen failure preserves source topology and balances the failed trace")
    func controllerSplitReopenFailurePreservesSourceTopology() throws {
        try withTemporaryDirectory { directory in
            let metrics = ControllerRecordingMetrics()
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 1)
            let store = ReaderSessionStore()
            let controller = ApplicationController(
                configService: ConfigService(source: ConfigFileSource(url: directory.appendingPathComponent("missing-config.toml"))),
                sessionStore: store,
                openMetrics: metrics,
                themeStore: ThemeSelectionStore(fileURL: directory.appendingPathComponent("theme-state.json")),
                recentFilesStore: RecentFilesStore(fileURL: directory.appendingPathComponent("recent-state.json")),
                terminationHandler: {}
            )
            defer {
                while controller.coordinator.closeActiveTab() {}
                controller.mainWindowController.close()
            }
            _ = controller.mainWindowController
            #expect(controller.openDocument(at: url))
            metrics.reset()
            let source = try #require(store.activeSession as? ReaderSession)
            try FileManager.default.removeItem(at: url)

            controller.dispatch(.paneSplitRight)
            #expect(controller.coordinator.snapshot.layout == .single(try #require(controller.coordinator.activePaneID)))
            #expect(store.sessionCount == 1)
            #expect(store.activeSession?.id == source.id)
            #expect(controller.mainWindowController.rootView.statusBar.presentation.tone == .error)
            #expect(controller.mainWindowController.rootView.statusBar.presentation.detail.contains("PDF file not found"))
            #expect(metrics.events.suffix(4).map(\.signature) == [
                "filePreflight.begin.-",
                "filePreflight.end.missingFile",
                "open.failed.point.missingFile",
                "open.total.end.missingFile",
            ])
        }
    }

    private func fixedID(_ value: Int) -> TabID {
        TabID(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!)
    }
}
private enum DeferredPaneRemoval {
    case bandMemberCollapse
    case globalUnsplit
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
    func applyTheme(_ theme: AppKitTheme) {}
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

    func reset() { events.removeAll() }
}

private extension PDFOpenMetricEvent {
    var signature: String {
        "\(name.rawValue).\(boundary.rawValue).\(outcome?.rawValue ?? "-")"
    }
}
