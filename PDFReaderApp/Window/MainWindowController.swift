import AppKit
import PDFReaderCore

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let coordinator: PaneCoordinator
    private let actionHandler: (ActionID) -> Void
    private var inputRouter: ReaderInputRouter!
    private var lastActiveSessionID: TabID?
    private let openPaneHandler: ((PaneID) -> Void)?
    private var tocTabIDsByPane: [PaneID: TabID?] = [:]
    private var promptCloseProjection: (layout: PaneLayout, paneID: PaneID?, tabID: TabID?)?
    private let currentThemeID: () -> ThemeID
    private let themePreviewHandler: (ThemeID) -> Void
    private let themeCommitHandler: (ThemeID) -> Void
    private let themeCancelHandler: (ThemeID) -> Void
    private(set) var resolvedConfig: ValidatedAppConfig
    private var themePickerPreOpenThemeID: ThemeID?
    private let currentIndicatorSettings: () -> LinkDestinationIndicatorSettings
    private let indicatorPreviewHandler: (LinkDestinationIndicatorSettings) -> Void
    private let indicatorCommitHandler: (LinkDestinationIndicatorSettings) -> Void
    private let indicatorCancelHandler: (LinkDestinationIndicatorSettings) -> Void
    private var indicatorPickerPreOpenSettings: LinkDestinationIndicatorSettings?
    private var savedTransientInputContexts: [InputContext] = []
    private var preservesTransientInputContext = false
    private let browseHandler: () -> Void
    private let recentFilesProvider: () -> [RecentFileEntry]
    private let recentOpenHandler: (String) -> Void
    private let recentPruneHandler: (String) -> RecentFilesPersist
    private let recentClearHandler: () -> RecentFilesPersist
    private var installedKeyViewLoop: [NSView] = []
    private let configFileURLProvider: () -> URL
    let rootView: ReaderRootView
    private(set) var availableUpdate: AvailableUpdate?
    var hasAvailableUpdate: Bool { availableUpdate != nil }

    init(
        coordinator: PaneCoordinator,
        theme: AppKitTheme,
        actionHandler: @escaping (ActionID) -> Void,
        keyDispatchHandler: ((KeyActionDispatch) -> Void)? = nil,
        validatedConfig: ValidatedAppConfig? = nil,
        openPaneHandler: ((PaneID) -> Void)? = nil,
        currentThemeID: @escaping () -> ThemeID = { .tokyoNight },
        themePreviewHandler: @escaping (ThemeID) -> Void = { _ in },
        themeCommitHandler: @escaping (ThemeID) -> Void = { _ in },
        themeCancelHandler: @escaping (ThemeID) -> Void = { _ in },
        currentIndicatorSettings: @escaping () -> LinkDestinationIndicatorSettings = { .standard },
        indicatorPreviewHandler: @escaping (LinkDestinationIndicatorSettings) -> Void = { _ in },
        indicatorCommitHandler: @escaping (LinkDestinationIndicatorSettings) -> Void = { _ in },
        indicatorCancelHandler: @escaping (LinkDestinationIndicatorSettings) -> Void = { _ in },
        browseHandler: @escaping () -> Void = {},
        recentFilesProvider: @escaping () -> [RecentFileEntry] = { [] },
        recentOpenHandler: @escaping (String) -> Void = { _ in },
        recentPruneHandler: @escaping (String) -> RecentFilesPersist = { _ in .persisted },
        recentClearHandler: @escaping () -> RecentFilesPersist = { .persisted },
        configFileURLProvider: @escaping () -> URL = { ConfigFileSource.defaultURL() }
    ) {
        self.browseHandler = browseHandler
        self.recentFilesProvider = recentFilesProvider
        self.recentOpenHandler = recentOpenHandler
        self.recentPruneHandler = recentPruneHandler
        self.configFileURLProvider = configFileURLProvider
        self.recentClearHandler = recentClearHandler
        self.coordinator = coordinator
        self.actionHandler = actionHandler
        self.currentThemeID = currentThemeID
        self.themePreviewHandler = themePreviewHandler
        self.themeCommitHandler = themeCommitHandler
        self.themeCancelHandler = themeCancelHandler
        self.openPaneHandler = openPaneHandler
        self.currentIndicatorSettings = currentIndicatorSettings
        self.indicatorPreviewHandler = indicatorPreviewHandler
        self.indicatorCommitHandler = indicatorCommitHandler
        self.indicatorCancelHandler = indicatorCancelHandler
        self.rootView = ReaderRootView(frame: NSRect(origin: .zero, size: WindowVisualMetrics.initialSize))
        let config = validatedConfig ?? Self.builtInValidatedConfig()
        self.resolvedConfig = config
        rootView.emptyState.setOpenBinding(config.keymap.bindings(for: .documentOpen).first)

        let window = ReaderWindow(
            contentRect: NSRect(origin: .zero, size: WindowVisualMetrics.initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Modeleaf"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.autorecalculatesKeyViewLoop = false
        window.minSize = WindowVisualMetrics.minimumSize
        window.contentView = rootView
        window.setAccessibilityIdentifier("mainWindow")

        super.init(window: window)
        applyTOCKeyHints(config.keymap)
        inputRouter = ReaderInputRouter(
            config: config,
            pendingHandler: { [weak rootView] prefix in rootView?.setPendingPrefix(prefix) },
            dispatchHandler: { [weak self] dispatch in self?.handleKeyDispatch(dispatch, fallback: keyDispatchHandler) }
        )
        window.keyEventHandler = { [weak self] event in
            self?.routeKeyEvent(event) ?? false
        }
        window.delegate = self
        window.mouseDownHandler = { [weak self] event in
            guard let self else { return }
            self.dismissLinkHintsAndRestoreFocus()
            guard self.rootView.helpOverlay.isHidden else { return }
            self.rootView.activatePane(atWindowPoint: event.locationInWindow)
        }
        window.geometryEventHandler = { [weak self] in
            guard let self else { return }
            self.dismissLinkHintsAndRestoreFocus()
            (self.coordinator.activeSession as? ReaderSession)?.cancelDestinationIndicator()
        }
        rootView.apply(theme: theme)
        rootView.setInputContext(.navigation)
        rootView.statusBar.onHelpTap = { [weak self] in self?.presentHelp() }
        rootView.emptyState.openButton.handler = { [weak self] in self?.actionHandler(.documentOpen) }
        rootView.tabBar.onSelect = { [weak self] id in self?.dispatchTabSelection(to: id) }
        rootView.tabBar.onClose = { [weak self] id in self?.dispatchTabClose(id) }
        rootView.tabBar.onNewTab = { [weak self] in self?.actionHandler(.documentOpen) }
        rootView.onPaneActivate = { [weak self] paneID in
            _ = self?.coordinator.activatePane(paneID)
        }
        rootView.onPaneSelect = { [weak self] paneID, tabID in
            guard let self else { return }
            self.coordinator.activatePane(paneID)
            self.dispatchTabSelection(to: tabID)
        }
        rootView.onPaneClose = { [weak self] paneID, tabID in
            guard let self else { return }
            self.coordinator.activatePane(paneID)
            self.dispatchTabClose(tabID)
        }
        rootView.onPaneNewTab = { [weak self] paneID in
            guard let self else { return }
            self.coordinator.activatePane(paneID)
            if let openPaneHandler = self.openPaneHandler {
                openPaneHandler(paneID)
            } else {
                self.actionHandler(.documentOpen)
            }
        }
        rootView.promptOverlay.commitButton.handler = { [weak self] in self?.actionHandler(.promptCommit) }
        rootView.promptOverlay.cancelButton.handler = { [weak self] in self?.actionHandler(.promptCancel) }
        coordinator.onSnapshot = { [weak self] snapshot in self?.refresh(snapshot: snapshot) }
        coordinator.configureCloseStaging { [weak self] projected in self?.stageClose(projected) ?? false }
        refresh(snapshot: coordinator.snapshot)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        focusActiveSurface(snapshot: coordinator.snapshot)
    }

    func presentLinkHints() {
        dismissAllTransientOverlays(restoringContext: false)
        guard inputRouter.context == .navigation,
              let provider = coordinator.activeSession as? any ReaderLinkProviding,
              let session = coordinator.activeSession as? ReaderSession
        else { return }
        let links = LinkHintMerge.mergeLinks(provider.linkTargets())
        guard !links.isEmpty else { return }
        var displayed: [(link: ReaderLink, rects: [NSRect])] = []
        for link in links {
            let rects = session.linkHintRects(for: link, in: rootView.linkHintOverlay)
            if !rects.isEmpty { displayed.append((link, rects)) }
        }
        guard !displayed.isEmpty else { return }
        let labels = LinkHintLabels.generate(count: displayed.count)
        beginTransientOverlay()
        let sessionID = session.id
        rootView.linkHintOverlay.onCommit = { [weak self, weak provider] index in
            guard let self, self.coordinator.snapshot.activeID == sessionID, displayed.indices.contains(index) else { return }
            let target = displayed[index].link.target
            self.dismissLinkHintsAndRestoreFocus()
            provider?.activateLink(target)
        }
        rootView.linkHintOverlay.onDismiss = { [weak self] in self?.dismissLinkHintsAndRestoreFocus() }
        rootView.linkHintOverlay.present(
            hints: zip(displayed, labels).map { (rects: $0.0.rects, label: $0.1) }
        )
        window?.makeFirstResponder(rootView.linkHintOverlay)
    }

    func dismissLinkHintsAndRestoreFocus() {
        guard !rootView.linkHintOverlay.isHidden else { return }
        rootView.linkHintOverlay.dismiss()
        rootView.linkHintOverlay.onCommit = nil
        rootView.linkHintOverlay.onDismiss = nil
        restoreTransientInputContext()
        focusActiveSurface(snapshot: coordinator.snapshot)
    }

    func presentThemePicker() {
        dismissAllTransientOverlays(restoringContext: false)
        beginTransientOverlay()
        guard rootView.themePickerOverlay.isHidden else { return }
        let preOpenThemeID = currentThemeID()
        rootView.themePickerOverlay.onPreview = { [weak self] id in self?.themePreviewHandler(id) }
        themePickerPreOpenThemeID = preOpenThemeID
        rootView.themePickerOverlay.onCommit = { [weak self] id in
            guard let self else { return }
            self.themeCommitHandler(id)
            self.dismissThemePickerAndRestoreFocus()
        }
        rootView.themePickerOverlay.onCancel = { [weak self] in self?.cancelThemePickerAndRestoreFocus() }
        rootView.themePickerOverlay.present(selectedThemeID: preOpenThemeID)
        rebuildKeyViewLoop(snapshot: coordinator.snapshot)
        window?.makeFirstResponder(rootView.themePickerOverlay)
    }

    private func cancelThemePickerAndRestoreFocus() {
        guard !rootView.themePickerOverlay.isHidden else { return }
        let preOpenThemeID = themePickerPreOpenThemeID
        dismissThemePickerAndRestoreFocus()
        if let preOpenThemeID { themeCancelHandler(preOpenThemeID) }
    }

    private func dismissThemePickerAndRestoreFocus() {
        rootView.themePickerOverlay.dismiss()
        rootView.themePickerOverlay.onPreview = nil
        rootView.themePickerOverlay.onCommit = nil
        themePickerPreOpenThemeID = nil
        rootView.themePickerOverlay.onCancel = nil
        restoreTransientInputContext()
        rebuildKeyViewLoop(snapshot: coordinator.snapshot)
        focusActiveSurface(snapshot: coordinator.snapshot)
    }

    func presentLinkIndicatorPicker() {
        dismissAllTransientOverlays(restoringContext: false)
        beginTransientOverlay()
        guard rootView.linkIndicatorPickerOverlay.isHidden else { return }
        let baseline = currentIndicatorSettings()
        indicatorPickerPreOpenSettings = baseline
        rootView.linkIndicatorPickerOverlay.onPreview = { [weak self] settings in
            self?.indicatorPreviewHandler(settings)
        }
        rootView.linkIndicatorPickerOverlay.onCommit = { [weak self] settings in
            guard let self else { return }
            self.indicatorCommitHandler(settings)
            self.dismissLinkIndicatorPickerAndRestoreFocus()
        }
        rootView.linkIndicatorPickerOverlay.onCancel = { [weak self] in
            self?.cancelLinkIndicatorPickerAndRestoreFocus()
        }
        rootView.linkIndicatorPickerOverlay.present(settings: baseline)
        rebuildKeyViewLoop(snapshot: coordinator.snapshot)
        window?.makeFirstResponder(rootView.linkIndicatorPickerOverlay.initialFocusView)
    }

    private func cancelLinkIndicatorPickerAndRestoreFocus() {
        guard !rootView.linkIndicatorPickerOverlay.isHidden else { return }
        let baseline = indicatorPickerPreOpenSettings
        dismissLinkIndicatorPickerAndRestoreFocus()
        if let baseline { indicatorCancelHandler(baseline) }
    }

    private func dismissLinkIndicatorPickerAndRestoreFocus() {
        rootView.linkIndicatorPickerOverlay.dismiss()
        rootView.linkIndicatorPickerOverlay.onPreview = nil
        rootView.linkIndicatorPickerOverlay.onCommit = nil
        rootView.linkIndicatorPickerOverlay.onCancel = nil
        indicatorPickerPreOpenSettings = nil
        restoreTransientInputContext()
        rebuildKeyViewLoop(snapshot: coordinator.snapshot)
        focusActiveSurface(snapshot: coordinator.snapshot)
    }

    func dismissAllTransientOverlays(restoringContext: Bool = true) {
        preservesTransientInputContext = !restoringContext
        if !rootView.commandPaletteOverlay.isHidden { dismissCommandPaletteAndRestoreFocus() }
        if !rootView.helpOverlay.isHidden { dismissHelpOverlayAndRestoreFocus() }
        if !rootView.themePickerOverlay.isHidden { cancelThemePickerAndRestoreFocus() }
        if !rootView.recentFilesOverlay.isHidden { dismissRecentFilesOverlayAndRestoreFocus() }
        if !rootView.linkIndicatorPickerOverlay.isHidden { cancelLinkIndicatorPickerAndRestoreFocus() }
        if !rootView.updateInstructionsOverlay.isHidden { dismissUpdateInstructionsAndRestoreFocus() }
        dismissLinkHintsAndRestoreFocus()
        preservesTransientInputContext = false
        if restoringContext { restoreTransientInputContext() }
    }

    func presentRecentFilesOpen() {
        presentRecentFilesOverlay()
    }

    func presentRecentFilesOverlay() {
        dismissAllTransientOverlays(restoringContext: false)
        beginTransientOverlay()
        rootView.recentFilesOverlay.onBrowse = { [weak self] in
            guard let self else { return }
            self.dismissRecentFilesOverlayAndRestoreFocus()
            self.browseHandler()
        }
        rootView.recentFilesOverlay.onOpenRecent = { [weak self] path in
            guard let self else { return }
            switch PathExistenceCheck.classify(path) {
            case .regularFile:
                self.dismissRecentFilesOverlayAndRestoreFocus()
                self.recentOpenHandler(path)
            case .missing:
                switch self.recentPruneHandler(path) {
                case .persisted:
                    self.rootView.recentFilesOverlay.showInlineError("File not found: \(URL(fileURLWithPath: path).lastPathComponent)")
                    self.rootView.recentFilesOverlay.refresh(entries: self.recentFilesProvider())
                case .rejected:
                    self.rootView.recentFilesOverlay.showInlineError("Couldn't update the list: unsupported file type")
                case let .failed(message):
                    self.rootView.recentFilesOverlay.showInlineError("Couldn't update the list: \(message)")
                }
            case let .notAFile(reason):
                self.rootView.recentFilesOverlay.showInlineError(reason)
            }
        }
        rootView.recentFilesOverlay.onClear = { [weak self] in
            guard let self else { return }
            switch self.recentClearHandler() {
            case .persisted:
                self.rootView.recentFilesOverlay.refresh(entries: self.recentFilesProvider())
                self.rootView.recentFilesOverlay.clearInlineError()
            case .rejected:
                self.rootView.recentFilesOverlay.showInlineError("Couldn't update the list: unsupported file type")
            case let .failed(message):
                self.rootView.recentFilesOverlay.showInlineError("Couldn't update the list: \(message)")
            }
        }
        rootView.recentFilesOverlay.onCancel = { [weak self] in self?.dismissRecentFilesOverlayAndRestoreFocus() }
        rootView.recentFilesOverlay.present(entries: recentFilesProvider())
        window?.makeFirstResponder(rootView.recentFilesOverlay)
    }

    private func dismissRecentFilesOverlayAndRestoreFocus() {
        rootView.recentFilesOverlay.dismiss()
        rootView.recentFilesOverlay.onBrowse = nil
        rootView.recentFilesOverlay.onOpenRecent = nil
        rootView.recentFilesOverlay.onCancel = nil
        focusActiveSurface(snapshot: coordinator.snapshot)
        restoreTransientInputContext()
        rootView.recentFilesOverlay.onClear = nil
    }

    func presentHelp() {
        dismissAllTransientOverlays(restoringContext: false)
        beginTransientOverlay()
        let sections = Self.helpSections(from: resolvedConfig.keymap)
        rootView.helpOverlay.onDismiss = { [weak self] in self?.dismissHelpOverlayAndRestoreFocus() }
        rootView.helpOverlay.present(sections: sections)
        window?.makeFirstResponder(rootView.helpOverlay)
    }

    private func dismissHelpOverlayAndRestoreFocus() {
        rootView.helpOverlay.dismiss()
        rootView.helpOverlay.onDismiss = nil
        restoreTransientInputContext()
        if !rootView.promptOverlay.isHidden {
            window?.makeFirstResponder(rootView.promptOverlay.textField)
            rootView.promptOverlay.setFocusAppearance(true)
        } else {
            focusActiveSurface(snapshot: coordinator.snapshot)
        }
    }

    private func paletteContextState() -> PaletteContextState {
        let snapshot = coordinator.snapshot
        let history = coordinator.activeSession
        return PaletteContextState(
            hasActiveDocument: coordinator.activeSession != nil,
            paneCount: snapshot.layout.paneIDs.count,
            tabCount: snapshot.tabs.count,
            inSearchResults: (savedTransientInputContexts.last ?? inputRouter.context) == .searchResults,
            configFileExists: FileManager.default.fileExists(atPath: configFileURLProvider().path),
            savedInputContext: savedTransientInputContexts.last ?? inputRouter.context,
            canGoBack: history?.canGoBack ?? false,
            canGoForward: history?.canGoForward ?? false,
            isNavigationHistoryHealthy: history?.isNavigationHistoryHealthy ?? false,
            hasAvailableUpdate: availableUpdate != nil
        )
    }

    func presentCommandPalette() {
        dismissAllTransientOverlays(restoringContext: false)
        beginTransientOverlay()
        guard rootView.commandPaletteOverlay.isHidden else { return }
        let state = paletteContextState()
        let commands = ActionRegistry.v1.userConfigurableDescriptors
            .filter { $0.id != .paletteOpen }
            .map { descriptor -> PaletteCommand in
                let availability = PaletteAvailability.evaluate(descriptor.id, state: state)
                return PaletteCommand(
                    id: descriptor.id,
                    title: descriptor.title,
                    shortcut: resolvedConfig.keymap.bindings(for: descriptor.id).first.flatMap { KeyBindingHint.text(for: $0) },
                    isEnabled: availability.enabled,
                    disabledReason: availability.reason
                )
            }
        rootView.commandPaletteOverlay.onCommit = { [weak self] id in
            guard let self,
                  PaletteAvailability.evaluate(id, state: self.paletteContextState()).enabled
            else { return }
            self.dismissCommandPaletteAndRestoreFocus()
            self.actionHandler(id)
        }
        rootView.commandPaletteOverlay.onCancel = { [weak self] in self?.dismissCommandPaletteAndRestoreFocus() }
        rootView.commandPaletteOverlay.present(commands: commands)
        window?.makeFirstResponder(rootView.commandPaletteOverlay)
    }

    private func dismissCommandPaletteAndRestoreFocus() {
        rootView.commandPaletteOverlay.dismiss()
        rootView.commandPaletteOverlay.onCommit = nil
        rootView.commandPaletteOverlay.onCancel = nil
        restoreTransientInputContext()
        focusActiveSurface(snapshot: coordinator.snapshot)
    }

    func apply(theme: AppKitTheme) {
        window?.backgroundColor = theme[.background]
        rootView.apply(theme: theme)
    }

    func applyConfig(_ config: ValidatedAppConfig) {
        rootView.cancelPendingTOCInput()
        resolvedConfig = config
        inputRouter.reconfigure(config: config)
        dismissLinkHintsAndRestoreFocus()
        rootView.emptyState.setOpenBinding(config.keymap.bindings(for: .documentOpen).first)
        applyTOCKeyHints(config.keymap)
    }

    var hasPinnedDiagnostic: Bool { rootView.hasPinnedDiagnostic }
    func showDiagnostic(_ message: String, expandedDetail: String? = nil, isError: Bool = true, pinned: Bool = false) {
        rootView.showDiagnostic(message, expandedDetail: expandedDetail, isError: isError, pinned: pinned)
    }

    func clearDiagnostic(force: Bool = false) {
        rootView.clearDiagnostic(force: force)
    }


    func presentUpdateBanner(_ text: String, onClick: @escaping () -> Void) {
        rootView.presentUpdateBanner(text, onClick: onClick)
    }

    func installAvailableUpdate(_ update: AvailableUpdate) {
        availableUpdate = update
        renderUpdateBanner()
    }
    func presentAvailableUpdate() {
        guard let availableUpdate else { return }
        dismissAllTransientOverlays(restoringContext: false)
        beginTransientOverlay()
        rootView.updateInstructionsOverlay.onCancel = { [weak self] in
            self?.dismissUpdateInstructionsAndRestoreFocus()
        }
        rootView.updateInstructionsOverlay.present(update: availableUpdate)
        rebuildKeyViewLoop(snapshot: coordinator.snapshot)
        window?.makeFirstResponder(rootView.updateInstructionsOverlay)
    }

    private func dismissUpdateInstructionsAndRestoreFocus() {
        guard !rootView.updateInstructionsOverlay.isHidden else { return }
        rootView.updateInstructionsOverlay.dismiss()
        rootView.updateInstructionsOverlay.onCancel = nil
        restoreTransientInputContext()
        rebuildKeyViewLoop(snapshot: coordinator.snapshot)
        if !rootView.promptOverlay.isHidden {
            window?.makeFirstResponder(rootView.promptOverlay.textField)
            rootView.promptOverlay.setFocusAppearance(true)
        } else {
            focusActiveSurface(snapshot: coordinator.snapshot)
        }
    }

    private func renderUpdateBanner() {
        guard let availableUpdate else { return }
        let shortcut = resolvedConfig.keymap.bindings(for: .updateShow).first
            .flatMap(KeyBindingHint.text(for:)) ?? "U"
        rootView.presentUpdateBanner("\u{2191} Modeleaf \(availableUpdate.version) available  [\(shortcut)]") { [weak self] in
            self?.presentAvailableUpdate()
        }
    }

    func presentPrompt(_ presentation: PromptPresentation) {
        rootView.cancelPendingTOCInput()
        let context: InputContext = presentation.kind == .page ? .pagePrompt : .searchPrompt
        inputRouter.synchronizeContext(context)
        rootView.setInputContext(context)
        rootView.promptOverlay.present(presentation)
        rebuildKeyViewLoop(snapshot: coordinator.snapshot)
        window?.makeFirstResponder(rootView.promptOverlay.textField)
    }

    func dismissPromptAndRestoreFocus() {
        dismissPromptAndRestoreFocus(to: .navigation, reason: .explicitCancel)
    }

    func dismissPromptAndRestoreFocus(reason: KeyInputInvalidationReason) {
        dismissPromptAndRestoreFocus(to: .navigation, reason: reason)
    }

    func dismissPromptAndRestoreFocus(
        to context: InputContext,
        reason: KeyInputInvalidationReason
    ) {
        rootView.promptOverlay.dismiss()
        if !savedTransientInputContexts.isEmpty, isTransientModalRoutingActive {
            savedTransientInputContexts[savedTransientInputContexts.count - 1] = context
        }
        inputRouter.synchronizeContext(context)
        inputRouter.invalidate(reason)
        rootView.setInputContext(context)
        rebuildKeyViewLoop(snapshot: coordinator.snapshot)
        focusActiveSurface(snapshot: coordinator.snapshot)
    }

    func showPromptValidation(_ message: String) {
        rootView.promptOverlay.showValidation(message)
        window?.makeFirstResponder(rootView.promptOverlay.textField)
        rootView.promptOverlay.setFocusAppearance(true)
    }

    func prepareForGlobalAction() {
        rootView.promptOverlay.discardMarkedComposition()
        dismissPromptAndRestoreFocus(
            to: coordinator.activeSession?.preferredInputContext ?? .navigation,
            reason: .explicitCancel
        )
    }

    var activePromptKind: ReaderPromptKind? { rootView.promptOverlay.activeKind }
    var activePromptText: String { rootView.promptOverlay.activeText }
    var inputContextForTesting: InputContext { inputRouter.context }

    func toggleTOCDrawer() {
        guard let paneID = coordinator.snapshot.activePaneID,
              let outline = coordinator.activeOutlineSnapshot
        else { return }
        rootView.toggleTOCWidget(in: paneID, snapshot: outline) { [weak self] rowID in
            guard let self else { return .unavailable }
            let outcome = self.coordinator.activateOutlineRow(id: rowID, in: paneID)
            if outcome == .verifiedLanding || outcome == .noOp { self.focusActiveSurface(snapshot: self.coordinator.snapshot) }
            return outcome
        }
        focusActiveSurface(snapshot: coordinator.snapshot)
    }

    func scrollTOCDrawerDown() { scrollTOCDrawer(byRows: 1) }
    func scrollTOCDrawerUp() { scrollTOCDrawer(byRows: -1) }

    private func scrollTOCDrawer(byRows direction: Int) {
        guard let paneID = coordinator.snapshot.activePaneID else { return }
        rootView.scrollTOCWidget(in: paneID, byRows: direction)
    }


    @discardableResult
    func routeKeyEventForTesting(_ event: NSEvent) -> Bool { routeKeyEvent(event) }

    @discardableResult
    private func routeKeyEvent(_ event: NSEvent) -> Bool {
        if !rootView.linkHintOverlay.isHidden, rootView.linkHintOverlay.handleKeyDown(event) { inputRouter.resetModalHistorySuppression(); return true }
        if !rootView.commandPaletteOverlay.isHidden, rootView.commandPaletteOverlay.handleKeyDown(event) { inputRouter.resetModalHistorySuppression(); return true }
        if !rootView.recentFilesOverlay.isHidden, rootView.recentFilesOverlay.handleKeyDown(event) { inputRouter.resetModalHistorySuppression(); return true }
        if !rootView.helpOverlay.isHidden, rootView.helpOverlay.handleKeyDown(event) { inputRouter.resetModalHistorySuppression(); return true }
        if !rootView.themePickerOverlay.isHidden, rootView.themePickerOverlay.handleKeyDown(event) { inputRouter.resetModalHistorySuppression(); return true }
        if !rootView.linkIndicatorPickerOverlay.isHidden, rootView.linkIndicatorPickerOverlay.handleKeyDown(event) { inputRouter.resetModalHistorySuppression(); return true }
        if !rootView.updateInstructionsOverlay.isHidden, rootView.updateInstructionsOverlay.handleKeyDown(event) { inputRouter.resetModalHistorySuppression(); return true }
        if isTransientModalRoutingActive {
            if inputRouter.handleHistoryWhileModal(event) { return true }
            return inputRouter.handle(event)
        }
        if let paneID = coordinator.snapshot.activePaneID,
           rootView.handleTOCKey(in: paneID, event: event) {
            return true
        }
        return inputRouter.handle(event)
    }

    private func handleKeyDispatch(_ dispatch: KeyActionDispatch, fallback: ((KeyActionDispatch) -> Void)?) {
        if suppressesDocumentKeyDispatch {
            guard ActionRegistry.v1.descriptor(for: dispatch.actionID)?.scope == .global else { return }
        }
        if let fallback { fallback(dispatch) } else { actionHandler(dispatch.actionID) }
    }

    private var isTransientModalRoutingActive: Bool {
        !rootView.commandPaletteOverlay.isHidden || !rootView.recentFilesOverlay.isHidden ||
            !rootView.helpOverlay.isHidden || !rootView.themePickerOverlay.isHidden ||
            !rootView.linkIndicatorPickerOverlay.isHidden || !rootView.updateInstructionsOverlay.isHidden ||
            !rootView.linkHintOverlay.isHidden || !rootView.promptOverlay.isHidden
    }

    private var suppressesDocumentKeyDispatch: Bool {
        !rootView.commandPaletteOverlay.isHidden || !rootView.recentFilesOverlay.isHidden ||
            !rootView.helpOverlay.isHidden || !rootView.themePickerOverlay.isHidden ||
            !rootView.linkIndicatorPickerOverlay.isHidden || !rootView.updateInstructionsOverlay.isHidden ||
            !rootView.linkHintOverlay.isHidden
    }

    private func beginTransientOverlay() {
        rootView.cancelPendingTOCInput()
        savedTransientInputContexts.append(inputRouter.context)
    }

    private func restoreTransientInputContext() {
        guard !savedTransientInputContexts.isEmpty else { return }
        let context = savedTransientInputContexts.removeLast()
        guard !preservesTransientInputContext, !isTransientModalRoutingActive else { return }
        inputRouter.synchronizeContext(context)
        inputRouter.invalidate(.explicitCancel)
        rootView.setInputContext(context)
    }
    func windowDidBecomeKey(_ notification: Notification) {
        if !rootView.updateInstructionsOverlay.isHidden {
            rootView.updateInstructionsOverlay.setFocusAppearance(true)
            window?.makeFirstResponder(rootView.updateInstructionsOverlay)
            return
        }
        if !rootView.commandPaletteOverlay.isHidden {
            window?.makeFirstResponder(rootView.commandPaletteOverlay)
            return
        }
        if !rootView.recentFilesOverlay.isHidden {
            window?.makeFirstResponder(rootView.recentFilesOverlay)
            return
        }
        if !rootView.helpOverlay.isHidden {
            window?.makeFirstResponder(rootView.helpOverlay)
            return
        }
        if !rootView.linkIndicatorPickerOverlay.isHidden {
            window?.makeFirstResponder(rootView.linkIndicatorPickerOverlay.initialFocusView)
            return
        }
        if !rootView.themePickerOverlay.isHidden {
            window?.makeFirstResponder(rootView.themePickerOverlay)
        } else if rootView.promptOverlay.isHidden {
            focusActiveSurface(snapshot: coordinator.snapshot)
        } else {
            window?.makeFirstResponder(rootView.promptOverlay.textField)
            rootView.promptOverlay.setFocusAppearance(true)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        rootView.cancelPendingTOCInput()
        dismissLinkHintsAndRestoreFocus()
        inputRouter.invalidate(.focusLost)
        if !rootView.linkIndicatorPickerOverlay.isHidden {
            rootView.linkIndicatorPickerOverlay.setFocusAppearance(false)
        } else if !rootView.updateInstructionsOverlay.isHidden {
            rootView.updateInstructionsOverlay.setFocusAppearance(false)
        } else if !rootView.themePickerOverlay.isHidden {
            rootView.themePickerOverlay.setFocusAppearance(false)
        } else {
            rootView.promptOverlay.setFocusAppearance(false)
        }
    }

    func windowDidResize(_ notification: Notification) {
        dismissLinkHintsAndRestoreFocus()
        (coordinator.activeSession as? ReaderSession)?.cancelDestinationIndicator()
    }

    private func refresh(snapshot: PaneCoordinatorSnapshot) {
        for (paneID, store) in snapshot.panes {
            if tocTabIDsByPane[paneID] != nil, tocTabIDsByPane[paneID] != store.activeID {
                rootView.closeTOCWidget(in: paneID)
            }
            tocTabIDsByPane[paneID] = store.activeID
        }
        tocTabIDsByPane = tocTabIDsByPane.filter { snapshot.panes[$0.key] != nil }
        if snapshot.activeID != lastActiveSessionID,
           let lastActiveSessionID,
           let previousSession = coordinator.session(for: lastActiveSessionID) as? ReaderSession {
            previousSession.cancelDestinationIndicator()
        }
        dismissLinkHintsAndRestoreFocus()
        let dismissStagedPrompt = promptCloseProjection.map {
            $0.layout == snapshot.layout && $0.paneID == snapshot.activePaneID && $0.tabID == snapshot.activeID
        } ?? false
        promptCloseProjection = nil
        defer {
            // Focus rings are first-responder driven, but PDFView moves first
            // responder to internal views; recompute every visible pane's ring
            // from the settled snapshot so a pane that lost focus indirectly
            // never keeps a stale ring (user review item 3-5).
            for view in snapshot.paneFocusViews.values {
                (view as? ReaderPDFView)?.refreshFocusAppearance()
            }
            (snapshot.activeFocusView as? ReaderPDFView)?.refreshFocusAppearance()
        }
        if snapshot.activeID != lastActiveSessionID || dismissStagedPrompt {
            let reason: KeyInputInvalidationReason = lastActiveSessionID != nil && snapshot.activeID == nil
                ? .sessionClosed
                : .sessionChanged
            if !rootView.promptOverlay.isHidden {
                rootView.promptOverlay.discardMarkedComposition()
                rootView.promptOverlay.dismiss()
            }
            let context = snapshot.inputContext
            inputRouter.synchronizeContext(context)
            inputRouter.invalidate(reason)
            rootView.setInputContext(context)
            lastActiveSessionID = snapshot.activeID
        }
        rootView.render(snapshot: snapshot)
        for paneID in snapshot.panes.keys {
            guard let outline = coordinator.store(for: paneID)?.activeOutlineSnapshot else { continue }
            rootView.renderTOCWidget(in: paneID, snapshot: outline) { [weak self] rowID in
                guard let self else { return .unavailable }
                let outcome = self.coordinator.activateOutlineRow(id: rowID, in: paneID)
                if outcome == .verifiedLanding || outcome == .noOp { self.focusActiveSurface(snapshot: self.coordinator.snapshot) }
                return outcome
            }
        }
        rebuildKeyViewLoop(snapshot: snapshot)
        window?.title = snapshot.windowTitle
        focusActiveSurface(snapshot: snapshot)
    }
    private func rebuildKeyViewLoop(snapshot: PaneCoordinatorSnapshot) {
        for view in installedKeyViewLoop {
            view.nextKeyView = nil
        }

        var views: [NSView] = []
        if let activeFocusView = snapshot.activeFocusView {
            views.append(activeFocusView)
            if !rootView.promptOverlay.isHidden {
                views.append(contentsOf: [
                    rootView.promptOverlay.textField,
                    rootView.promptOverlay.commitButton,
                    rootView.promptOverlay.cancelButton,
                ])
            }
            if snapshot.layout.isMultiPane, let paneID = snapshot.activePaneID {
                views.append(contentsOf: rootView.paneViewForTesting(paneID)?.orderedKeyViews ?? [])
            } else {
                views.append(contentsOf: rootView.tabBar.orderedKeyViews)
            }
        } else {
            views.append(rootView.emptyState.openButton)
        }

        installedKeyViewLoop = views
        guard let first = views.first else {
            window?.initialFirstResponder = nil
            return
        }
        for index in views.indices {
            views[index].nextKeyView = views[(index + 1) % views.count]
        }
        window?.initialFirstResponder = first
    }

    private func stageClose(_ projected: PaneCoordinatorSnapshot) -> Bool {
        guard let window else { return false }
        guard window.isVisible else { return true }
        let target = projected.activeFocusView ?? projected.activeContentView ?? rootView.emptyState.openButton
        guard rootView.promptOverlay.isHidden, window.attachedSheet == nil else {
            if !rootView.promptOverlay.isHidden {
                promptCloseProjection = (projected.layout, projected.activePaneID, projected.activeID)
            }
            return true
        }
        rootView.render(snapshot: projected, isCommitted: false)
        rebuildKeyViewLoop(snapshot: projected)
        guard target.acceptsFirstResponder,
              window.makeFirstResponder(target),
              window.firstResponder === target
        else { return false }
        return true
    }


    private func focusActiveSurface(snapshot: PaneCoordinatorSnapshot) {
        guard rootView.promptOverlay.isHidden else { return }
        if let focusView = snapshot.activeFocusView, focusView.acceptsFirstResponder {
            window?.makeFirstResponder(focusView)
        } else if snapshot.isEmpty {
            window?.makeFirstResponder(rootView.emptyState.openButton)
        }
    }
    private static func helpSections(from keymap: ValidatedKeymap) -> [HelpOverlaySection] {
        let tabSelectionIDs: [ActionID] = [
            .tabSelect1, .tabSelect2, .tabSelect3, .tabSelect4, .tabSelect5,
            .tabSelect6, .tabSelect7, .tabSelect8, .tabSelect9,
        ]
        let usesDefaultTabSelectionBindings = tabSelectionIDs.allSatisfy {
            keymap.bindings(for: $0) == BuiltInDefaults.keymap[$0, default: []]
        }
        var entriesByCategory: [(title: String, entries: [(keyText: String, commandTitle: String)])] = []

        func append(_ entry: (keyText: String, commandTitle: String), to title: String) {
            if entriesByCategory.last?.title != title {
                entriesByCategory.append((title, []))
            }
            entriesByCategory[entriesByCategory.count - 1].entries.append(entry)
        }

        for descriptor in ActionRegistry.v1.userConfigurableDescriptors {
            if tabSelectionIDs.contains(descriptor.id), usesDefaultTabSelectionBindings {
                if descriptor.id == .tabSelect1 {
                    append(("Cmd+1..9", "Select tab 1-9"), to: "Tabs")
                }
                continue
            }
            let hints = keymap.bindings(for: descriptor.id).compactMap(KeyBindingHint.text(for:))
            guard !hints.isEmpty else { continue }
            append((hints.joined(separator: ", "), descriptor.title), to: BuiltInDefaults.categoryTitle(for: descriptor.id))
        }
        let searchEntries = [
            ("Enter", "Next search match"),
            ("Shift+Enter", "Previous search match"),
        ]
        if let searchIndex = entriesByCategory.firstIndex(where: { $0.title == "Search" }) {
            entriesByCategory[searchIndex].entries += searchEntries
        } else {
            entriesByCategory.append(("Search", searchEntries))
        }

        return entriesByCategory.map { HelpOverlaySection(title: $0.title, entries: $0.entries) }
    }

    private func dispatchTabSelection(to targetID: TabID) {
        let snapshot = coordinator.snapshot
        guard let activeID = snapshot.activeID,
              activeID != targetID,
              let activeIndex = snapshot.tabs.firstIndex(where: { $0.id == activeID }),
              let targetIndex = snapshot.tabs.firstIndex(where: { $0.id == targetID })
        else {
            return
        }

        let count = snapshot.tabs.count
        let forwardSteps = (targetIndex - activeIndex + count) % count
        let backwardSteps = (activeIndex - targetIndex + count) % count
        let action: ActionID = forwardSteps <= backwardSteps ? .tabNext : .tabPrevious
        let stepCount = min(forwardSteps, backwardSteps)
        for _ in 0..<stepCount { actionHandler(action) }
    }

    private func dispatchTabClose(_ targetID: TabID) {
        let originalActiveID = coordinator.snapshot.activeID
        guard coordinator.session(for: targetID) != nil else { return }
        dispatchTabSelection(to: targetID)
        guard coordinator.snapshot.activeID == targetID else { return }
        actionHandler(.documentClose)
        guard let originalActiveID, originalActiveID != targetID, coordinator.session(for: originalActiveID) != nil else { return }
        dispatchTabSelection(to: originalActiveID)
    }

    private func applyTOCKeyHints(_ keymap: ValidatedKeymap) {
        let down = keymap.bindings(for: .tocScrollDown).first.flatMap(KeyBindingHint.text(for:)) ?? ""
        let up = keymap.bindings(for: .tocScrollUp).first.flatMap(KeyBindingHint.text(for:)) ?? ""
        let toggle = keymap.bindings(for: .tocToggle).first.flatMap(KeyBindingHint.text(for:)) ?? ""
        rootView.setTOCKeyHints(scrollDown: down, scrollUp: up, toggle: toggle)
    }

    private static func builtInValidatedConfig() -> ValidatedAppConfig {
        guard let config = ConfigValidator.validate(SparseAppConfig()).validatedConfig else {
            preconditionFailure("built-in reader configuration must validate")
        }
        return config
    }

}
extension MainWindowController: ReaderWorkflowPresenting {}
