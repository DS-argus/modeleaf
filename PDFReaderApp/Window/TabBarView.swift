import AppKit
import PDFReaderCore

private enum TabBarLayoutMetrics {
    static let regularTabWidth: CGFloat = 220
    static let compactInactiveTabWidth: CGFloat = 40
    static let minimumCompactActiveTabWidth: CGFloat = 120
    static let spacing: CGFloat = 0
    static let trailingInset: CGFloat = 8
}

private enum TabItemLayout: Equatable {
    case regular
    case compactActive(width: CGFloat)
    case compactInactive
}

@MainActor
private final class TabItemView: NSView {
    let id: TabID
    private let selectButton = ClosureButton(title: "", target: nil, action: nil)
    private let closeButton = ClosureButton(title: "", target: nil, action: nil)
    private let displayTitle: String
    private let index: Int
    private let count: Int
    private var widthConstraint: NSLayoutConstraint!
    private var selectLeadingConstraint: NSLayoutConstraint!
    private var selectTrailingConstraint: NSLayoutConstraint!
    private var closeTrailingConstraint: NSLayoutConstraint!
    private var trackingAreaReference: NSTrackingArea?
    private var itemLayout = TabItemLayout.regular
    private var selected = false
    private var paneIsActive = true
    private var hovering = false
    private var theme: AppKitTheme?

    var onSelect: ((TabID) -> Void)?
    var onClose: ((TabID) -> Void)?
    fileprivate var orderedKeyViews: [NSView] { [selectButton, closeButton] }
    override var mouseDownCanMoveWindow: Bool { false }

