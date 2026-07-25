import AppKit

@MainActor
final class PaneContainerView: NSSplitView, NSSplitViewDelegate {
    private let minimumPaneThickness: CGFloat = 160

    init(orientation: PaneOrientation) {
        super.init(frame: .zero)
        isVertical = orientation == .sideBySide
        dividerStyle = .thin
        autosaveName = ""
        delegate = self
        setAccessibilityIdentifier("paneContainer")
    }

    required init?(coder: NSCoder) { nil }

    func install(leadingOrTop: PaneView, trailingOrBottom: PaneView, orientation: PaneOrientation) {
        isVertical = orientation == .sideBySide
        for view in subviews { view.removeFromSuperview() }
        addSubview(leadingOrTop)
        addSubview(trailingOrBottom)
        needsLayout = true
        layoutSubtreeIfNeeded()
        setPosition(dividerPosition, ofDividerAt: 0)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard subviews.count == 2 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.subviews.count == 2 else { return }
            self.setPosition(self.dividerPosition, ofDividerAt: 0)
        }
    }

    private var dividerPosition: CGFloat {
        let available = isVertical ? bounds.width : bounds.height
        return max(minimumPaneThickness, (available - dividerThickness) / 2)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        minimumPaneThickness
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let thickness = isVertical ? bounds.width : bounds.height
        return max(minimumPaneThickness, thickness - dividerThickness - minimumPaneThickness)
    }
}
