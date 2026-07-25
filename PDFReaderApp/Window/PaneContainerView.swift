import AppKit

@MainActor
final class PaneContainerView: NSSplitView, NSSplitViewDelegate {
    private let minimumPaneThickness: CGFloat = 160
    private var hasInitializedDivider = false

    init(orientation: PaneOrientation) {
        super.init(frame: .zero)
        isVertical = orientation == .sideBySide
        dividerStyle = .thin
        autosaveName = ""
        delegate = self
        setAccessibilityIdentifier("paneContainer")
    }

    required init?(coder: NSCoder) { nil }

    func install(leading: NSView, trailing: NSView, orientation: PaneOrientation) {
        let vertical = orientation == .sideBySide
        guard isVertical != vertical || subviews.count != 2 || subviews[0] !== leading || subviews[1] !== trailing else { return }
        isVertical = vertical
        for view in subviews { view.removeFromSuperview() }
        addArrangedSubview(leading)
        addArrangedSubview(trailing)
        needsLayout = true
        layoutSubtreeIfNeeded()
        if !hasInitializedDivider {
            setPosition(defaultDividerPosition, ofDividerAt: 0)
            hasInitializedDivider = true
        }
    }

    func removeAllPanes() { for view in subviews { removeArrangedSubview(view) } }

    private var defaultDividerPosition: CGFloat {
        let available = isVertical ? bounds.width : bounds.height
        let maximum = max(minimumPaneThickness, available - dividerThickness - minimumPaneThickness)
        return min(maximum, max(minimumPaneThickness, (available - dividerThickness) / 2))
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { minimumPaneThickness }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let thickness = isVertical ? bounds.width : bounds.height
        return max(minimumPaneThickness, thickness - dividerThickness - minimumPaneThickness)
    }
}
