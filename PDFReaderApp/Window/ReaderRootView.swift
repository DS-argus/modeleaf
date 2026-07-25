import AppKit
import PDFReaderCore

@MainActor
private final class ColumnHost: NSView {
    private weak var child: NSView?
    func install(_ view: NSView) {
        guard child !== view else { return }
        child?.removeFromSuperview()
        child = view
        view.prepareForAutoLayout()
        addSubview(view)
        NSLayoutConstraint.activate([view.topAnchor.constraint(equalTo: topAnchor), view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
}

@MainActor
final class ReaderRootView: NSView {
    let tabBar = TabBarView()
    let emptyState = EmptyStateView()
    let statusBar = StatusBarView()
    let promptOverlay = PromptOverlayView()
    private let contentHost = NSView()
    private let paneContainer = PaneContainerView(orientation: .sideBySide)
    private let leadingColumnHost = ColumnHost()
    private let trailingColumnHost = ColumnHost()
    private let leadingStackContainer = PaneContainerView(orientation: .stacked)
    private let trailingStackContainer = PaneContainerView(orientation: .stacked)
    private var paneViews: [PaneID: PaneView] = [:]
    private var theme: AppKitTheme?
    private var tabBarHeightConstraint: NSLayoutConstraint!
    private weak var presentedContentView: NSView?
    private var currentStatus = StatusBarPresentation.empty
    private var readerInputContext: InputContext?
    var onPaneSelect: ((PaneID, TabID) -> Void)?
    var onPaneClose: ((PaneID, TabID) -> Void)?
    var onPaneNewTab: ((PaneID) -> Void)?
    private var renderedSessionSnapshot: ReaderSessionStoreSnapshot?
    var onPaneActivate: ((PaneID) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); wantsLayer = true; setAccessibilityIdentifier("readerRoot")
        for view in [tabBar, contentHost, statusBar, promptOverlay] { view.prepareForAutoLayout(); addSubview(view) }
        emptyState.prepareForAutoLayout(); contentHost.addSubview(emptyState)
        paneContainer.prepareForAutoLayout(); contentHost.addSubview(paneContainer)
        NSLayoutConstraint.activate([
            paneContainer.topAnchor.constraint(equalTo: contentHost.topAnchor), paneContainer.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor), paneContainer.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor), paneContainer.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
        paneContainer.isHidden = true
        tabBarHeightConstraint = tabBar.heightAnchor.constraint(equalToConstant: 0)
        let preferredPromptWidth = promptOverlay.widthAnchor.constraint(equalToConstant: WindowVisualMetrics.promptPreferredWidth); preferredPromptWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor), tabBar.leadingAnchor.constraint(equalTo: leadingAnchor), tabBar.trailingAnchor.constraint(equalTo: trailingAnchor), tabBarHeightConstraint,
            contentHost.topAnchor.constraint(equalTo: tabBar.bottomAnchor), contentHost.leadingAnchor.constraint(equalTo: leadingAnchor), contentHost.trailingAnchor.constraint(equalTo: trailingAnchor), contentHost.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            emptyState.topAnchor.constraint(equalTo: contentHost.topAnchor), emptyState.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor), emptyState.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor), emptyState.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor), statusBar.trailingAnchor.constraint(equalTo: trailingAnchor), statusBar.bottomAnchor.constraint(equalTo: bottomAnchor), statusBar.heightAnchor.constraint(equalToConstant: WindowVisualMetrics.statusBarHeight),
            promptOverlay.centerXAnchor.constraint(equalTo: contentHost.centerXAnchor), promptOverlay.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor, constant: -16), promptOverlay.heightAnchor.constraint(equalToConstant: WindowVisualMetrics.promptHeight), preferredPromptWidth, promptOverlay.widthAnchor.constraint(lessThanOrEqualToConstant: WindowVisualMetrics.promptMaximumWidth), promptOverlay.widthAnchor.constraint(greaterThanOrEqualToConstant: 360), promptOverlay.leadingAnchor.constraint(greaterThanOrEqualTo: contentHost.leadingAnchor, constant: 40), promptOverlay.trailingAnchor.constraint(lessThanOrEqualTo: contentHost.trailingAnchor, constant: -40),
        ])
    }
    required init?(coder: NSCoder) { nil }

    func apply(theme: AppKitTheme) { self.theme = theme; for pane in paneViews.values { pane.apply(theme: theme) }; layer?.backgroundColor = theme[.background].cgColor; contentHost.wantsLayer = true; contentHost.layer?.backgroundColor = theme[.background].cgColor; tabBar.apply(theme: theme); emptyState.apply(theme: theme); statusBar.apply(theme: theme); promptOverlay.apply(theme: theme) }

    func render(snapshot: ReaderSessionStoreSnapshot, activeContentView: NSView?, sessionStatus: ReaderStatusSnapshot?) {
        let hasTabs = !snapshot.tabs.isEmpty
        if renderedSessionSnapshot != snapshot { tabBar.render(snapshot); tabBarHeightConstraint.constant = hasTabs ? WindowVisualMetrics.tabBarHeight : 0; tabBar.isHidden = !hasTabs; emptyState.isHidden = hasTabs; renderedSessionSnapshot = snapshot }
        setPresentedContentView(activeContentView); renderStatus(sessionStatus)
    }

    func render(snapshot: PaneCoordinatorSnapshot, isCommitted: Bool = true) {
        if isCommitted { prunePaneViews(absentFrom: snapshot.panes) }
        guard snapshot.layout.isMultiPane else {
            paneContainer.isHidden = true
            leadingColumnHost.removeFromSuperview()
            trailingColumnHost.removeFromSuperview()
            if isCommitted { paneContainer.removeAllPanes() }
            tabBar.isHidden = snapshot.isEmpty
            render(snapshot: snapshot.activeStoreSnapshot, activeContentView: snapshot.activeContentView, sessionStatus: snapshot.activeStatus)
            return
        }
        tabBar.isHidden = true; tabBarHeightConstraint.constant = 0; renderedSessionSnapshot = nil; emptyState.isHidden = true; paneContainer.isHidden = false
        switch snapshot.layout {
        case let .single(stack):
            paneContainer.isHidden = true
            leadingColumnHost.install(render(stack: stack, side: .leading, snapshot: snapshot))
            leadingColumnHost.prepareForAutoLayout()
            if leadingColumnHost.superview !== contentHost {
                contentHost.addSubview(leadingColumnHost)
                NSLayoutConstraint.activate([
                    leadingColumnHost.topAnchor.constraint(equalTo: contentHost.topAnchor),
                    leadingColumnHost.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                    leadingColumnHost.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
                    leadingColumnHost.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
                ])
            }
        case let .split(leading, trailing):
            leadingColumnHost.removeFromSuperview()
            leadingColumnHost.install(render(stack: leading, side: .leading, snapshot: snapshot))
            trailingColumnHost.install(render(stack: trailing, side: .trailing, snapshot: snapshot))
            paneContainer.install(leading: leadingColumnHost, trailing: trailingColumnHost, orientation: .sideBySide)
        case .empty: break
        }
        renderStatus(snapshot.activeStatus)
    }

    private func render(stack: PaneStack, side: PaneColumnSide, snapshot: PaneCoordinatorSnapshot) -> NSView {
        switch stack {
        case let .one(id):
            let pane = configurePane(id, snapshot: snapshot, label: side == .leading ? "Left" : "Right")
            return pane
        case let .two(top, bottom):
            let columnLabel = side == .leading ? "Left" : "Right"
            let isSplit: Bool
            if case .split = snapshot.layout { isSplit = true } else { isSplit = false }
            let topView = configurePane(top, snapshot: snapshot, label: isSplit ? "\(columnLabel) Top" : "Top")
            let bottomView = configurePane(bottom, snapshot: snapshot, label: isSplit ? "\(columnLabel) Bottom" : "Bottom")
            let container = side == .leading ? leadingStackContainer : trailingStackContainer
            container.install(leading: topView, trailing: bottomView, orientation: .stacked)
            return container
        }
    }

    private func configurePane(_ id: PaneID, snapshot: PaneCoordinatorSnapshot, label: String) -> PaneView {
        let pane = paneView(for: id, trafficLightInset: snapshot.layout.topLeftPaneID == id ? WindowVisualMetrics.trafficLightInset : 0)
        pane.setPositionLabel(label); pane.render(snapshot: snapshot.panes[id]!, contentView: snapshot.paneContentViews[id]); pane.setActive(snapshot.activePaneID == id); return pane
    }
    private func renderStatus(_ sessionStatus: ReaderStatusSnapshot?) { if let sessionStatus { currentStatus.context = readerInputContext.map(Self.statusLabel(for:)) ?? sessionStatus.context; currentStatus.page = sessionStatus.page; currentStatus.zoom = sessionStatus.zoom; currentStatus.detail = sessionStatus.detail; currentStatus.expandedDetail = nil; currentStatus.tone = .normal } else if currentStatus.tone != .error { currentStatus = .empty }; statusBar.render(currentStatus) }
    private func paneView(for id: PaneID, trafficLightInset: CGFloat) -> PaneView { if let pane = paneViews[id] { pane.setTrafficLightInset(trafficLightInset); return pane }; let pane = PaneView(id: id, trafficLightInset: trafficLightInset); if let theme { pane.apply(theme: theme) }; paneViews[id] = pane; pane.onSelect = { [weak self] tabID in self?.onPaneSelect?(id, tabID) }; pane.onClose = { [weak self] tabID in self?.onPaneClose?(id, tabID) }; pane.onActivate = { [weak self] in self?.onPaneActivate?(id) }; pane.onNewTab = { [weak self] in self?.onPaneNewTab?(id) }; return pane }
    private func prunePaneViews(absentFrom panes: [PaneID: ReaderSessionStoreSnapshot]) { for id in paneViews.keys.filter({ panes[$0] == nil }) { paneViews.removeValue(forKey: id)?.retire() } }
    func paneViewForTesting(_ id: PaneID) -> PaneView? { paneViews[id] }
    func activatePane(atWindowPoint point: NSPoint) { let localPoint = convert(point, from: nil); var view = hitTest(localPoint); while let candidate = view { if let pane = candidate as? PaneView { pane.activateForPointerEvent(); return }; view = candidate.superview } }
    func setInputContext(_ context: InputContext) { readerInputContext = context; currentStatus.context = Self.statusLabel(for: context); statusBar.render(currentStatus) }
    func showDiagnostic(_ message: String, expandedDetail: String? = nil, isError: Bool = true) { currentStatus.detail = message; currentStatus.expandedDetail = expandedDetail; currentStatus.tone = isError ? .error : .normal; statusBar.render(currentStatus) }
    func clearDiagnostic() { currentStatus.detail = ReaderStatusSnapshot.empty.detail; currentStatus.expandedDetail = nil; currentStatus.tone = .normal; statusBar.render(currentStatus) }
    func setPendingPrefix(_ prefix: String) { currentStatus.pendingPrefix = prefix; statusBar.render(currentStatus) }
    private func setPresentedContentView(_ view: NSView?) { if presentedContentView !== view { presentedContentView?.removeFromSuperview() }; presentedContentView = view; attachContentView(view, to: contentHost) }
    private static func statusLabel(for context: InputContext) -> String { switch context { case .navigation: "NORMAL"; case .pagePrompt: "PAGE"; case .searchPrompt, .searchResults: "SEARCH" } }
}
