import AppKit

@MainActor
final class PaneContainerView: NSSplitView, NSSplitViewDelegate {
    private var hasInitializedDivider = false
    private var pendingDividerPosition: CGFloat?
    private var initializesDividerOnFirstLayout = false
    var onDividerMoved: ((CGFloat) -> Void)?
    var suppressDividerCapture = false

    init(orientation: PaneOrientation, accessibilityIdentifier: String) {
        super.init(frame: .zero)
        isVertical = orientation == .sideBySide
        dividerStyle = .thin
        autosaveName = ""
        delegate = self
        setAccessibilityIdentifier(accessibilityIdentifier)
    }

    required init?(coder: NSCoder) { nil }

    func install(leading: NSView, trailing: NSView, orientation: PaneOrientation, resetDivider: Bool, initializesDivider: Bool) {
        let vertical = orientation == .sideBySide
        let topologyChanged = isVertical != vertical || subviews.count != 2 || subviews[0] !== leading || subviews[1] !== trailing
        guard topologyChanged else { return }
        suppressDividerCapture = true
        defer { suppressDividerCapture = false }
        isVertical = vertical
        for view in subviews { view.removeFromSuperview() }
        // Children may arrive from a constraint-based host (ColumnHost) with
        // translatesAutoresizingMaskIntoConstraints disabled; this split view
        // lays out via autoresizing, so restore it or reparented panes keep
        // their stale fitting-size frames forever.
        for view in [leading, trailing] { view.translatesAutoresizingMaskIntoConstraints = true }
        addArrangedSubview(leading)
        addArrangedSubview(trailing)
        if resetDivider || (!hasInitializedDivider && initializesDivider) {
            pendingDividerPosition = nil
            initializesDividerOnFirstLayout = true
        }
        needsLayout = true
        // Synchronous layout keeps install semantics: freshly installed panes
        // receive real frames (and their controllers see viewDidLayout) before
        // the caller's render pass continues; the layout() override applies
        // any pending divider position at final-geometry time within the pass.
        layoutSubtreeIfNeeded()
    }

    func removeAllPanes() { for view in subviews { removeArrangedSubview(view) } }

    var currentDividerPosition: CGFloat {
        guard subviews.count == 2 else { return 0 }
        return isVertical ? subviews[0].frame.width : subviews[0].frame.height
    }

    /// Records the desired position and defers application to `layout()`.
    /// Applying eagerly against pre-layout bounds lets subsequent autolayout
    /// passes proportionally rescale the transient position, so the divider
    /// is only ever positioned once geometry is final for a layout pass.
    func applyDividerPosition(_ position: CGFloat) {
        guard subviews.count == 2 else { return }
        pendingDividerPosition = position
        initializesDividerOnFirstLayout = false
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() { super.layout(); applyPendingDividerIfPossible() }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if pendingDividerPosition != nil || initializesDividerOnFirstLayout { needsLayout = true }
    }

    private func applyPendingDividerIfPossible() {
        guard subviews.count == 2 else { return }
        let available = isVertical ? bounds.width : bounds.height
        guard available > dividerThickness + 2 * WindowVisualMetrics.minimumPaneThickness else { return }
        let position: CGFloat
        if let pendingDividerPosition { position = pendingDividerPosition; self.pendingDividerPosition = nil }
        else if initializesDividerOnFirstLayout { position = defaultDividerPosition; initializesDividerOnFirstLayout = false }
        else { return }
        suppressDividerCapture = true
        setPosition(position, ofDividerAt: 0)
        suppressDividerCapture = false
        hasInitializedDivider = true
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // While an application is pending, resizes are re-install/layout
        // transients, never user drags; capturing them would corrupt the
        // topology-owned saved position before it can be re-applied.
        guard !suppressDividerCapture, subviews.count == 2,
              pendingDividerPosition == nil, !initializesDividerOnFirstLayout else { return }
        onDividerMoved?(currentDividerPosition)
    }

    private var defaultDividerPosition: CGFloat {
        let available = isVertical ? bounds.width : bounds.height
        let minimum = WindowVisualMetrics.minimumPaneThickness
        let maximum = max(minimum, available - dividerThickness - minimum)
        return min(maximum, max(minimum, (available - dividerThickness) / 2))
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { WindowVisualMetrics.minimumPaneThickness }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let thickness = isVertical ? bounds.width : bounds.height
        return max(WindowVisualMetrics.minimumPaneThickness, thickness - dividerThickness - WindowVisualMetrics.minimumPaneThickness)
    }
}
