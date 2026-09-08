import AppKit

@MainActor
final class CitationPreviewOverlayView: NSView {
    private enum Metrics {
        static let preferredWidth: CGFloat = 520
        static let minimumWidth: CGFloat = 280
        static let edgeInset: CGFloat = 16
        static let cardGap: CGFloat = 10
        static let chromeHeight: CGFloat = 127
        static let minimumReferenceHeight: CGFloat = 20
    }

    var onCommit: ((CitationPreviewItem) -> Void)?
    var onSearch: ((CitationPreviewItem) -> Void)?
    var onDismiss: (() -> Void)?

    private let card = NSView()
    private let titleLabel = NSTextField(labelWithString: "Reference")
    private let separator = NSBox()
    private let tabs = NSStackView()
    private let referenceScrollView = NSScrollView()
    private let referenceTextView = NSTextView()
    private let keyHintLabel = NSTextField(labelWithString: "")
    private var referenceHeightConstraint: NSLayoutConstraint!
    private var cardLeadingConstraint: NSLayoutConstraint!
    private var cardBottomConstraint: NSLayoutConstraint!
    private var cardWidthConstraint: NSLayoutConstraint!
    private var cardHeightConstraint: NSLayoutConstraint!
    private var group: CitationPreviewGroup?
    private var selectedIndex = 0
    private var anchorRect = CGRect.zero
    private var tabViews: [CitationPreviewTabView] = []
    private var theme: AppKitTheme?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Citation reference preview")
        setAccessibilityIdentifier("citationPreviewOverlay")

        card.wantsLayer = true
        card.layer?.cornerRadius = WindowVisualMetrics.cornerRadius
        card.layer?.masksToBounds = false
        card.shadow = NSShadow()
        card.shadow?.shadowBlurRadius = 16
        card.shadow?.shadowOffset = NSSize(width: 0, height: -4)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.setAccessibilityIdentifier("citationPreview.title")

        separator.boxType = .separator
        separator.setAccessibilityIdentifier("citationPreview.separator")

        tabs.orientation = .horizontal
        tabs.alignment = .centerY
        tabs.spacing = 5
        tabs.distribution = .fillEqually

        referenceTextView.isEditable = false
        referenceTextView.isSelectable = true
        referenceTextView.drawsBackground = false
        referenceTextView.isRichText = false
        referenceTextView.isHorizontallyResizable = false
        referenceTextView.isVerticallyResizable = true
        referenceTextView.textContainerInset = .zero
        referenceTextView.font = .systemFont(ofSize: 13)
        referenceTextView.textContainer?.widthTracksTextView = true
        referenceTextView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        referenceTextView.setAccessibilityIdentifier("citationPreview.referenceText")

        referenceScrollView.borderType = .noBorder
        referenceScrollView.drawsBackground = false
        referenceScrollView.hasHorizontalScroller = false
        referenceScrollView.hasVerticalScroller = false
        referenceScrollView.autohidesScrollers = true
        referenceScrollView.documentView = referenceTextView
        referenceScrollView.prepareForAutoLayout()
        referenceHeightConstraint = referenceScrollView.heightAnchor.constraint(
            equalToConstant: Metrics.minimumReferenceHeight
        )
        referenceHeightConstraint.isActive = true

        keyHintLabel.font = .systemFont(ofSize: 11)
        keyHintLabel.lineBreakMode = .byTruncatingTail
        keyHintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keyHintLabel.setAccessibilityIdentifier("citationPreview.keyHint")

