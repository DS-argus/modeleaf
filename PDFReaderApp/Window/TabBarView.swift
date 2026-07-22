import AppKit
import PDFReaderCore

@MainActor
private final class TabItemView: NSView {
    let id: TabID
    private let selectButton = ClosureButton(title: "", target: nil, action: nil)
    private let closeButton = ClosureButton(title: "", target: nil, action: nil)
    private var trackingAreaReference: NSTrackingArea?
    private var active = false
    private var hovering = false
    private var theme: AppKitTheme?

    var onSelect: ((TabID) -> Void)?
    var onClose: ((TabID) -> Void)?
    fileprivate var orderedKeyViews: [NSView] { [selectButton, closeButton] }

    init(tab: ReaderTabSnapshot, index: Int, count: Int, active: Bool) {
        self.id = tab.id
        self.active = active
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = WindowVisualMetrics.compactCornerRadius

        selectButton.title = tab.title
        selectButton.isBordered = false
        selectButton.alignment = .left
        selectButton.lineBreakMode = .byTruncatingMiddle
        selectButton.font = .systemFont(ofSize: 12, weight: active ? .semibold : .regular)
        selectButton.state = active ? .on : .off
        selectButton.handler = { [weak self] in
            guard let self else { return }
            self.onSelect?(self.id)
        }
        selectButton.setAccessibilityRole(.radioButton)
        selectButton.setAccessibilityLabel("\(tab.title), tab \(index + 1) of \(count)")
        selectButton.setAccessibilityValue(active ? "selected" : "not selected")
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
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: WindowVisualMetrics.tabHeight),
            widthAnchor.constraint(equalToConstant: 184),
            selectButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            selectButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            selectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
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
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
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

    func apply(theme: AppKitTheme) {
        self.theme = theme
        refreshAppearance()
    }

    private func refreshAppearance() {
        guard let theme else { return }
        let background: NSColor
        if active {
            background = theme[.activeTab]
        } else if hovering {
            background = theme.hover
        } else {
            background = theme[.inactiveTab]
        }
        layer?.backgroundColor = background.cgColor
        layer?.borderWidth = active ? 1 : 0
        layer?.borderColor = theme[.accent].withAlphaComponent(0.48).cgColor
        selectButton.contentTintColor = active ? theme[.foreground] : theme[.mutedText]
        closeButton.contentTintColor = active || hovering ? theme[.foreground] : theme[.mutedText]
        closeButton.alphaValue = active || hovering ? 0.92 : 0.48
    }

    private static func identifierComponent(_ id: TabID) -> String {
        id.rawValue.uuidString.lowercased()
    }
}

@MainActor
final class TabBarView: NSView {
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private var itemViews: [TabItemView] = []
    private var theme: AppKitTheme?

    var onSelect: ((TabID) -> Void)?
    var onClose: ((TabID) -> Void)?
    var orderedKeyViews: [NSView] { itemViews.flatMap(\.orderedKeyViews) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Document tabs")
        setAccessibilityIdentifier("tabBar")

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 5
        stackView.edgeInsets = NSEdgeInsets(
            top: 4,
            left: WindowVisualMetrics.trafficLightInset,
            bottom: 4,
            right: 8
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
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func render(_ snapshot: ReaderSessionStoreSnapshot) {
        for item in itemViews {
            stackView.removeArrangedSubview(item)
            item.removeFromSuperview()
        }
        itemViews = snapshot.tabs.enumerated().map { index, tab in
            let item = TabItemView(
                tab: tab,
                index: index,
                count: snapshot.tabs.count,
                active: snapshot.activeID == tab.id
            )
            item.onSelect = { [weak self] id in self?.onSelect?(id) }
            item.onClose = { [weak self] id in self?.onClose?(id) }
            if let theme { item.apply(theme: theme) }
            stackView.addArrangedSubview(item)
            return item
        }
        setAccessibilityValue(snapshot.activeID.map { "\(snapshot.tabs.count) tabs, active \($0)" } ?? "No tabs")
    }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        layer?.backgroundColor = theme[.background].cgColor
        for item in itemViews { item.apply(theme: theme) }
    }
}
