import AppKit
import PDFReaderCore


@MainActor
final class ApplicationController {
    let configResult: ConfigLoadResult
    let sessionStore: ReaderSessionStore
    let coordinator: PaneCoordinator
    private let application: NSApplication
    private let terminationHandler: () -> Void
    private let newInstanceLauncher: () -> Void
    private let pdfOpenService: PDFOpenService
    private let openMetrics: any PDFOpenMetrics
    private let openPanelPresenter: any PDFOpenPanelPresenting
    private let actionDispatcher: ActionDispatcher
    private var pendingDuplicateTraces: [TabID: OpenTraceID] = [:]
    private let themeStore: ThemeSelectionStore
    private(set) var currentThemeID: ThemeID
    private let themeStartupDiagnostic: String?
    private let recentFilesStore: RecentFilesStore
    private(set) var menuBuilder: ValidatedMenuBuilder?
    private let configService: ConfigService
    private var activeConfig: ValidatedAppConfig
    private let configFileStore: ConfigFileStore
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
            browseHandler: { [weak self] in self?.presentOpenPanel() },
            recentFilesProvider: { [weak self] in self?.recentFilesStore.load() ?? [] },
            recentOpenHandler: { [weak self] path in _ = self?.openDocument(at: URL(fileURLWithPath: path)) },
            recentPruneHandler: { [weak self] path in self?.recentFilesStore.prune(absolutePath: path) ?? .failed(message: "recent-files store unavailable") },
            recentClearHandler: { [weak self] in self?.recentFilesStore.clear() ?? .failed(message: "recent-files store unavailable") },
            configFileURLProvider: { [weak self] in self?.configService.source.url ?? ConfigFileSource.defaultURL() }
        )
        actionDispatcher.presentation = controller
        return controller
    }()
    init(application: NSApplication = .shared, configService: ConfigService = ConfigService(), sessionStore: ReaderSessionStore = ReaderSessionStore(), pdfOpenService: PDFOpenService = PDFOpenService(), openMetrics: any PDFOpenMetrics = OSLogPDFOpenMetrics(), openPanelPresenter: any PDFOpenPanelPresenting = NativePDFOpenPanelPresenter(), themeStore: ThemeSelectionStore = ThemeSelectionStore(), recentFilesStore: RecentFilesStore = RecentFilesStore(), terminationHandler: (() -> Void)? = nil, newInstanceLauncher: (() -> Void)? = nil) {
        let configResult = configService.load()
        self.application = application; self.configService = configService; self.configResult = configResult; self.activeConfig = configResult.activeConfig; self.sessionStore = sessionStore
        self.coordinator = PaneCoordinator(initialStore: sessionStore)
        self.configFileStore = ConfigFileStore(fileURL: configService.source.url)
        self.pdfOpenService = pdfOpenService; self.openMetrics = openMetrics; self.openPanelPresenter = openPanelPresenter; self.themeStore = themeStore; self.recentFilesStore = recentFilesStore
        switch themeStore.load() {
        case let .selected(id): self.currentThemeID = id; self.themeStartupDiagnostic = nil
        case .absent, .invalid: self.currentThemeID = ThemeSelectionStore.productDefault; self.themeStartupDiagnostic = nil
        case let .ioError(message): self.currentThemeID = ThemeSelectionStore.productDefault; self.themeStartupDiagnostic = "Could not read the saved theme (\(message)); using the default."
        }
        self.terminationHandler = terminationHandler ?? { application.terminate(nil) }
        self.newInstanceLauncher = newInstanceLauncher ?? { ApplicationController.launchNewInstance() }
        self.actionDispatcher = ActionDispatcher(coordinator: coordinator, navigation: configResult.activeConfig.config.navigation)
        self.actionDispatcher.configureLifecycleHandlers(openDocument: { [weak self] in self?.presentOpenPanel() }, terminate: { [weak self] in self?.terminationHandler() }, newInstance: { [weak self] in self?.newInstanceLauncher() })
        coordinator.configureDuplication { [weak self] snapshot in self?.makeDuplicate(from: snapshot) }
        self.actionDispatcher.configureConfigReloadHandler { [weak self] in self?.reloadConfig() }
        coordinator.configureDuplicationCompletion { [weak self] session, committed in self?.completeDuplicate(session, committed: committed) }
        self.actionDispatcher.configureConfigWriteDefaultHandler { [weak self] in self?.writeDefaultConfig() }
        self.actionDispatcher.configureConfigResetDefaultHandler { [weak self] in self?.resetConfig() }
    }

    func start() { let menuBuilder = ValidatedMenuBuilder(descriptors: activeConfig.menuDescriptors, dispatch: { [weak self] action in self?.dispatch(action) }, isEnabled: { [weak self] action in self?.actionDispatcher.isActionEnabled(action) ?? false }); self.menuBuilder = menuBuilder; application.mainMenu = menuBuilder.makeMainMenu(); mainWindowController.showWindow(nil); if !configResult.diagnostics.isEmpty {
            // Aggregate independent startup failures so a config warning never
            // hides an operational theme-state I/O error (or vice versa).
            let presentation = ConfigDiagnosticPresentation(diagnostics: configResult.diagnostics, usedFallback: configResult.usedFallback)
            let detail = [presentation.details, themeStartupDiagnostic].compactMap { $0 }.joined(separator: "\n")
            mainWindowController.showDiagnostic(presentation.summary, expandedDetail: detail.isEmpty ? nil : detail, isError: presentation.hasErrors)
        } else if let themeStartupDiagnostic {
            mainWindowController.showDiagnostic(themeStartupDiagnostic, isError: false)
        }
        checkForUpdates()
    }

    private func checkForUpdates() {
        Task { [weak self] in
            let banner = await UpdateChecker().fetchBanner()
            guard let self, let banner else { return }
            self.mainWindowController.presentUpdateBanner(banner) {
                NSWorkspace.shared.open(UpdateChecker.releasesPage)
            }
        }
    }
    func dispatch(_ action: ActionID) { actionDispatcher.dispatch(action) }

    func dispatch(_ keyDispatch: KeyActionDispatch) {
        if keyDispatch.actionID == .configReload {
            reloadConfig()
        } else {
            actionDispatcher.dispatch(keyDispatch)
        }
    }

    func reloadConfig() {
        switch configService.reload() {
        case let .applied(config, warnings):
            let prepared = prepare(config)
            install(prepared)
            let message = warnings.isEmpty ? "Config reloaded" : "Config reloaded (\(warnings.count) warnings)"
            mainWindowController.showDiagnostic(message, isError: false)
        case let .rejected(diagnostics):
            let presentation = ConfigDiagnosticPresentation(diagnostics: diagnostics, usedFallback: false)
            mainWindowController.showDiagnostic("Configuration rejected; previous configuration remains active.", expandedDetail: presentation.details, isError: true, pinned: true)
        case .missing:
            mainWindowController.showDiagnostic("No configuration file to reload.", isError: false)
        }
    }

    func writeDefaultConfig() {
        switch configFileStore.writeDefaultExclusive(Data(BuiltInDefaults.defaultConfigTOML.utf8)) {
        case .created:
            mainWindowController.showDiagnostic("Default config written", isError: false)
        case .alreadyExists:
            mainWindowController.showDiagnostic("Config already exists", isError: false)
        case let .failed(message):
            mainWindowController.showDiagnostic("Could not write default config: \(message)")
        }
    }

    func resetConfig() {
        let builtIn = ConfigValidator.validate(SparseAppConfig())
        guard let config = builtIn.validatedConfig else {
            preconditionFailure("Built-in configuration must validate")
        }
        let prepared = prepare(config)
        switch configFileStore.reset(defaultBytes: Data(BuiltInDefaults.defaultConfigTOML.utf8)) {
        case .replaced:
            install(prepared)
            mainWindowController.showDiagnostic("Config reset to defaults", isError: false)
        case .unchanged:
            if activeConfig.config != prepared.validatedConfig.config || mainWindowController.hasPinnedDiagnostic {
                install(prepared)
            }
            mainWindowController.showDiagnostic("Config already matches defaults", isError: false)
        case .missingFile:
            mainWindowController.showDiagnostic("No config file to reset", isError: false)
        case let .failed(message):
            mainWindowController.showDiagnostic("Could not reset config: \(message)")
        }
    }
    private func prepare(_ config: ValidatedAppConfig) -> PreparedConfigGeneration {
        let builder = ValidatedMenuBuilder(
            descriptors: config.menuDescriptors,
            dispatch: { [weak self] action in self?.dispatch(action) },
            isEnabled: { [weak self] action in self?.actionDispatcher.isActionEnabled(action) ?? false }
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
            let session = try pdfOpenService.open(url: url, traceID: traceID, metrics: openMetrics); session.applyTheme(AppKitTheme(themeID: currentThemeID))
            guard coordinator.insert(session, into: target) else { session.prepareForClose(reason: .insertionRejected); mainWindowController.showDiagnostic("Could not create a PDF tab for \(url.lastPathComponent)"); recordOpenFailure(traceID: traceID, outcome: .insertionRejected); return false }
            mainWindowController.clearDiagnostic()
            if case let .failed(message) = recentFilesStore.recordOpened(absolutePath: url.path) {
                mainWindowController.showDiagnostic("PDF opened but recent-files list could not be saved: \(message)")
            }
            openMetrics.record(.point(.openReady, traceID: traceID, outcome: .success))
            openMetrics.record(.end(.openTotal, traceID: traceID, outcome: .success))
            return true
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
    func openExternalDocuments(_ urls: [URL]) { for url in urls { _ = openDocument(at: url) } }
    private func presentOpenPanel(target: PaneOpenTarget = .createIfEmpty) { openPanelPresenter.present(attachedTo: mainWindowController.window) { [weak self] url in guard let self, let url else { return }; _ = self.openDocument(at: url, target: target) } }
    private func recordOpenFailure(traceID: OpenTraceID, outcome: PDFOpenMetricOutcome) { openMetrics.record(.point(.openFailed, traceID: traceID, outcome: outcome)); openMetrics.record(.end(.openTotal, traceID: traceID, outcome: outcome)) }

    private func makeDuplicate(from snapshot: ReaderDuplicationSnapshot) -> (any ReaderSessionPresenting)? {
        let traceID = OpenTraceID(); openMetrics.record(.point(.openRequested, traceID: traceID)); openMetrics.record(.begin(.openTotal, traceID: traceID))
        do {
            let session = try pdfOpenService.open(url: snapshot.sourceURL, traceID: traceID, metrics: openMetrics)
            session.applyTheme(AppKitTheme(themeID: currentThemeID))
            session.seedPendingPresentation(snapshot)
            pendingDuplicateTraces[session.id] = traceID
            return session
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
