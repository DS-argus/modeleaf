import AppKit
import PDFReaderCore


@MainActor
final class ApplicationController {
    let settingsResult: SettingsLoadResult
    let sessionStore: ReaderSessionStore
    let coordinator: PaneCoordinator
    private let application: NSApplication
    private let terminationHandler: () -> Void
    private let newInstanceLauncher: () -> Void
    private let pdfOpenService: PDFOpenService
    private let openMetrics: any PDFOpenMetrics
    private let openPanelPresenter: any PDFOpenPanelPresenting
    private let passwordPresenter: any PDFPasswordPresenting
    private let actionDispatcher: ActionDispatcher
    private var pendingDuplicateTraces: [TabID: OpenTraceID] = [:]
    private let themeStore: ThemeSelectionStore
    private(set) var currentThemeID: ThemeID
    private let themeStartupDiagnostic: String?
    private let indicatorSettingsStore: LinkDestinationIndicatorSettingsStore
    private(set) var currentIndicatorSettings: LinkDestinationIndicatorSettings
    private let indicatorStartupDiagnostic: String?
    private let recentFilesStore: RecentFilesStore
    private let citationPreviewSettingsStore: CitationPreviewSettingsStore
    private(set) var isCitationPreviewEnabled: Bool
    private let citationPreviewStartupDiagnostic: String?
    private(set) var menuBuilder: ValidatedMenuBuilder?
    private let settingsService: SettingsService
    private var activeConfig: ValidatedAppConfig
    private var settingsCoordinator: SettingsCoordinator?
    enum ConfigInstallStep: Equatable {
        case dismissTransientOverlays
        case applyWindowConfig
        case updateNavigation
        case installMenu
        case activateConfig
    }
    private(set) var configInstallStepsForTesting: [ConfigInstallStep] = []
    private(set) var configInstallGenerationCountForTesting = 0
    private struct PreparedConfigGeneration {
        let validatedConfig: ValidatedAppConfig
        let menuBuilder: ValidatedMenuBuilder
        let mainMenu: NSMenu
    }

