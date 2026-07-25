import AppKit
import PDFReaderCore

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let coordinator: PaneCoordinator
    private let actionHandler: (ActionID) -> Void
    private let inputRouter: ReaderInputRouter
    private var lastActiveSessionID: TabID?
    private let openPaneHandler: ((PaneID) -> Void)?
    private var installedKeyViewLoop: [NSView] = []
    let rootView: ReaderRootView

    init(
        coordinator: PaneCoordinator,
        theme: AppKitTheme,
        actionHandler: @escaping (ActionID) -> Void,
        keyDispatchHandler: ((KeyActionDispatch) -> Void)? = nil,
        validatedConfig: ValidatedAppConfig? = nil,
        openPaneHandler: ((PaneID) -> Void)? = nil,
    ) {
        self.coordinator = coordinator
        self.actionHandler = actionHandler
        self.openPaneHandler = openPaneHandler
        self.rootView = ReaderRootView(frame: NSRect(origin: .zero, size: WindowVisualMetrics.initialSize))
        let config = validatedConfig ?? Self.builtInValidatedConfig()
        self.inputRouter = ReaderInputRouter(
            config: config,
            pendingHandler: { [weak rootView] prefix in rootView?.setPendingPrefix(prefix) },
            dispatchHandler: keyDispatchHandler ?? { actionHandler($0.actionID) }
        )
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
        window.keyEventHandler = { [weak inputRouter] event in
            inputRouter?.handle(event) ?? false
        }
        window.delegate = self
        window.mouseDownHandler = { [weak self] event in
            self?.rootView.activatePane(atWindowPoint: event.locationInWindow)
        }
        rootView.apply(theme: theme)
        rootView.setInputContext(.navigation)
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

    func apply(theme: AppKitTheme) {
        window?.backgroundColor = theme[.background]
        rootView.apply(theme: theme)
    }

    func showDiagnostic(_ message: String, expandedDetail: String? = nil, isError: Bool = true) {
        rootView.showDiagnostic(message, expandedDetail: expandedDetail, isError: isError)
    }

    func clearDiagnostic() {
        rootView.clearDiagnostic()
    }

    func presentPrompt(_ presentation: PromptPresentation) {
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

    @discardableResult
    func routeKeyEventForTesting(_ event: NSEvent) -> Bool {
        inputRouter.handle(event)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if rootView.promptOverlay.isHidden {
            focusActiveSurface(snapshot: coordinator.snapshot)
        } else {
            window?.makeFirstResponder(rootView.promptOverlay.textField)
            rootView.promptOverlay.setFocusAppearance(true)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        inputRouter.invalidate(.focusLost)
        rootView.promptOverlay.setFocusAppearance(false)
    }

    private func refresh(snapshot: PaneCoordinatorSnapshot) {
        if snapshot.activeID != lastActiveSessionID {
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
            if case .split = snapshot.layout, let paneID = snapshot.activePaneID {
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
        guard rootView.promptOverlay.isHidden, window.attachedSheet == nil else { return true }
        rootView.render(snapshot: projected)
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
        for _ in 0..<stepCount {
            actionHandler(action)
        }
    }

    private func dispatchTabClose(_ targetID: TabID) {
        let originalActiveID = coordinator.snapshot.activeID
        guard coordinator.session(for: targetID) != nil else { return }

        dispatchTabSelection(to: targetID)
        guard coordinator.snapshot.activeID == targetID else { return }
        actionHandler(.documentClose)

        guard let originalActiveID,
              originalActiveID != targetID,
              coordinator.session(for: originalActiveID) != nil
        else {
            return
        }
        dispatchTabSelection(to: originalActiveID)
    }

    private static func builtInValidatedConfig() -> ValidatedAppConfig {
        guard let config = ConfigValidator.validate(SparseAppConfig()).validatedConfig else {
            preconditionFailure("built-in reader configuration must validate")
        }
        return config
    }
}

extension MainWindowController: ReaderWorkflowPresenting {}
