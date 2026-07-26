import AppKit
import PDFReaderCore

@MainActor
final class ApplicationController {
    let configResult: ConfigLoadResult
    let sessionStore: ReaderSessionStore
    let coordinator: PaneCoordinator
    private let application: NSApplication
    private let terminationHandler: () -> Void
    private let pdfOpenService: PDFOpenService
    private let openMetrics: any PDFOpenMetrics
    private let openPanelPresenter: any PDFOpenPanelPresenting
    private let actionDispatcher: ActionDispatcher
    private var pendingDuplicateTraces: [TabID: OpenTraceID] = [:]
    private let themeStore: ThemeSelectionStore
    private(set) var currentThemeID: ThemeID
    private(set) var menuBuilder: ValidatedMenuBuilder?

    lazy var mainWindowController: MainWindowController = {
        let controller = MainWindowController(coordinator: coordinator, theme: AppKitTheme(themeID: currentThemeID), actionHandler: { [weak self] action in self?.actionDispatcher.dispatch(action) }, keyDispatchHandler: { [weak self] dispatch in self?.actionDispatcher.dispatch(dispatch) }, validatedConfig: configResult.activeConfig, openPaneHandler: { [weak self] paneID in self?.presentOpenPanel(target: .existing(paneID)) }, currentThemeID: { [weak self] in self?.currentThemeID ?? .catppuccinMocha }, themePreviewHandler: { [weak self] id in self?.applyTheme(id, persist: false) }, themeCommitHandler: { [weak self] id in self?.applyTheme(id, persist: true) }, themeCancelHandler: { [weak self] id in self?.applyTheme(id, persist: false) })
        actionDispatcher.presentation = controller
        return controller
    }()

    init(application: NSApplication = .shared, configService: ConfigService = ConfigService(), sessionStore: ReaderSessionStore = ReaderSessionStore(), pdfOpenService: PDFOpenService = PDFOpenService(), openMetrics: any PDFOpenMetrics = OSLogPDFOpenMetrics(), openPanelPresenter: any PDFOpenPanelPresenting = NativePDFOpenPanelPresenter(), themeStore: ThemeSelectionStore = ThemeSelectionStore(), terminationHandler: (() -> Void)? = nil) {
        let configResult = configService.load()
        self.application = application; self.configResult = configResult; self.sessionStore = sessionStore
        self.coordinator = PaneCoordinator(initialStore: sessionStore)
        self.pdfOpenService = pdfOpenService; self.openMetrics = openMetrics; self.openPanelPresenter = openPanelPresenter; self.themeStore = themeStore; self.currentThemeID = themeStore.resolvedTheme(); self.terminationHandler = terminationHandler ?? { application.terminate(nil) }
        self.actionDispatcher = ActionDispatcher(coordinator: coordinator, navigation: configResult.activeConfig.config.navigation)
        self.actionDispatcher.configureLifecycleHandlers(openDocument: { [weak self] in self?.presentOpenPanel() }, terminate: { [weak self] in self?.terminationHandler() })
        coordinator.configureDuplication { [weak self] snapshot in self?.makeDuplicate(from: snapshot) }
        coordinator.configureDuplicationCompletion { [weak self] session, committed in self?.completeDuplicate(session, committed: committed) }
    }

    func start() { let menuBuilder = ValidatedMenuBuilder(descriptors: configResult.activeConfig.menuDescriptors, dispatch: { [weak self] action in self?.dispatch(action) }); self.menuBuilder = menuBuilder; application.mainMenu = menuBuilder.makeMainMenu(); mainWindowController.showWindow(nil); if !configResult.diagnostics.isEmpty { let presentation = ConfigDiagnosticPresentation(diagnostics: configResult.diagnostics, usedFallback: configResult.usedFallback); mainWindowController.showDiagnostic(presentation.summary, expandedDetail: presentation.details, isError: presentation.hasErrors) } }
    func dispatch(_ action: ActionID) { actionDispatcher.dispatch(action) }
    @discardableResult func openDocument(at url: URL, target: PaneOpenTarget = .createIfEmpty) -> Bool {
        let traceID = OpenTraceID(); openMetrics.record(.point(.openRequested, traceID: traceID)); openMetrics.record(.begin(.openTotal, traceID: traceID))
        do {
            let session = try pdfOpenService.open(url: url, traceID: traceID, metrics: openMetrics); session.applyTheme(AppKitTheme(themeID: currentThemeID))
            guard coordinator.insert(session, into: target) else { session.prepareForClose(reason: .insertionRejected); mainWindowController.showDiagnostic("Could not create a PDF tab for \(url.lastPathComponent)"); recordOpenFailure(traceID: traceID, outcome: .insertionRejected); return false }
            mainWindowController.clearDiagnostic(); openMetrics.record(.point(.openReady, traceID: traceID, outcome: .success)); openMetrics.record(.end(.openTotal, traceID: traceID, outcome: .success)); return true
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
}

struct ConfigDiagnosticPresentation: Equatable {
    let summary: String; let details: String; let hasErrors: Bool
    init(diagnostics: [ConfigDiagnostic], usedFallback: Bool) { let errorCount = diagnostics.count { $0.severity == .error }; let warningCount = diagnostics.count { $0.severity == .warning }; hasErrors = errorCount > 0; var counts: [String] = []; if errorCount > 0 { counts.append("\(errorCount) error\(errorCount == 1 ? "" : "s")") }; if warningCount > 0 { counts.append("\(warningCount) warning\(warningCount == 1 ? "" : "s")") }; summary = "Configuration: \(counts.joined(separator: ", "))\(usedFallback ? " · built-in defaults active" : "")"; details = diagnostics.enumerated().map { index, diagnostic in let location = [diagnostic.sourcePath, diagnostic.line.map(String.init)].compactMap { $0 }.joined(separator: ":"); var fields = ["\(index + 1). \(diagnostic.severity.rawValue.uppercased()) [\(diagnostic.code.rawValue)]", location.isEmpty ? "config" : location, diagnostic.semanticPath.isEmpty ? "$" : diagnostic.semanticPath, diagnostic.message]; if !diagnostic.actions.isEmpty { fields.append("actions: \(diagnostic.actions.joined(separator: ", "))") }; if !diagnostic.contexts.isEmpty { fields.append("contexts: \(diagnostic.contexts.map(\.rawValue).joined(separator: ", "))") }; return fields.joined(separator: " — ") }.joined(separator: "\n") }
}
