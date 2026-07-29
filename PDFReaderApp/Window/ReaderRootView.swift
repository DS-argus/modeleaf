import AppKit
import PDFReaderCore


enum ReaderActiveDiagnosticKind: Equatable {
    case error
    case informational
}

struct ReaderActiveDiagnostic: Equatable {
    let message: String
    let kind: ReaderActiveDiagnosticKind
    let pinned: Bool
    let expandedDetail: String?
}
@MainActor
private final class BandHost: NSView {
    private weak var child: NSView?
    func install(_ view: NSView) {
        guard child !== view else { return }
        // Only detach the previous child if it is still ours: the render pass
        // may already have reparented it into a stack container, and removing
        // it here would tear it back out of its new home.
        if let child, child.superview === self { child.removeFromSuperview() }
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
    let themePickerOverlay = ThemePickerOverlayView()
    let promptOverlay = PromptOverlayView()
    private var activeDiagnostic: ReaderActiveDiagnostic?
    let commandPaletteOverlay = CommandPaletteOverlayView()
    let recentFilesOverlay = RecentFilesOpenOverlayView()
    let helpOverlay = HelpOverlayView()
    private let contentHost = NSView()
    private let paneContainer = PaneContainerView(orientation: .sideBySide, accessibilityIdentifier: "paneContainer")
    private let leadingBandHost = BandHost()
    private let trailingBandHost = BandHost()
    private let leadingBandContainer = PaneContainerView(orientation: .stacked, accessibilityIdentifier: "paneContainer.leadingBand")
    private let trailingBandContainer = PaneContainerView(orientation: .stacked, accessibilityIdentifier: "paneContainer.trailingBand")
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
    /// Absolute divider positions owned by pane topology, keyed by the
    /// unordered pane pair owned by a split band's inner divider; captured
    /// only from committed renders or real user drags.
    private var innerDividerPositions: [Set<PaneID>: CGFloat] = [:]
    private var outerDividerPosition: (orientation: PaneOrientation, position: CGFloat)?
    private var capturesDividerPositions = true
    private var currentInnerPairsByBand: [PaneBandSide: Set<PaneID>] = [:]
    private var hadCommittedSplit = false
    private var committedLayout: PaneLayout?
    var onPaneActivate: ((PaneID) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); wantsLayer = true; setAccessibilityIdentifier("readerRoot")
        paneContainer.onDividerMoved = { [weak self] position in
            guard let self, self.capturesDividerPositions else { return }
            self.outerDividerPosition = (self.paneContainer.isVertical ? .sideBySide : .stacked, position)
        }
        leadingBandContainer.onDividerMoved = { [weak self] position in
            guard let self, self.capturesDividerPositions, let pair = self.currentInnerPairsByBand[.leading] else { return }
            self.innerDividerPositions[pair] = position
        }
        trailingBandContainer.onDividerMoved = { [weak self] position in
            guard let self, self.capturesDividerPositions, let pair = self.currentInnerPairsByBand[.trailing] else { return }
            self.innerDividerPositions[pair] = position
        }
        for view in [tabBar, contentHost, statusBar, promptOverlay, themePickerOverlay, commandPaletteOverlay, recentFilesOverlay, helpOverlay] { view.prepareForAutoLayout(); addSubview(view) }
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
            themePickerOverlay.centerXAnchor.constraint(equalTo: contentHost.centerXAnchor), themePickerOverlay.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor), themePickerOverlay.leadingAnchor.constraint(greaterThanOrEqualTo: contentHost.leadingAnchor, constant: 40), themePickerOverlay.trailingAnchor.constraint(lessThanOrEqualTo: contentHost.trailingAnchor, constant: -40),
            recentFilesOverlay.centerXAnchor.constraint(equalTo: contentHost.centerXAnchor), recentFilesOverlay.topAnchor.constraint(equalTo: contentHost.topAnchor, constant: 72), recentFilesOverlay.leadingAnchor.constraint(greaterThanOrEqualTo: contentHost.leadingAnchor, constant: 40), recentFilesOverlay.trailingAnchor.constraint(lessThanOrEqualTo: contentHost.trailingAnchor, constant: -40),
            recentFilesOverlay.bottomAnchor.constraint(lessThanOrEqualTo: contentHost.bottomAnchor, constant: -40),
            helpOverlay.centerXAnchor.constraint(equalTo: contentHost.centerXAnchor), helpOverlay.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor), helpOverlay.leadingAnchor.constraint(greaterThanOrEqualTo: contentHost.leadingAnchor, constant: 20), helpOverlay.trailingAnchor.constraint(lessThanOrEqualTo: contentHost.trailingAnchor, constant: -20), helpOverlay.topAnchor.constraint(greaterThanOrEqualTo: contentHost.topAnchor, constant: 16), helpOverlay.bottomAnchor.constraint(lessThanOrEqualTo: contentHost.bottomAnchor, constant: -16),
            commandPaletteOverlay.centerXAnchor.constraint(equalTo: contentHost.centerXAnchor), commandPaletteOverlay.topAnchor.constraint(equalTo: contentHost.topAnchor, constant: 72), commandPaletteOverlay.leadingAnchor.constraint(greaterThanOrEqualTo: contentHost.leadingAnchor, constant: 40), commandPaletteOverlay.trailingAnchor.constraint(lessThanOrEqualTo: contentHost.trailingAnchor, constant: -40),
            emptyState.topAnchor.constraint(equalTo: contentHost.topAnchor), emptyState.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor), emptyState.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor), emptyState.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor), statusBar.trailingAnchor.constraint(equalTo: trailingAnchor), statusBar.bottomAnchor.constraint(equalTo: bottomAnchor), statusBar.heightAnchor.constraint(equalToConstant: WindowVisualMetrics.statusBarHeight),
            promptOverlay.centerXAnchor.constraint(equalTo: contentHost.centerXAnchor), promptOverlay.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor, constant: -16), promptOverlay.heightAnchor.constraint(equalToConstant: WindowVisualMetrics.promptHeight), preferredPromptWidth, promptOverlay.widthAnchor.constraint(lessThanOrEqualToConstant: WindowVisualMetrics.promptMaximumWidth), promptOverlay.widthAnchor.constraint(greaterThanOrEqualToConstant: 360), promptOverlay.leadingAnchor.constraint(greaterThanOrEqualTo: contentHost.leadingAnchor, constant: 40), promptOverlay.trailingAnchor.constraint(lessThanOrEqualTo: contentHost.trailingAnchor, constant: -40),
        ])
    }
    required init?(coder: NSCoder) { nil }
    func apply(theme: AppKitTheme) { self.theme = theme; for pane in paneViews.values { pane.apply(theme: theme) }; layer?.backgroundColor = theme[.background].cgColor; contentHost.wantsLayer = true; contentHost.layer?.backgroundColor = theme[.background].cgColor; tabBar.apply(theme: theme); emptyState.apply(theme: theme); statusBar.apply(theme: theme); promptOverlay.apply(theme: theme); themePickerOverlay.apply(theme: theme); commandPaletteOverlay.apply(theme: theme); recentFilesOverlay.apply(theme: theme); helpOverlay.apply(theme: theme) }

    func render(snapshot: ReaderSessionStoreSnapshot, activeContentView: NSView?, sessionStatus: ReaderStatusSnapshot?) {
        let hasTabs = !snapshot.tabs.isEmpty
        if renderedSessionSnapshot != snapshot { tabBar.render(snapshot); tabBarHeightConstraint.constant = hasTabs ? WindowVisualMetrics.tabBarHeight : 0; tabBar.isHidden = !hasTabs; emptyState.isHidden = hasTabs; renderedSessionSnapshot = snapshot }
        setPresentedContentView(activeContentView); renderStatus(sessionStatus)
    }
    func render(snapshot: PaneCoordinatorSnapshot, isCommitted: Bool = true) {
        // Captures stay off for the whole render body: install/redistribution
        // layout storms must never overwrite topology-owned positions.
        capturesDividerPositions = false
        defer { capturesDividerPositions = isCommitted }
        if isCommitted { prunePaneViews(absentFrom: snapshot.panes) }
        guard snapshot.layout.isMultiPane else {
            paneContainer.isHidden = true
            leadingBandHost.removeFromSuperview()
            trailingBandHost.removeFromSuperview()
            if isCommitted {
                paneContainer.removeAllPanes()
                hadCommittedSplit = false
                outerDividerPosition = nil
                committedLayout = snapshot.layout
            }
            tabBar.isHidden = snapshot.isEmpty
            render(snapshot: snapshot.activeStoreSnapshot, activeContentView: snapshot.activeContentView, sessionStatus: snapshot.activeStatus)
            return
        }
        tabBar.isHidden = true
        tabBarHeightConstraint.constant = 0
        renderedSessionSnapshot = nil
        emptyState.isHidden = true
        paneContainer.isHidden = false
        switch snapshot.layout {
        case let .split(orientation, leading, trailing):
            leadingBandHost.removeFromSuperview()
            leadingBandHost.install(render(stack: leading, side: .leading, outerOrientation: orientation, snapshot: snapshot, isCommitted: isCommitted))
            trailingBandHost.install(render(stack: trailing, side: .trailing, outerOrientation: orientation, snapshot: snapshot, isCommitted: isCommitted))
            let desiredInnerPositions = [leadingBandContainer, trailingBandContainer].map { container -> CGFloat? in
                guard container.subviews.count == 2, !container.hasPendingDividerAdjustment else { return nil }
                return container.currentDividerPosition
            }
            let promotedPosition = isCommitted ? promotedInnerPosition(from: committedLayout, to: snapshot.layout) : nil
            if let promotedPosition { outerDividerPosition = (orientation, promotedPosition) }
            let isNewSplit = !hadCommittedSplit
            let axisChanged = outerDividerPosition?.orientation != orientation
            paneContainer.install(
                leading: leadingBandHost,
                trailing: trailingBandHost,
                orientation: orientation,
                resetDivider: isCommitted && (isNewSplit || (axisChanged && promotedPosition == nil)),
                initializesDivider: isCommitted
            )
            if let saved = outerDividerPosition, saved.orientation == orientation {
                paneContainer.applyDividerPosition(saved.position)
            }
            for (container, desired) in zip([leadingBandContainer, trailingBandContainer], desiredInnerPositions) {
                if let desired { container.applyDividerPosition(desired) }
            }
            if isCommitted {
                hadCommittedSplit = true
                committedLayout = snapshot.layout
            }
        case .empty, .single:
            preconditionFailure("multi-pane render requires a split layout: \(snapshot.layout)")
        }
        renderStatus(snapshot.activeStatus)
    }

    private func promotedInnerPosition(from oldLayout: PaneLayout?, to newLayout: PaneLayout) -> CGFloat? {
        guard case let .split(oldOrientation, oldLeading, oldTrailing) = oldLayout,
              case let .split(newOrientation, newLeading, newTrailing) = newLayout,
              newOrientation != oldOrientation else { return nil }
        let oldPair: Set<PaneID>?
        switch (oldLeading, oldTrailing) {
        case (.one, let .two(first, second)), (let .two(first, second), .one): oldPair = [first, second]
        default: oldPair = nil
        }
        guard let oldPair, Set(newLeading.paneIDs + newTrailing.paneIDs) == oldPair else { return nil }
        return innerDividerPositions[oldPair]
    }

    private func render(stack: PaneStack, side: PaneBandSide, outerOrientation: PaneOrientation, snapshot: PaneCoordinatorSnapshot, isCommitted: Bool) -> NSView {
        let bandLabel = outerOrientation == .stacked ? (side == .leading ? "Top" : "Bottom") : (side == .leading ? "Left" : "Right")
        switch stack {
        case let .one(id):
            if isCommitted { currentInnerPairsByBand[side] = nil }
            return configurePane(id, snapshot: snapshot, label: bandLabel)
        case let .two(first, second):
            let innerOrientation = outerOrientation.perpendicular
            let firstLabel = outerOrientation == .stacked ? "\(bandLabel) Left" : "\(bandLabel) Top"
            let secondLabel = outerOrientation == .stacked ? "\(bandLabel) Right" : "\(bandLabel) Bottom"
            let container = side == .leading ? leadingBandContainer : trailingBandContainer
            let pair: Set<PaneID> = [first, second]
            let isNewPair = innerDividerPositions[pair] == nil
            container.install(
                leading: configurePane(first, snapshot: snapshot, label: firstLabel),
                trailing: configurePane(second, snapshot: snapshot, label: secondLabel),
                orientation: innerOrientation,
                resetDivider: isCommitted && isNewPair,
                initializesDivider: isCommitted
            )
            if let saved = innerDividerPositions[pair] { container.applyDividerPosition(saved) }
            if isCommitted { currentInnerPairsByBand[side] = pair }
            return container
        }
    }
    private func renderStatus(_ sessionStatus: ReaderStatusSnapshot?) {
        if let sessionStatus {
            currentStatus.context = readerInputContext.map(Self.statusLabel(for:)) ?? sessionStatus.context
            currentStatus.page = sessionStatus.page
            currentStatus.zoom = sessionStatus.zoom
            if activeDiagnostic?.pinned != true {
                currentStatus.detail = sessionStatus.detail
                currentStatus.expandedDetail = nil
                currentStatus.tone = .normal
            }
        } else if activeDiagnostic?.pinned != true {
            currentStatus = .empty
        }
        statusBar.render(currentStatus)
    }
    private func configurePane(_ id: PaneID, snapshot: PaneCoordinatorSnapshot, label: String) -> PaneView {
        let pane = paneView(for: id, trafficLightInset: snapshot.layout.topLeftPaneID == id ? WindowVisualMetrics.trafficLightInset : 0)
        pane.setPositionLabel(label); pane.render(snapshot: snapshot.panes[id]!, contentView: snapshot.paneContentViews[id]); pane.setActive(snapshot.activePaneID == id); return pane
    }
    private func paneView(for id: PaneID, trafficLightInset: CGFloat) -> PaneView { if let pane = paneViews[id] { pane.setTrafficLightInset(trafficLightInset); return pane }; let pane = PaneView(id: id, trafficLightInset: trafficLightInset); if let theme { pane.apply(theme: theme) }; paneViews[id] = pane; pane.onSelect = { [weak self] tabID in self?.onPaneSelect?(id, tabID) }; pane.onClose = { [weak self] tabID in self?.onPaneClose?(id, tabID) }; pane.onActivate = { [weak self] in self?.onPaneActivate?(id) }; pane.onNewTab = { [weak self] in self?.onPaneNewTab?(id) }; return pane }

    private func prunePaneViews(absentFrom panes: [PaneID: ReaderSessionStoreSnapshot]) {
        for id in paneViews.keys.filter({ panes[$0] == nil }) { paneViews.removeValue(forKey: id)?.retire() }
        for pair in innerDividerPositions.keys where !pair.allSatisfy({ panes[$0] != nil }) {
            innerDividerPositions.removeValue(forKey: pair)
        }
    }
    var recentFilesOverlayIsWithinContentBoundsForTesting: Bool {
        contentHost.bounds.contains(contentHost.convert(recentFilesOverlay.bounds, from: recentFilesOverlay))
    }
    var helpOverlayIsWithinContentBoundsForTesting: Bool {
        contentHost.bounds.contains(contentHost.convert(helpOverlay.bounds, from: helpOverlay))
    }
    func paneViewForTesting(_ id: PaneID) -> PaneView? { paneViews[id] }
    func activatePane(atWindowPoint point: NSPoint) { let localPoint = convert(point, from: nil); var view = hitTest(localPoint); while let candidate = view { if let pane = candidate as? PaneView { pane.activateForPointerEvent(); return }; view = candidate.superview } }

    func showDiagnostic(_ message: String, expandedDetail: String? = nil, isError: Bool = true, pinned: Bool = false) {
        activeDiagnostic = ReaderActiveDiagnostic(message: message, kind: isError ? .error : .informational, pinned: pinned, expandedDetail: expandedDetail)
        currentStatus.detail = message
        currentStatus.expandedDetail = expandedDetail
        currentStatus.tone = isError ? .error : .normal
        statusBar.render(currentStatus)
    }
    func presentUpdateBanner(_ text: String?, onClick: (() -> Void)? = nil) { statusBar.onUpdateClicked = onClick; statusBar.presentUpdate(text) }
    func clearDiagnostic(force: Bool = false) {
        guard force || activeDiagnostic?.pinned != true else { return }
        activeDiagnostic = nil
        currentStatus.detail = ReaderStatusSnapshot.empty.detail
        currentStatus.expandedDetail = nil
        currentStatus.tone = .normal
        statusBar.render(currentStatus)
    }
    func setInputContext(_ context: InputContext) { readerInputContext = context; currentStatus.context = Self.statusLabel(for: context); statusBar.render(currentStatus) }
    func setPendingPrefix(_ prefix: String) { currentStatus.pendingPrefix = prefix; statusBar.render(currentStatus) }
    private func setPresentedContentView(_ view: NSView?) { if presentedContentView !== view { presentedContentView?.removeFromSuperview() }; presentedContentView = view; attachContentView(view, to: contentHost) }
    private static func statusLabel(for context: InputContext) -> String { switch context { case .navigation: "NORMAL"; case .pagePrompt: "PAGE"; case .searchPrompt, .searchResults: "SEARCH" } }
}