    init(tab: ReaderTabSnapshot, index: Int, count: Int, selected: Bool, paneIsActive: Bool) {
        self.id = tab.id
        self.displayTitle = Self.displayTitle(for: tab.title)
        self.index = index
        self.count = count
        self.selected = selected
        self.paneIsActive = paneIsActive
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = WindowVisualMetrics.compactCornerRadius
        layer?.masksToBounds = false

        selectButton.respondsToFirstMouse = true
        closeButton.respondsToFirstMouse = true
        selectButton.title = displayTitle
        selectButton.isBordered = false
        selectButton.alignment = .left
        selectButton.lineBreakMode = .byTruncatingTail
        selectButton.font = .systemFont(ofSize: 12, weight: selected && paneIsActive ? .semibold : .regular)
        selectButton.state = selected ? .on : .off
        selectButton.handler = { [weak self] in
            guard let self else { return }
            self.onSelect?(self.id)
        }
        selectButton.setAccessibilityRole(.radioButton)
        selectButton.setAccessibilityLabel("\(tab.title), tab \(index + 1) of \(count)")
        selectButton.setAccessibilityValue(selected ? "selected" : "not selected")
        selectButton.setAccessibilityIdentifier("tab.\(Self.identifierComponent(tab.id))")

        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        if closeButton.image == nil { closeButton.title = "×" }
        closeButton.handler = { [weak self] in
            guard let self else { return }
            self.onClose?(self.id)
        }
        closeButton.setAccessibilityLabel("Close \(tab.title)")
        closeButton.setAccessibilityIdentifier("tab.close.\(Self.identifierComponent(tab.id))")

        selectButton.prepareForAutoLayout()
        closeButton.prepareForAutoLayout()
        addSubview(selectButton)
        addSubview(closeButton)
        widthConstraint = widthAnchor.constraint(equalToConstant: TabBarLayoutMetrics.regularTabWidth)
        selectLeadingConstraint = selectButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        selectTrailingConstraint = selectButton.trailingAnchor.constraint(
            equalTo: closeButton.leadingAnchor,
            constant: -4
        )
        closeTrailingConstraint = closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: WindowVisualMetrics.tabHeight),
            widthConstraint,
            selectLeadingConstraint,
            selectTrailingConstraint,
            selectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeTrailingConstraint,
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refreshAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refreshAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(id)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        refreshAppearance()
    }
    func setPaneActive(_ active: Bool) {
        guard paneIsActive != active else { return }
        paneIsActive = active
        selectButton.font = .systemFont(ofSize: 12, weight: selected && active ? .semibold : .regular)
        refreshAppearance()
    }

    @discardableResult
    func apply(itemLayout: TabItemLayout) -> Bool {
        guard self.itemLayout != itemLayout else { return false }
        self.itemLayout = itemLayout

        switch itemLayout {
        case .regular:
            widthConstraint.constant = TabBarLayoutMetrics.regularTabWidth
        selectButton.title = displayTitle
            selectLeadingConstraint.constant = 10
            selectTrailingConstraint.constant = -4
            closeTrailingConstraint.constant = -6
        case let .compactActive(width):
            widthConstraint.constant = width
            selectButton.title = "\(index + 1)/\(count)  \(displayTitle)"
            selectLeadingConstraint.constant = 10
            selectTrailingConstraint.constant = -4
            closeTrailingConstraint.constant = -6
        case .compactInactive:
            widthConstraint.constant = TabBarLayoutMetrics.compactInactiveTabWidth
            selectButton.title = ""
            selectLeadingConstraint.constant = 4
            selectTrailingConstraint.constant = -2
            closeTrailingConstraint.constant = -4
        }
        needsLayout = true
        refreshAppearance()
        return true
    }
    private var isActive: Bool { selected && paneIsActive }

    private func refreshAppearance() {
        guard let theme else { return }
        let active = isActive
        layer?.backgroundColor = active
            ? NSColor.clear.cgColor
            : (hovering ? theme.hover : theme[.inactiveTab]).cgColor
        if itemLayout == .compactInactive {
            layer?.borderWidth = 1
            layer?.borderColor = theme[.border]
                .withAlphaComponent(hovering ? 0.72 : 0.42)
                .cgColor
        } else {
            layer?.borderWidth = 0
            layer?.borderColor = NSColor.clear.cgColor
        }
        // The path owns the upper corners; a layer radius also clips the lower stroke ends.
        layer?.cornerRadius = active ? 0 : WindowVisualMetrics.compactCornerRadius
        selectButton.contentTintColor = active ? theme[.foreground] : theme[.mutedText]
        closeButton.contentTintColor = active || hovering ? theme[.foreground] : theme[.mutedText]
        closeButton.alphaValue = active || hovering ? 0.92 : 0.62
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let theme else { return }
        guard isActive else {
            theme[.border].withAlphaComponent(hovering ? 0.72 : 0.42).setStroke()
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY + 7))
            divider.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY - 7))
            divider.lineWidth = 1
            divider.stroke()
            return
        }

        let lineWidth = WindowVisualMetrics.canvasFocusRingWidth
        let inset = lineWidth / 2
        let radius = min(4, max(0, bounds.height / 2 - inset))
        let left = bounds.minX + inset
        let right = bounds.maxX - inset
        let bottom = bounds.minY
        let top = bounds.maxY - inset
        guard right > left, top > bottom else { return }

        let fill = NSBezierPath()
        fill.move(to: NSPoint(x: left, y: bottom))
        fill.line(to: NSPoint(x: left, y: top - radius))
        fill.curve(
            to: NSPoint(x: left + radius, y: top),
            controlPoint1: NSPoint(x: left, y: top - radius * 0.45),
            controlPoint2: NSPoint(x: left + radius * 0.45, y: top)
        )
        fill.line(to: NSPoint(x: right - radius, y: top))
        fill.curve(
            to: NSPoint(x: right, y: top - radius),
            controlPoint1: NSPoint(x: right - radius * 0.45, y: top),
            controlPoint2: NSPoint(x: right, y: top - radius * 0.45)
        )
        fill.line(to: NSPoint(x: right, y: bottom))
        fill.close()
        theme.canvasBackground.setFill()
        fill.fill()

        let stroke = NSBezierPath()
        stroke.move(to: NSPoint(x: left, y: bottom))
        stroke.line(to: NSPoint(x: left, y: top - radius))
        stroke.curve(
            to: NSPoint(x: left + radius, y: top),
            controlPoint1: NSPoint(x: left, y: top - radius * 0.45),
            controlPoint2: NSPoint(x: left + radius * 0.45, y: top)
        )
        stroke.line(to: NSPoint(x: right - radius, y: top))
        stroke.curve(
            to: NSPoint(x: right, y: top - radius),
            controlPoint1: NSPoint(x: right - radius * 0.45, y: top),
            controlPoint2: NSPoint(x: right, y: top - radius * 0.45)
        )
        stroke.line(to: NSPoint(x: right, y: bottom))
        stroke.lineWidth = lineWidth
        theme.focusRing.setStroke()
        stroke.stroke()
    }

    private static func identifierComponent(_ id: TabID) -> String {
        id.rawValue.uuidString.lowercased()
    }

    private static func displayTitle(for fullTitle: String) -> String {
        guard fullTitle.lowercased().hasSuffix(".pdf") else { return fullTitle }
        let title = String(fullTitle.dropLast(4))
        return title.isEmpty ? fullTitle : title
    }
}

