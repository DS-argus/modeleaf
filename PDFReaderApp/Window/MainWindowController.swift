import AppKit
import PDFReaderCore

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private unowned let sessionStore: ReaderSessionStore
    private let actionHandler: (ActionID) -> Void
    private let inputRouter: ReaderInputRouter
    private var lastActiveSessionID: TabID?
    private var installedKeyViewLoop: [NSView] = []
    let rootView: ReaderRootView

    init(
        sessionStore: ReaderSessionStore,
        theme: AppKitTheme,
        actionHandler: @escaping (ActionID) -> Void,
        keyDispatchHandler: ((KeyActionDispatch) -> Void)? = nil,
        validatedConfig: ValidatedAppConfig? = nil
    ) {
        self.sessionStore = sessionStore
        self.actionHandler = actionHandler
        self.rootView = ReaderRootView(frame: NSRect(origin: .zero, size: WindowVisualMetrics.initialSize))
        let config = validatedConfig ?? Self.builtInValidatedConfig()
        self.inputRouter = ReaderInputRouter(
            config: config,
            pendingHandler: { [weak rootView] prefix in rootView?.setPendingPrefix(prefix) },
            dispatchHandler: keyDispatchHandler ?? { actionHandler($0.actionID) }
        )

        let window = ReaderWindow(
            contentRect: NSRect(origin: .zero, size: WindowVisualMetrics.initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "PDF Reader"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.autorecalculatesKeyViewLoop = false
        window.minSize = WindowVisualMetrics.minimumSize
        window.contentView = rootView
        window.setAccessibilityIdentifier("mainWindow")

        super.init(window: window)
        window.keyEventHandler = { [weak inputRouter] event in
            inputRouter?.handle(event) ?? false
        }
        window.delegate = self
        rootView.apply(theme: theme)
        rootView.setInputContext(.navigation)
        rootView.emptyState.openButton.handler = { [weak self] in self?.actionHandler(.documentOpen) }
        rootView.tabBar.onSelect = { [weak self] id in self?.dispatchTabSelection(to: id) }
        rootView.tabBar.onClose = { [weak self] id in self?.dispatchTabClose(id) }
        rootView.promptOverlay.commitButton.handler = { [weak self] in self?.actionHandler(.promptCommit) }
        rootView.promptOverlay.cancelButton.handler = { [weak self] in self?.actionHandler(.promptCancel) }
        sessionStore.onChange = { [weak self] _ in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        focusActiveSurface()
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
        rebuildKeyViewLoop()
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
        rebuildKeyViewLoop()
        focusActiveSurface()
    }

    func showPromptValidation(_ message: String) {
        rootView.promptOverlay.showValidation(message)
        window?.makeFirstResponder(rootView.promptOverlay.textField)
        rootView.promptOverlay.setFocusAppearance(true)
    }

    func prepareForGlobalAction() {
        rootView.promptOverlay.discardMarkedComposition()
        dismissPromptAndRestoreFocus(
            to: sessionStore.activeSession?.preferredInputContext ?? .navigation,
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
            focusActiveSurface()
        } else {
            window?.makeFirstResponder(rootView.promptOverlay.textField)
            rootView.promptOverlay.setFocusAppearance(true)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        inputRouter.invalidate(.focusLost)
        rootView.promptOverlay.setFocusAppearance(false)
    }

    private func refresh() {
        let snapshot = sessionStore.snapshot
        let active = sessionStore.activeSession
        if snapshot.activeID != lastActiveSessionID {
            let reason: KeyInputInvalidationReason = lastActiveSessionID != nil && snapshot.activeID == nil
                ? .sessionClosed
                : .sessionChanged
            if !rootView.promptOverlay.isHidden {
                rootView.promptOverlay.discardMarkedComposition()
                rootView.promptOverlay.dismiss()
            }
            let context = active?.preferredInputContext ?? .navigation
            inputRouter.synchronizeContext(context)
            inputRouter.invalidate(reason)
            rootView.setInputContext(context)
            lastActiveSessionID = snapshot.activeID
        }
        rootView.render(
            snapshot: snapshot,
            activeContentView: active?.contentView,
            sessionStatus: active?.statusSnapshot
        )
        rebuildKeyViewLoop()
        window?.title = active.map { "\($0.title) — PDF Reader" } ?? "PDF Reader"
        focusActiveSurface()
    }

    private func rebuildKeyViewLoop() {
        for view in installedKeyViewLoop {
            view.nextKeyView = nil
        }

        var views: [NSView] = []
        if let active = sessionStore.activeSession {
            views.append(active.focusView)
            if !rootView.promptOverlay.isHidden {
                views.append(contentsOf: [
                    rootView.promptOverlay.textField,
                    rootView.promptOverlay.commitButton,
                    rootView.promptOverlay.cancelButton,
                ])
            }
            views.append(contentsOf: rootView.tabBar.orderedKeyViews)
        } else {
            views.append(rootView.emptyState.openButton)
        }

        installedKeyViewLoop = views
        guard let first = views.first else {
            window?.initialFirstResponder = nil
            return
        }
        for (view, next) in zip(views, views.dropFirst() + [first]) {
            view.nextKeyView = next
        }
        window?.initialFirstResponder = first
    }

    private func focusActiveSurface() {
        guard rootView.promptOverlay.isHidden else { return }
        if let active = sessionStore.activeSession, active.focusView.acceptsFirstResponder {
            window?.makeFirstResponder(active.focusView)
        } else if sessionStore.snapshot.isEmpty {
            window?.makeFirstResponder(rootView.emptyState.openButton)
        }
    }

    private func dispatchTabSelection(to targetID: TabID) {
        let snapshot = sessionStore.snapshot
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
        let originalActiveID = sessionStore.snapshot.activeID
        guard sessionStore.session(for: targetID) != nil else { return }

        dispatchTabSelection(to: targetID)
        guard sessionStore.snapshot.activeID == targetID else { return }
        actionHandler(.documentClose)

        guard let originalActiveID,
              originalActiveID != targetID,
              sessionStore.session(for: originalActiveID) != nil
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
