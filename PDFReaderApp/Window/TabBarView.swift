import AppKit
import PDFReaderCore

private enum TabBarLayoutMetrics {
    static let regularTabWidth: CGFloat = 184
    static let compactInactiveTabWidth: CGFloat = 40
    static let minimumCompactActiveTabWidth: CGFloat = 120
    static let spacing: CGFloat = 5
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

    private func refreshAppearance() {
        guard let theme else { return }
        let background: NSColor
        if selected && paneIsActive {
            background = theme[.activeTab]
        } else if hovering {
            background = theme.hover
        } else {
            background = theme[.inactiveTab]
        }
        layer?.backgroundColor = background.cgColor
        if selected && paneIsActive {
            layer?.borderWidth = 1
            layer?.borderColor = theme[.accent].withAlphaComponent(0.48).cgColor
        } else if itemLayout == .compactInactive {
            layer?.borderWidth = 1
            layer?.borderColor = theme[.border]
                .withAlphaComponent(hovering ? 0.72 : 0.42)
                .cgColor
        } else {
            layer?.borderWidth = 0
            layer?.borderColor = NSColor.clear.cgColor
        }
        selectButton.contentTintColor = selected && paneIsActive ? theme[.foreground] : theme[.mutedText]
        closeButton.contentTintColor = selected && paneIsActive || hovering ? theme[.foreground] : theme[.mutedText]
        closeButton.alphaValue = selected && paneIsActive || hovering ? 0.92 : 0.48
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
        stackView.alignment = .centerY
        stackView.spacing = TabBarLayoutMetrics.spacing
        stackView.edgeInsets = NSEdgeInsets(
            top: 4,
            left: trafficLightInset,
            bottom: 4,
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

    override func layout() {
        super.layout()
        if updateAdaptiveLayout() {
            stackView.layoutSubtreeIfNeeded()
            scrollView.documentView?.layoutSubtreeIfNeeded()
        }
        guard let activeItemView else { return }
        scrollView.layoutSubtreeIfNeeded()
        activeItemView.scrollToVisible(activeItemView.bounds)
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
        if let paneIsActive {
            layer?.borderWidth = paneIsActive ? WindowVisualMetrics.focusIndicatorWidth : 0
            layer?.borderColor = paneIsActive ? theme.focusRing.cgColor : NSColor.clear.cgColor
        } else {
            layer?.borderWidth = 0
            layer?.borderColor = NSColor.clear.cgColor
        }
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