        for view in [titleLabel, separator, tabs, keyHintLabel] { view.prepareForAutoLayout() }
        for view in [titleLabel, separator, tabs, referenceScrollView, keyHintLabel] { card.addSubview(view) }
        card.prepareForAutoLayout()
        addSubview(card)
        cardLeadingConstraint = card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.edgeInset)
        cardBottomConstraint = card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.edgeInset)
        cardWidthConstraint = card.widthAnchor.constraint(equalToConstant: Metrics.preferredWidth)
        cardHeightConstraint = card.heightAnchor.constraint(equalToConstant: Metrics.chromeHeight + Metrics.minimumReferenceHeight)
        NSLayoutConstraint.activate([
            cardLeadingConstraint,
            cardBottomConstraint,
            cardWidthConstraint,
            cardHeightConstraint,
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            titleLabel.heightAnchor.constraint(equalToConstant: 16),
            separator.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            separator.heightAnchor.constraint(equalToConstant: 1),
            tabs.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 10),
            tabs.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            tabs.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            tabs.heightAnchor.constraint(equalToConstant: 26),
            referenceScrollView.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 10),
            referenceScrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            referenceScrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            keyHintLabel.topAnchor.constraint(equalTo: referenceScrollView.bottomAnchor, constant: 12),
            keyHintLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            keyHintLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            keyHintLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            keyHintLabel.heightAnchor.constraint(equalToConstant: 14),
        ])
        card.layoutSubtreeIfNeeded()
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        card.layer?.backgroundColor = theme[.activeTab].withAlphaComponent(0.96).cgColor
        card.layer?.borderColor = theme.focusRing.cgColor
        card.layer?.borderWidth = WindowVisualMetrics.focusIndicatorWidth
        card.shadow?.shadowColor = theme.overlayShadow
        titleLabel.textColor = theme[.accent]
        separator.borderColor = theme.separator
        referenceTextView.textColor = theme[.foreground]
        renderKeyHint()
        tabViews.forEach { $0.apply(theme: theme) }
    }

    func present(group: CitationPreviewGroup, anchorRect: CGRect) {
        guard !group.items.isEmpty, group.items.indices.contains(group.selectedIndex) else { return }
        self.group = group
        self.anchorRect = anchorRect
        selectedIndex = group.selectedIndex
        rebuildTabs()
        updateSelection()
        isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func dismiss() {
        group = nil
        tabViews.forEach { tabs.removeArrangedSubview($0); $0.removeFromSuperview() }
        tabViews = []
        titleLabel.stringValue = "Reference"
        referenceTextView.string = ""
        referenceScrollView.contentView.scroll(to: .zero)
        isHidden = true
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123:
            moveSelection(by: -1)
        case 124:
            moveSelection(by: 1)
        case 48:
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
            moveSelection(by: event.modifierFlags.contains(.shift) ? -1 : 1)
        case 36, 76:
            if event.modifierFlags.contains(.shift) { searchSelection() }
            else { commitSelection() }
        case 53:
            onDismiss?()
        default:
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let characters = event.charactersIgnoringModifiers?.lowercased()
            else { return false }
            switch characters {
            case "h": moveSelection(by: -1)
            case "l": moveSelection(by: 1)
            default: return false
            }
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !handleKeyDown(event) { super.keyDown(with: event) }
    }

    override func layout() {
        guard !isHidden else { super.layout(); return }
        let availableWidth = max(0, bounds.width - (Metrics.edgeInset * 2))
        let width = min(Metrics.preferredWidth, max(Metrics.minimumWidth, availableWidth))
        let maximumCardHeight = max(0, bounds.height - (Metrics.edgeInset * 2))
        let textWidth = max(1, width - 32)
        let desiredReferenceHeight = referenceTextHeight(for: textWidth)
        let maximumReferenceHeight = max(
            Metrics.minimumReferenceHeight,
            maximumCardHeight - Metrics.chromeHeight
        )
        let referenceHeight = min(desiredReferenceHeight, maximumReferenceHeight)
        referenceHeightConstraint.constant = referenceHeight
        referenceScrollView.hasVerticalScroller = desiredReferenceHeight > referenceHeight + 0.5
        referenceTextView.setFrameSize(NSSize(width: textWidth, height: desiredReferenceHeight))
        let height = min(maximumCardHeight, Metrics.chromeHeight + referenceHeight)
        let x = min(
            max(anchorRect.midX - width / 2, bounds.minX + Metrics.edgeInset),
            bounds.maxX - width - Metrics.edgeInset
        )
        let preferredAbove = anchorRect.maxY + Metrics.cardGap
        let y = preferredAbove + height <= bounds.maxY - Metrics.edgeInset
            ? preferredAbove
            : max(bounds.minY + Metrics.edgeInset, anchorRect.minY - height - Metrics.cardGap)
        cardLeadingConstraint.constant = x - bounds.minX
        cardBottomConstraint.constant = -(y - bounds.minY)
        cardWidthConstraint.constant = width
        cardHeightConstraint.constant = height
        super.layout()
        card.layoutSubtreeIfNeeded()
    }

    var selectedStateForTesting: CitationPreviewItemState? { selectedItem?.state }
    var selectedIsResolvedForTesting: Bool? { selectedItem?.isResolved }
    var visibleLabelsForTesting: [String] { group?.items.map(\.label) ?? [] }
    var selectedLabelForTesting: String? { selectedItem?.label }
    var referenceTextForTesting: String { referenceTextView.string }
    var referenceRequiresScrollingForTesting: Bool { referenceScrollView.hasVerticalScroller }
    var keyHintForTesting: NSAttributedString { keyHintLabel.attributedStringValue }
    var hasCallbacksForTesting: Bool { onCommit != nil || onSearch != nil || onDismiss != nil }
    var cardFrameForTesting: CGRect { card.frame }
    var referenceFollowsTabsForTesting: Bool {
        card.layoutSubtreeIfNeeded()
        let tabFrame = card.convert(tabs.bounds, from: tabs)
        let referenceFrame = card.convert(referenceScrollView.bounds, from: referenceScrollView)
        return tabFrame.minY - referenceFrame.maxY <= 12
    }
    func pointerEnterTabForTesting(at index: Int) { tabViews[index].pointerEnterForTesting() }
    var tabWidthsForTesting: [CGFloat] {
        card.layoutSubtreeIfNeeded()
        return tabViews.map { $0.frame.width }
    }
    func pointerActivateTabForTesting(at index: Int) { tabViews[index].pointerActivateForTesting() }

    func containsCard(atWindowPoint point: NSPoint) -> Bool {
        card.frame.contains(convert(point, from: nil))
    }

    private var selectedItem: CitationPreviewItem? {
        guard let group, group.items.indices.contains(selectedIndex) else { return nil }
        return group.items[selectedIndex]
    }

    private func rebuildTabs() {
        tabViews.forEach { tabs.removeArrangedSubview($0); $0.removeFromSuperview() }
        guard let group else { tabViews = []; return }
        tabViews = group.items.enumerated().map { index, item in
            let tab = CitationPreviewTabView(labelText: item.label, isResolved: item.isResolved)
            tab.onPointerEnter = { [weak self] in self?.select(index) }
            tab.onPointerActivate = { [weak self] in self?.select(index) }
            if let theme { tab.apply(theme: theme) }
            tabs.addArrangedSubview(tab)
            return tab
        }
    }

    private func moveSelection(by offset: Int) {
        guard let group else { return }
        let next = (selectedIndex + offset + group.items.count) % group.items.count
        select(next)
    }

    private func select(_ index: Int) {
        guard let group, group.items.indices.contains(index) else { return }
        selectedIndex = index
        updateSelection()
    }

    private func updateSelection() {
        guard let item = selectedItem else { return }
        for (index, tab) in tabViews.enumerated() { tab.isSelected = index == selectedIndex }
        titleLabel.stringValue = item.isResolved ? "Reference" : "Reference unavailable"
        referenceTextView.string = item.referenceText
        referenceTextView.setAccessibilityValue(
            item.isResolved ? item.referenceText : (item.unresolvedReason?.message ?? "Reference text could not be verified.")
        )
        setAccessibilityValue(
            "Reference \(item.label) of \(group?.items.count ?? 0)\(item.isResolved ? "" : " (unresolved)")"
        )
        referenceScrollView.contentView.scroll(to: .zero)
        needsLayout = true
    }

    private func commitSelection() {
        guard let item = selectedItem, item.isResolved else { return }
        onCommit?(item)
    }

    private func searchSelection() {
        guard let item = selectedItem, item.isResolved else { return }
        onSearch?(item)
    }

    private func referenceTextHeight(for width: CGFloat) -> CGFloat {
        let font = referenceTextView.font ?? .systemFont(ofSize: 13)
        let bounds = (referenceTextView.string as NSString).boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return max(Metrics.minimumReferenceHeight, ceil(bounds.height) + 2)
    }

    private func renderKeyHint() {
        guard let theme else {
            keyHintLabel.stringValue = "h/l ⇥/⇧⇥  Select    ↩  Move    ⇧↩  Scholar    Esc  Close"
            return
        }
        let result = NSMutableAttributedString()
        let shortcutAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: theme[.accent],
        ]
        let descriptionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: theme[.mutedText],
        ]
        for (shortcut, description) in [
            ("h/l ⇥/⇧⇥", "  Select    "),
            ("↩", "  Move    "),
            ("⇧↩", "  Scholar    "),
            ("Esc", "  Close"),
        ] {
            result.append(NSAttributedString(string: shortcut, attributes: shortcutAttributes))
            result.append(NSAttributedString(string: description, attributes: descriptionAttributes))
        }
        keyHintLabel.attributedStringValue = result
    }
}

@MainActor
private final class CitationPreviewTabView: PointerActionView {
    var isSelected = false { didSet { updateAppearance() } }
    private let label: NSTextField
    private let isResolved: Bool
    private var theme: AppKitTheme?

    init(labelText: String, isResolved: Bool = true) {
        self.label = NSTextField(labelWithString: labelText)
        self.isResolved = isResolved
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Reference \(labelText)")
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolTip = labelText
        label.prepareForAutoLayout()
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        updateAppearance()
    }

    private func updateAppearance() {
        guard let theme else { return }
        let enabled = isResolved
        label.textColor = isSelected && enabled
            ? theme[.background]
            : (enabled ? theme[.foreground] : theme[.mutedText])
        layer?.backgroundColor = (isSelected && enabled ? theme[.accent] : theme.separator).cgColor
        setAccessibilityValue(
            isSelected
                ? (enabled ? "Selected" : "Selected, unresolved")
                : (enabled ? "Not selected" : "Not selected, unresolved")
        )
    }
}