    lazy var mainWindowController: MainWindowController = {
        let controller = MainWindowController(
            coordinator: coordinator,
            theme: AppKitTheme(themeID: currentThemeID),
            actionHandler: { [weak self] action in self?.dispatch(action) },
            keyDispatchHandler: { [weak self] dispatch in self?.dispatch(dispatch) },
            validatedConfig: activeConfig,
            openPaneHandler: { [weak self] paneID in self?.presentOpenPanel(target: .existing(paneID)) },
            currentThemeID: { [weak self] in self?.currentThemeID ?? .tokyoNight },
            themePreviewHandler: { [weak self] id in self?.applyTheme(id, persist: false) },
            themeCommitHandler: { [weak self] id in self?.applyTheme(id, persist: true) },
            themeCancelHandler: { [weak self] id in self?.applyTheme(id, persist: false) },
            currentIndicatorSettings: { [weak self] in self?.currentIndicatorSettings ?? .standard },
            indicatorPreviewHandler: { [weak self] settings in self?.applyIndicatorSettings(settings, persist: false) },
            indicatorCommitHandler: { [weak self] settings in self?.applyIndicatorSettings(settings, persist: true) },
            indicatorCancelHandler: { [weak self] settings in self?.applyIndicatorSettings(settings, persist: false) },
            browseHandler: { [weak self] in self?.presentOpenPanel() },
            recentFilesProvider: { [weak self] in self?.recentFilesStore.load() ?? [] },
            recentOpenHandler: { [weak self] path in _ = self?.openDocument(at: URL(fileURLWithPath: path)) },
            recentPruneHandler: { [weak self] path in self?.recentFilesStore.prune(absolutePath: path) ?? .failed(message: "recent-files store unavailable") },
            recentClearHandler: { [weak self] in self?.recentFilesStore.clear() ?? .failed(message: "recent-files store unavailable") },
        )
        actionDispatcher.presentation = controller
        return controller
    }()
    init(
        application: NSApplication = .shared,
        settingsService: SettingsService = SettingsService(),
        sessionStore: ReaderSessionStore = ReaderSessionStore(),
        pdfOpenService: PDFOpenService = PDFOpenService(),
        openMetrics: any PDFOpenMetrics = OSLogPDFOpenMetrics(),
        openPanelPresenter: any PDFOpenPanelPresenting = NativePDFOpenPanelPresenter(),
        passwordPresenter: any PDFPasswordPresenting = NativePDFPasswordPresenter(),
        themeStore: ThemeSelectionStore = ThemeSelectionStore(),
        indicatorSettingsStore: LinkDestinationIndicatorSettingsStore = LinkDestinationIndicatorSettingsStore(),
        recentFilesStore: RecentFilesStore = RecentFilesStore(),
        citationPreviewSettingsStore: CitationPreviewSettingsStore = CitationPreviewSettingsStore(),
        terminationHandler: (() -> Void)? = nil,
        newInstanceLauncher: (() -> Void)? = nil
    ) {
        let settingsResult = settingsService.load()
        self.application = application; self.settingsService = settingsService; self.settingsResult = settingsResult; self.activeConfig = settingsResult.activeConfig; self.sessionStore = sessionStore
        self.coordinator = PaneCoordinator(initialStore: sessionStore)
        self.pdfOpenService = pdfOpenService; self.openMetrics = openMetrics; self.openPanelPresenter = openPanelPresenter; self.themeStore = themeStore; self.recentFilesStore = recentFilesStore
        self.passwordPresenter = passwordPresenter
        self.indicatorSettingsStore = indicatorSettingsStore
        self.citationPreviewSettingsStore = citationPreviewSettingsStore
        switch themeStore.load() {
        case let .selected(id): self.currentThemeID = id; self.themeStartupDiagnostic = nil
        case .absent, .invalid: self.currentThemeID = ThemeSelectionStore.productDefault; self.themeStartupDiagnostic = nil
        case let .ioError(message): self.currentThemeID = ThemeSelectionStore.productDefault; self.themeStartupDiagnostic = "Could not read the saved theme (\(message)); using the default."
        }
        switch indicatorSettingsStore.load() {
        case let .selected(settings):
            self.currentIndicatorSettings = settings
            self.indicatorStartupDiagnostic = nil
        case .absent, .invalid:
            self.currentIndicatorSettings = LinkDestinationIndicatorSettingsStore.productDefault
            self.indicatorStartupDiagnostic = nil
        case let .ioError(message):
            self.currentIndicatorSettings = LinkDestinationIndicatorSettingsStore.productDefault
            self.indicatorStartupDiagnostic = "Could not read the saved link indicator settings (\(message)); using the default."
        }
        switch citationPreviewSettingsStore.load() {
        case let .selected(enabled):
            self.isCitationPreviewEnabled = enabled
            self.citationPreviewStartupDiagnostic = nil
        case .absent, .invalid:
            self.isCitationPreviewEnabled = CitationPreviewSettingsStore.productDefault
            self.citationPreviewStartupDiagnostic = nil
        case let .ioError(message):
            self.isCitationPreviewEnabled = CitationPreviewSettingsStore.productDefault
            self.citationPreviewStartupDiagnostic = "Could not read the saved citation preview setting (\(message)); using OFF."
        }
        self.terminationHandler = terminationHandler ?? { application.terminate(nil) }
        self.newInstanceLauncher = newInstanceLauncher ?? { ApplicationController.launchNewInstance() }
        self.actionDispatcher = ActionDispatcher(coordinator: coordinator, navigation: settingsResult.activeConfig.config.navigation)
        self.actionDispatcher.configureLifecycleHandlers(openDocument: { [weak self] in self?.presentOpenPanel() }, terminate: { [weak self] in self?.terminationHandler() }, newInstance: { [weak self] in self?.newInstanceLauncher() })
        coordinator.configureDuplication { [weak self] snapshot in self?.makeDuplicate(from: snapshot) }
        self.actionDispatcher.configureSettingsHandler { [weak self] in self?.presentSettings() }
        coordinator.configureDuplicationCompletion { [weak self] session, committed in self?.completeDuplicate(session, committed: committed) }
        coordinator.applyLinkDestinationIndicatorSettings(currentIndicatorSettings)
        coordinator.applyCitationPreviewEnabled(isCitationPreviewEnabled)
        mainWindowController.rootView.setCitationPreviewEnabled(isCitationPreviewEnabled)
        self.actionDispatcher.configureCitationPreviewToggleHandler { [weak self] in self?.toggleCitationPreview() }
    }