@MainActor
final class TabBarView: NSView {
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    let newTabButton = ClosureButton(title: "", target: nil, action: nil)
    private var itemViews: [TabItemView] = []
    private weak var activeItemView: TabItemView?
    private var theme: AppKitTheme?
    private(set) var usesCompactLayout = false
    private var paneIsActive: Bool?

    var onSelect: ((TabID) -> Void)?
    var onClose: ((TabID) -> Void)?
    var onNewTab: (() -> Void)?
    var onActiveTabGeometryChange: (() -> Void)?
    var orderedKeyViews: [NSView] { itemViews.flatMap(\.orderedKeyViews) + [newTabButton] }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Pane-scoped accessibility namespace. When set, the tab bar and its
    /// new-tab control expose pane-qualified identifiers; single-pane windows
    /// keep the historical unscoped identifiers.
    var accessibilityScope: String? {
        didSet {
            guard accessibilityScope != oldValue else { return }
            applyAccessibilityIdentifiers()
        }
    }

    /// Leading inset reserving space for the window traffic lights. Only the
    /// pane occupying the window's top-left applies the reservation; other
    /// panes pass 0.
    var trafficLightInset: CGFloat = WindowVisualMetrics.trafficLightInset {
        didSet {
            guard trafficLightInset != oldValue else { return }
            stackView.edgeInsets.left = trafficLightInset
            needsLayout = true
        }
    }