    func start() {
        let menuBuilder = ValidatedMenuBuilder(
            descriptors: activeConfig.menuDescriptors,
            dispatch: { [weak self] action in self?.dispatch(action) },
            isEnabled: { [weak self] action in self?.actionDispatcher.isActionEnabled(action) ?? false }
        )
        self.menuBuilder = menuBuilder
        application.mainMenu = menuBuilder.makeMainMenu()
        mainWindowController.showWindow(nil)

        let stateDiagnostics = [
            themeStartupDiagnostic,
            indicatorStartupDiagnostic,
            citationPreviewStartupDiagnostic,
        ].compactMap { $0 }
        if !settingsResult.diagnostics.isEmpty {
            let presentation = ConfigDiagnosticPresentation(
                diagnostics: settingsResult.diagnostics,
                usedFallback: settingsResult.diagnostics.contains { $0.severity == .error }
            )
            let detail = ([presentation.details].compactMap { $0 } + stateDiagnostics).joined(separator: "\n")
            mainWindowController.showDiagnostic(
                presentation.summary,
                expandedDetail: detail.isEmpty ? nil : detail,
                isError: presentation.hasErrors
            )
        } else if !stateDiagnostics.isEmpty {
            mainWindowController.showDiagnostic(stateDiagnostics.joined(separator: "\n"), isError: false)
        }
        checkForUpdates()
    }

    private func checkForUpdates() {
        Task { [weak self] in
            let update = await UpdateChecker().fetchUpdate()
            guard let self, let update else { return }
            self.mainWindowController.installAvailableUpdate(update)
        }
    }
    func dispatch(_ action: ActionID) {
        if mainWindowController.isSettingsPresented {
            if action == .settingsOpen { return }
            guard action == .appQuit, settingsCoordinator?.requestClose() == true else { return }
        }
        actionDispatcher.dispatch(action)
    }

    func presentSettings() {
        guard !mainWindowController.isSettingsPresented, let window = mainWindowController.window else { return }
        let editor = SettingsCoordinator(
            service: settingsService,
            view: mainWindowController.rootView.settingsOverlay,
            window: window,
            currentConfig: { [unowned self] in self.activeConfig },
            currentGeneration: { [unowned self] in self.configInstallGenerationCountForTesting },
            install: { [weak self] config in
                guard let self else { return }
                self.install(self.prepare(config))
            },
            closePanel: { [weak self] in self?.mainWindowController.dismissSettingsPanel() }
        )
        settingsCoordinator = editor
        mainWindowController.onSettingsClose = { [weak editor] in editor?.requestClose() ?? true }
        mainWindowController.presentSettingsPanel()
        editor.open()
    }

    func dispatch(_ keyDispatch: KeyActionDispatch) {
        if mainWindowController.isSettingsPresented {
            dispatch(keyDispatch.actionID)
            return
        }
        actionDispatcher.dispatch(keyDispatch)
    }

    private func prepare(_ config: ValidatedAppConfig) -> PreparedConfigGeneration {
        let builder = ValidatedMenuBuilder(
            descriptors: config.menuDescriptors,
            dispatch: { [weak self] action in self?.dispatch(action) },
            isEnabled: { [weak self] action in
                guard let self else { return false }
                if self.mainWindowController.isSettingsPresented {
                    return action == .settingsOpen || action == .appQuit
                }
                return self.actionDispatcher.isActionEnabled(action)
            }
        )
        return PreparedConfigGeneration(validatedConfig: config, menuBuilder: builder, mainMenu: builder.makeMainMenu())
    }

    private func install(_ generation: PreparedConfigGeneration) {
        configInstallStepsForTesting = []
        mainWindowController.dismissAllTransientOverlays()
        configInstallGenerationCountForTesting += 1
        configInstallStepsForTesting.append(.dismissTransientOverlays)
        mainWindowController.applyConfig(generation.validatedConfig)
        configInstallStepsForTesting.append(.applyWindowConfig)
        actionDispatcher.updateNavigation(generation.validatedConfig.config.navigation)
        configInstallStepsForTesting.append(.updateNavigation)
        application.mainMenu = generation.mainMenu
        menuBuilder = generation.menuBuilder
        configInstallStepsForTesting.append(.installMenu)
        activeConfig = generation.validatedConfig
        configInstallStepsForTesting.append(.activateConfig)
        mainWindowController.clearDiagnostic(force: true)
    }
    @discardableResult func openDocument(at url: URL, target: PaneOpenTarget = .createIfEmpty) -> Bool {
        let traceID = OpenTraceID(); openMetrics.record(.point(.openRequested, traceID: traceID)); openMetrics.record(.begin(.openTotal, traceID: traceID))
        do {
            let session = try openSession(at: url, traceID: traceID)
            session.applyTheme(AppKitTheme(themeID: currentThemeID))
            session.applyLinkDestinationIndicatorSettings(currentIndicatorSettings)
            session.applyCitationPreviewEnabled(isCitationPreviewEnabled)
            guard coordinator.insert(session, into: target) else { session.prepareForClose(reason: .insertionRejected); mainWindowController.showDiagnostic("Could not create a PDF tab for \(url.lastPathComponent)"); recordOpenFailure(traceID: traceID, outcome: .insertionRejected); return false }
            mainWindowController.clearDiagnostic()
            if case let .failed(message) = recentFilesStore.recordOpened(absolutePath: url.path) {
                mainWindowController.showDiagnostic("PDF opened but recent-files list could not be saved: \(message)")
            }
            openMetrics.record(.point(.openReady, traceID: traceID, outcome: .success))
            openMetrics.record(.end(.openTotal, traceID: traceID, outcome: .success))
            return true
        } catch PDFOpenError.cancelled {
            openMetrics.record(.end(.openTotal, traceID: traceID, outcome: .cancelled))
            return false
        } catch let error as PDFOpenError { mainWindowController.showDiagnostic(error.presentation); recordOpenFailure(traceID: traceID, outcome: error.metricOutcome); return false
        } catch { mainWindowController.showDiagnostic("Could not open PDF: \(error.localizedDescription)"); recordOpenFailure(traceID: traceID, outcome: .unexpectedFailure); return false }
    }
    func applyTheme(_ id: ThemeID, persist: Bool) {
        currentThemeID = id
        let theme = AppKitTheme(themeID: id)
        mainWindowController.apply(theme: theme)
        coordinator.applyTheme(theme)
        if persist, case let .failed(message) = themeStore.persist(id) {
            // The theme is applied for this session, but the durable write
            // failed; tell the user instead of pretending it committed.
            mainWindowController.showDiagnostic("Theme applied for this session but could not be saved: \(message)")
        }
    }

    func applyIndicatorSettings(_ settings: LinkDestinationIndicatorSettings, persist: Bool) {
        currentIndicatorSettings = settings
        coordinator.applyLinkDestinationIndicatorSettings(settings)
        if persist, case let .failed(message) = indicatorSettingsStore.persist(settings) {
            mainWindowController.showDiagnostic(
                "Link indicator settings applied for this session but could not be saved: \(message)"
            )
        }

    }
    func toggleCitationPreview() {
        isCitationPreviewEnabled.toggle()
        mainWindowController.dismissAllTransientOverlays()
        coordinator.applyCitationPreviewEnabled(isCitationPreviewEnabled)
        mainWindowController.rootView.setCitationPreviewEnabled(isCitationPreviewEnabled)
        let state = isCitationPreviewEnabled ? "ON" : "OFF"
        if case let .failed(message) = citationPreviewSettingsStore.persist(isCitationPreviewEnabled) {
            mainWindowController.showDiagnostic(
                "Citation Preview · Experimental · \(state) · could not save: \(message)"
            )
            return
        }
    }
    func openExternalDocuments(_ urls: [URL]) { for url in urls { _ = openDocument(at: url) } }
    private func presentOpenPanel(target: PaneOpenTarget = .createIfEmpty) { openPanelPresenter.present(attachedTo: mainWindowController.window) { [weak self] url in guard let self, let url else { return }; _ = self.openDocument(at: url, target: target) } }
    private func recordOpenFailure(traceID: OpenTraceID, outcome: PDFOpenMetricOutcome) { openMetrics.record(.point(.openFailed, traceID: traceID, outcome: outcome)); openMetrics.record(.end(.openTotal, traceID: traceID, outcome: outcome)) }