    private func applyAccessibilityIdentifiers() {
        if let accessibilityScope {
            setAccessibilityIdentifier("\(accessibilityScope).tabBar")
            newTabButton.setAccessibilityIdentifier("\(accessibilityScope).tab.new")
        } else {
            setAccessibilityIdentifier("tabBar")
            newTabButton.setAccessibilityIdentifier("tab.new")
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Document tabs")
        setAccessibilityIdentifier("tabBar")

        stackView.orientation = .horizontal
        stackView.alignment = .bottom
        stackView.spacing = TabBarLayoutMetrics.spacing
        stackView.edgeInsets = NSEdgeInsets(
            top: WindowVisualMetrics.tabBarHeight - WindowVisualMetrics.tabHeight,
            left: trafficLightInset,
            bottom: 0,
            right: TabBarLayoutMetrics.trailingInset
        )
        stackView.prepareForAutoLayout()

        let documentView = NSView()
        documentView.prepareForAutoLayout()
        documentView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.heightAnchor.constraint(equalToConstant: WindowVisualMetrics.tabBarHeight),
        ])

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = documentView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(activeTabBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        newTabButton.respondsToFirstMouse = true
        scrollView.prepareForAutoLayout()
        newTabButton.isBordered = false
        newTabButton.imagePosition = .imageOnly
        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Open PDF in New Tab")
        if newTabButton.image == nil { newTabButton.title = "+" }
        newTabButton.toolTip = "Open PDF in New Tab"
        newTabButton.handler = { [weak self] in self?.onNewTab?() }
        newTabButton.setAccessibilityLabel("Open PDF in New Tab")
        newTabButton.setAccessibilityIdentifier("tab.new")
        newTabButton.prepareForAutoLayout()
        addSubview(scrollView)
        addSubview(newTabButton)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: newTabButton.leadingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            newTabButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newTabButton.widthAnchor.constraint(equalToConstant: 24),
            newTabButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func activeTabBoundsDidChange(_ notification: Notification) {
        onActiveTabGeometryChange?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = superview.map { convert(point, from: $0) } ?? point
        let clipPoint = scrollView.contentView.convert(localPoint, from: self)
        if scrollView.contentView.bounds.contains(clipPoint) {
            for item in itemViews.reversed() {
                let itemPoint = item.convert(localPoint, from: self)
                let hitTestPoint = item.superview?.convert(localPoint, from: self) ?? itemPoint
                if item.bounds.contains(itemPoint), let target = item.hitTest(hitTestPoint) {
                    return target
                }
            }
        }
        return super.hitTest(point)
    }

    func activeTabFrame(in view: NSView) -> NSRect? {
        guard let activeItemView else { return nil }
        let visibleRect = scrollView.contentView.convert(scrollView.contentView.bounds, to: self)
        let itemRect = activeItemView.convert(activeItemView.bounds, to: self)
        let clipped = itemRect.intersection(visibleRect).intersection(bounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        return convert(clipped, to: view)
    }

    var activeTabFrameForTesting: NSRect? { activeTabFrame(in: self) }


    override func layout() {
        super.layout()
        _ = updateAdaptiveLayout()
        stackView.layoutSubtreeIfNeeded()
        scrollView.documentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        if let activeItemView {
            activeItemView.scrollToVisible(activeItemView.bounds)
        }
        onActiveTabGeometryChange?()
    }

    func render(_ snapshot: ReaderSessionStoreSnapshot) {
        activeItemView = nil
        for item in itemViews {
            stackView.removeArrangedSubview(item)
            item.removeFromSuperview()
        }
        itemViews = snapshot.tabs.enumerated().map { index, tab in
            let item = TabItemView(
                tab: tab,
                index: index,
                count: snapshot.tabs.count,
                selected: snapshot.activeID == tab.id,
                paneIsActive: paneIsActive ?? true
            )
            item.onSelect = { [weak self] id in self?.onSelect?(id) }
            item.onClose = { [weak self] id in self?.onClose?(id) }
            if let theme { item.apply(theme: theme) }
            stackView.addArrangedSubview(item)
            if snapshot.activeID == tab.id {
                activeItemView = item
            }
            return item
        }
        if let activeID = snapshot.activeID,
           let activeIndex = snapshot.tabs.firstIndex(where: { $0.id == activeID })
        {
            setAccessibilityValue(
                "\(snapshot.tabs.count) tabs, active \(activeIndex + 1) of \(snapshot.tabs.count)"
            )
        } else {
            setAccessibilityValue("No tabs")
        }
        needsLayout = true
    }
    func setPaneActive(_ active: Bool) {
        guard paneIsActive != active else { return }
        paneIsActive = active
        refreshPaneAppearance()
        for item in itemViews { item.setPaneActive(active) }
    }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        refreshPaneAppearance()
        newTabButton.contentTintColor = theme[.mutedText]
        for item in itemViews { item.apply(theme: theme) }
    }

    private func refreshPaneAppearance() {
        guard let theme else { return }
        layer?.backgroundColor = theme.tabBarBackground.cgColor
        // No perimeter border: user review found the 2pt focus-ring outline
        // loud and clashing with the canvas ring. Active-pane distinction
        // lives in the per-tab styling (quieter selected tab on the inactive
        // pane) plus the canvas focus ring and accessibility value.
        layer?.borderWidth = 0
        layer?.borderColor = NSColor.clear.cgColor
    }

    @discardableResult
    private func updateAdaptiveLayout() -> Bool {
        guard !itemViews.isEmpty else {
            let changed = usesCompactLayout
            usesCompactLayout = false
            return changed
        }

        let tabCount = itemViews.count
        let spacingWidth = CGFloat(max(0, tabCount - 1)) * TabBarLayoutMetrics.spacing
        let regularContentWidth = trafficLightInset
            + TabBarLayoutMetrics.trailingInset
            + CGFloat(tabCount) * TabBarLayoutMetrics.regularTabWidth
            + spacingWidth
        let availableWidth = scrollView.contentView.bounds.width
        let shouldCompact = regularContentWidth > availableWidth + 0.5
        var changed = usesCompactLayout != shouldCompact
        usesCompactLayout = shouldCompact

        guard shouldCompact, let activeItemView else {
            for item in itemViews {
                changed = item.apply(itemLayout: .regular) || changed
            }
            return changed
        }

        let inactiveCount = max(0, tabCount - 1)
        let fixedCompactWidth = trafficLightInset
            + TabBarLayoutMetrics.trailingInset
            + CGFloat(inactiveCount) * TabBarLayoutMetrics.compactInactiveTabWidth
            + spacingWidth
        let activeWidth = min(
            TabBarLayoutMetrics.regularTabWidth,
            max(
                TabBarLayoutMetrics.minimumCompactActiveTabWidth,
                availableWidth - fixedCompactWidth
            )
        )

        for item in itemViews {
            let layout: TabItemLayout = item === activeItemView
                ? .compactActive(width: activeWidth)
                : .compactInactive
            changed = item.apply(itemLayout: layout) || changed
        }
        return changed
    }
}