    private func openSession(at url: URL, traceID: OpenTraceID) throws -> ReaderSession {
        var prompted = false
        defer {
            if prompted { mainWindowController.restoreReaderFocus() }
        }
        return try pdfOpenService.open(url: url, traceID: traceID, metrics: openMetrics) { invalidPassword in
            if !prompted {
                self.mainWindowController.dismissAllTransientOverlays()
                self.mainWindowController.prepareForGlobalAction()
            }
            prompted = true
            return self.passwordPresenter.requestPassword(for: url, invalidPassword: invalidPassword)
        }
    }

    private func makeDuplicate(from snapshot: ReaderDuplicationSnapshot) -> (any ReaderSessionPresenting)? {
        let traceID = OpenTraceID(); openMetrics.record(.point(.openRequested, traceID: traceID)); openMetrics.record(.begin(.openTotal, traceID: traceID))
        do {
            let session = try openSession(at: snapshot.sourceURL, traceID: traceID)
            session.applyTheme(AppKitTheme(themeID: currentThemeID))
            session.applyLinkDestinationIndicatorSettings(currentIndicatorSettings)
            session.applyCitationPreviewEnabled(isCitationPreviewEnabled)
            session.seedPendingPresentation(snapshot)
            pendingDuplicateTraces[session.id] = traceID
            return session
        } catch PDFOpenError.cancelled {
            openMetrics.record(.end(.openTotal, traceID: traceID, outcome: .cancelled))
        } catch let error as PDFOpenError { mainWindowController.showDiagnostic(error.presentation); recordOpenFailure(traceID: traceID, outcome: error.metricOutcome)
        } catch { mainWindowController.showDiagnostic("Could not duplicate PDF: \(error.localizedDescription)"); recordOpenFailure(traceID: traceID, outcome: .unexpectedFailure) }
        return nil
    }

    private func completeDuplicate(_ session: any ReaderSessionPresenting, committed: Bool) {
        guard let traceID = pendingDuplicateTraces.removeValue(forKey: session.id) else { return }
        if committed { openMetrics.record(.point(.openReady, traceID: traceID, outcome: .success)); openMetrics.record(.end(.openTotal, traceID: traceID, outcome: .success))
        } else { recordOpenFailure(traceID: traceID, outcome: .insertionRejected) }
    }

    private static func launchNewInstance() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration, completionHandler: nil)
    }
}

struct ConfigDiagnosticPresentation: Equatable {
    let summary: String; let details: String; let hasErrors: Bool
    init(diagnostics: [ConfigDiagnostic], usedFallback: Bool) { let errorCount = diagnostics.count { $0.severity == .error }; let warningCount = diagnostics.count { $0.severity == .warning }; hasErrors = errorCount > 0; var counts: [String] = []; if errorCount > 0 { counts.append("\(errorCount) error\(errorCount == 1 ? "" : "s")") }; if warningCount > 0 { counts.append("\(warningCount) warning\(warningCount == 1 ? "" : "s")") }; summary = "Configuration: \(counts.joined(separator: ", "))\(usedFallback ? " · built-in defaults active" : "")"; details = diagnostics.enumerated().map { index, diagnostic in let location = [diagnostic.sourcePath, diagnostic.line.map(String.init)].compactMap { $0 }.joined(separator: ":"); var fields = ["\(index + 1). \(diagnostic.severity.rawValue.uppercased()) [\(diagnostic.code.rawValue)]", location.isEmpty ? "config" : location, diagnostic.semanticPath.isEmpty ? "$" : diagnostic.semanticPath, diagnostic.message]; if !diagnostic.actions.isEmpty { fields.append("actions: \(diagnostic.actions.joined(separator: ", "))") }; if !diagnostic.contexts.isEmpty { fields.append("contexts: \(diagnostic.contexts.map(\.rawValue).joined(separator: ", "))") }; return fields.joined(separator: " — ") }.joined(separator: "\n") }
}
