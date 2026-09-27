import AppKit
import PDFReaderCore


/// One compact, immutable row supplied by the shortcut-settings coordinator.
struct ShortcutSettingsRow: Equatable, Sendable {
    let id: String
    let title: String
    let group: String
    let current: String?
    let defaultBinding: String?
    let additionalBindingCount: Int

    init(
        id: String,
        title: String,
        group: String,
        current: String?,
        defaultBinding: String?,
        additionalBindingCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.group = group
        self.current = current
        self.defaultBinding = defaultBinding
        self.additionalBindingCount = additionalBindingCount
    }
}

/// A standalone, keyboard-first list. Draft state, validation, capture and
/// persistence remain owned by the parent coordinator.
@MainActor
final class ShortcutSettingsOverlayView: NSView, NSSearchFieldDelegate {
    private static let prefixTimeoutRowID = "input.prefixTimeout"
    var onRecord: ((String) -> Void)?
    var onReset: ((String) -> Void)?
    var onApply: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onReload: (() -> Void)?
    var onClose: (() -> Void)?
    var onPrefixTimeoutChanged: ((String) -> Void)?
    var onRowSelected: ((String?) -> Void)?

    private enum Metrics {
        static let inset: CGFloat = 16
        static let preferredWidth: CGFloat = 680
        static let preferredHeight: CGFloat = 610
        static let headerHeight: CGFloat = 70
        static let footerHeight: CGFloat = 28
        static let rowHeight: CGFloat = 32
        static let groupHeight: CGFloat = 26
        static let minimumListHeight: CGFloat = 68
        static let hintHeight: CGFloat = 18
    }

    private let titleLabel = NSTextField(labelWithString: "Key Bindings")
    private let separator = NSBox()
    private let searchField = NSSearchField()
    private let headerStack = NSStackView()
    private let scrollView = NSScrollView()
    private let prefixGroup = ShortcutSettingsGroupCardView(group: "Prefix & Sequences")
    private let prefixTimeoutField = NSTextField(string: "")
    private let prefixTimeoutHelp = NSTextField(labelWithString: "(100–2,000)")
    private let prefixTimeoutUnitLabel = NSTextField(labelWithString: "ms")
    private let listStack = ShortcutSettingsListStackView()
    private let footerSeparator = NSBox()
    private let footerStatusLabel = NSTextField(labelWithString: "")
    private let footerHintLabel = NSTextField(labelWithString: "")
    private let footer = NSStackView()
    private let footerSpacer = NSView()
    private let reloadButton = ClosureButton(frame: .zero)
    private let discardButton = ClosureButton(frame: .zero)
    private let applyButton = ClosureButton(frame: .zero)

    private var theme = AppKitTheme(themeID: .tokyoNight)
    private var restingBorderColor = NSColor.clear
    private var focusIndicatorColor = NSColor.clear
    private var showsFocusIndicator = false

    private(set) var isEmbedded = false
    private var allRows: [ShortcutSettingsRow] = []
    private var filteredRows: [ShortcutSettingsRow] = []
    private var visibleRows: [ShortcutSettingsRow] = []
    private var rowViews: [String: ShortcutSettingsCompactRowView] = [:]
    private var timeoutRowView: ShortcutSettingsTimeoutRowView!
    private var prefixRowView: ShortcutSettingsCompactRowView?
    private var groupCardViews: [String: ShortcutSettingsGroupCardView] = [:]
    private var renderedListRowIDs: [String] = []
    private var selectedRowID: String?
    private var lastSelectedRowID: String?
    private var panelMode = true
    private var searchIsEditing = false
    private var needsReconciliation = false
    private var canApply = false
    private var isDirty = false
    private var statusMessage: String?
    private var errorMessage: String?
    private var recordingRowID: String?
    private var recordingText: String?
    private var prefixTimeoutEditing = false
    private var prefixTimeoutPreedit: String?
    private var flashTimer: Timer?
    private var statusHeightConstraint: NSLayoutConstraint?
    private var headerHeightConstraint: NSLayoutConstraint?

    private var preferredWidthConstraint: NSLayoutConstraint?
    private var preferredHeightConstraint: NSLayoutConstraint?
    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        if isEmbedded {
            return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
        return NSSize(width: Metrics.preferredWidth, height: Metrics.preferredHeight)
    }

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, embedded: false)
    }

    convenience init(embedded: Bool = false) {
        self.init(frame: .zero, embedded: embedded)
    }

    init(frame frameRect: NSRect, embedded: Bool = false) {
        isEmbedded = embedded
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = WindowVisualMetrics.cornerRadius
        layer?.masksToBounds = false
        shadow = NSShadow()
        shadow?.shadowBlurRadius = 18
        shadow?.shadowOffset = NSSize(width: 0, height: -4)
        setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        setContentCompressionResistancePriority(.fittingSizeCompression, for: .vertical)
        setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        setContentHuggingPriority(.fittingSizeCompression, for: .vertical)
        if !isEmbedded {
            let preferredWidth = widthAnchor.constraint(equalToConstant: Metrics.preferredWidth)
            let preferredHeight = heightAnchor.constraint(equalToConstant: Metrics.preferredHeight)
            preferredWidth.priority = .defaultHigh
            preferredHeight.priority = .defaultHigh
            NSLayoutConstraint.activate([preferredWidth, preferredHeight])
            preferredWidthConstraint = preferredWidth
            preferredHeightConstraint = preferredHeight
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Shortcut settings")
        setAccessibilityIdentifier("shortcutSettingsOverlay")

        configureHeader()
        if !isEmbedded {
            footerSeparator.prepareForAutoLayout()
            addSubview(footerSeparator)
        }
        configureList()
        configureFooter()
        configureActions()

        apply(theme: theme)
        isHidden = true
        updateButtonStates()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updatePreferredSize()
    }

    override func layout() {
        updatePreferredSize()
        super.layout()
    }

    func updatePreferredSize() {
        guard !isEmbedded, let host = superview else { return }
        preferredWidthConstraint?.priority = isHidden ? .fittingSizeCompression : .defaultHigh
        preferredHeightConstraint?.priority = isHidden ? .fittingSizeCompression : .defaultHigh
        preferredWidthConstraint?.constant = min(Metrics.preferredWidth, max(0, host.bounds.width - 32))
        preferredHeightConstraint?.constant = min(Metrics.preferredHeight, max(0, host.bounds.height - 24))
    }
    required init?(coder: NSCoder) { nil }
    // MARK: Public contract

    func apply(theme: AppKitTheme) {
        self.theme = theme
        layer?.backgroundColor = theme[.activeTab].withAlphaComponent(0.98).cgColor
        restingBorderColor = theme.separator
        appearance = NSAppearance(named: theme.id == .catppuccinLatte ? .aqua : .darkAqua)
        focusIndicatorColor = theme.focusRing
        shadow?.shadowColor = theme.overlayShadow

        titleLabel.textColor = theme[.accent]
        prefixGroup.apply(theme: theme)
        separator.borderColor = theme.separator
        footerSeparator.borderColor = theme.separator
        footerStatusLabel.textColor = theme[.mutedText]
        footerHintLabel.textColor = theme[.mutedText]
        searchField.textColor = theme[.foreground]
        searchField.backgroundColor = theme.canvasBackground
        applyButton.contentTintColor = theme[.accent]
        discardButton.contentTintColor = theme[.foreground]
        reloadButton.contentTintColor = theme[.foreground]
        for card in groupCardViews.values { card.apply(theme: theme) }
        for rowView in rowViews.values { rowView.apply(theme: theme) }
        timeoutRowView?.apply(theme: theme)
        updateFocusAppearance()
        renderKeyboardHint()
        renderFooter()
    }

    func present() {
        isHidden = false
        panelMode = true
        searchIsEditing = false
        selectedRowID = nil
        lastSelectedRowID = nil
        prefixTimeoutEditing = false
        prefixTimeoutPreedit = nil
        for rowView in rowViews.values { rowView.isSelected = false }
        timeoutRowView?.isSelected = false
        showsFocusIndicator = true
        updateFocusAppearance()
        updateButtonStates()
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(self)
        renderFooter()
    }

    func dismiss() {
        endRecording()
        cancelPrefixTimeoutEditing()
        flashTimer?.invalidate()
        flashTimer = nil
        panelMode = true
        searchIsEditing = false
        selectedRowID = nil
        showsFocusIndicator = false
        updateFocusAppearance()
        isHidden = true
    }

    func render(
        rows: [ShortcutSettingsRow],
        status: String? = nil,
        canApply: Bool,
        isDirty: Bool
    ) {

        allRows = rows
        statusMessage = status
        self.canApply = canApply
        self.isDirty = isDirty
        updateFilteredRows()
        updateButtonStates()
        renderFooter()

    }

    func setNeedsReconciliation(_ needed: Bool) {
        needsReconciliation = needed
        updateButtonStates()
        renderFooter()
        updateKeyViewLoop()
    }
    func render(prefixTimeoutMilliseconds: String) {
        guard !prefixTimeoutEditing else { return }
        prefixTimeoutField.stringValue = prefixTimeoutMilliseconds
        timeoutRowView?.render(theme: theme)
        prefixTimeoutField.setAccessibilityValue(prefixTimeoutField.stringValue)
        updateKeyViewLoop()
    }

    /// The coordinator owns capture. During recording this view deliberately
    /// returns false for every event so j/k/r/slash/Tab/Enter stay captured.
    func setRecording(rowID: String, text: String) {
        guard rowViews[rowID] != nil else { return }
        selectedRowID = rowID
        lastSelectedRowID = rowID
        onRowSelected?(rowID)
        panelMode = false
        recordingRowID = rowID
        recordingText = text
        for (id, rowView) in rowViews {
            timeoutRowView?.isSelected = false
            rowView.isSelected = id == rowID
            rowView.isRecording = id == rowID
            rowView.recordingText = id == rowID ? text : nil
        }
        updateButtonStates()
        renderFooter()
    }

    func endRecording() {
        recordingRowID = nil
        recordingText = nil
        if let selectedRowID { lastSelectedRowID = selectedRowID }
        for rowView in rowViews.values {
            rowView.isRecording = false
            rowView.recordingText = nil
        }
        updateButtonStates()
        renderFooter()
        restoreSelectedRowFocus()
    }

    func flashError(rowID: String, message: String) {
        errorMessage = message
        statusMessage = message
        flashTimer?.invalidate()
        for (id, rowView) in rowViews { rowView.isFlashing = id == rowID }
        timeoutRowView?.isFlashing = rowID == Self.prefixTimeoutRowID
        flashTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flashTimer = nil
                self.rowViews[rowID]?.isFlashing = false
                self.timeoutRowView?.isFlashing = false
            }
        }
        renderFooter()
    }

    /// Handles panel, selected-row, search, and tab-focus routes. Recording
    /// input always belongs to the coordinator and is never consumed here.
    func handleNavigation(_ event: NSEvent) -> Bool {
        guard recordingRowID == nil else { return false }

        if prefixTimeoutEditing {
            if event.keyCode == 53 {
                cancelPrefixTimeoutEditing()
                return true
            }
            let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            if plain, [36, 76].contains(event.keyCode) {
                return commitPrefixTimeoutEditing()
            }
            return false
        }

        if event.keyCode == 48, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            return moveFocus(backwards: event.modifierFlags.contains(.shift))
        }

        if searchIsEditing {
            switch event.keyCode {
            case 36, 76, 53:
                finishSearch()
                return true
            default:
                return false
            }
        }

        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           (event.keyCode == 44 || event.charactersIgnoringModifiers == "/") {
            beginSearch()
            return true
        }

        // Let a focused native footer button perform its own explicit activation.
        if isNativeButtonFocused && [36, 76, 49].contains(event.keyCode) {
            return false
        }

        // The embedded shell owns panel-mode routing. Returning false here is
        // deliberate: the child must not consume j while the shell is in its
        // RIGHTPANEL state.
        if panelMode && isEmbedded {
            return false
        }

        if panelMode {
            switch event.keyCode {
            case 126: return moveSelection(by: -1)
            case 125: return moveSelection(by: 1)
            case 36, 76:
                guard applyButton.isEnabled else { return true }
                guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
                onApply?()
                return true
            case 53:
                onClose?()
                return true
            default:
                guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                      let characters = event.charactersIgnoringModifiers?.lowercased()
                else { return false }
                switch characters {
                case "k": return moveSelection(by: -1)
                case "j": return moveSelection(by: 1)
                default: return false
                }
            }
        }

        guard selectedRowID != nil else {
            enterPanelMode()
            return true
        }

        switch event.keyCode {
        case 126: return moveSelection(by: -1)
        case 125: return moveSelection(by: 1)
        case 36, 76:
            guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
            return beginEditingSelectedRowForShell()
        case 53:
            enterPanelMode()
            return true
        default:
            guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let characters = event.charactersIgnoringModifiers?.lowercased()
            else { return false }
            switch characters {
            case "k": return moveSelection(by: -1)
            case "j": return moveSelection(by: 1)
            case "r": return resetSelection()
            default: return false
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if !handleNavigation(event) { super.keyDown(with: event) }
    }

    // MARK: Internal testing/focus surface

    var searchFieldForTesting: NSSearchField { searchField }
    var reloadButtonForTesting: NSButton { reloadButton }
    var applyButtonForTesting: NSButton { applyButton }
    var discardButtonForTesting: NSButton { discardButton }
    var footerStatusForTesting: NSTextField { footerStatusLabel }
    var footerHintForTesting: NSTextField { footerHintLabel }
    var visibleRowIDsForTesting: [String] { visibleRows.map(\.id) }
    var selectedRowIDForTesting: String? { selectedRowID }
    var panelModeForTesting: Bool { panelMode }
    var ownsSearchInput: Bool { searchIsEditing }
    var isRecording: Bool { recordingRowID != nil }
    var isEditingPrefixTimeout: Bool { prefixTimeoutEditing }
    var validationMessageForParent: String? { errorMessage }
    var prefixTimeoutFieldForTesting: NSTextField { prefixTimeoutField }
    var searchIsEditingForTesting: Bool { searchIsEditing }
    var rowViewsForTesting: [String: NSView] {
        var result = rowViews.mapValues { $0 as NSView }
        if let timeoutRowView { result[Self.prefixTimeoutRowID] = timeoutRowView }
        return result
    }
    var groupCardIDsForTesting: [String] {
        listStack.arrangedSubviews.compactMap { $0.accessibilityIdentifier() }
            .filter { $0.hasPrefix("shortcutSettings.group.") }
    }
    var isEmbeddedForTesting: Bool { isEmbedded }
    var isRecordingForTesting: Bool { recordingRowID != nil }
    var headerTitleForTesting: NSTextField { titleLabel }
    var orderedKeyViews: [NSView] {
        var result: [NSView] = [searchField]
        for row in visibleRows {
            if row.id == Self.prefixTimeoutRowID {
                result.append(prefixTimeoutField)
            } else if let rowView = rowViews[row.id] {
                result.append(contentsOf: rowView.orderedKeyViews)
            }
        }
        if !reloadButton.isHidden { result.append(reloadButton) }
        result.append(contentsOf: [discardButton, applyButton])
        return result.filter { !$0.isHidden && (($0 as? NSControl)?.isEnabled ?? true) }
    }

    var selectedRowIDValue: String? { selectedRowID }
    var isPanelModeValue: Bool { panelMode }

    func enterRowModeForShell(preferredRowID: String? = nil) {
        let preferred = preferredRowID ?? lastSelectedRowID
        let target = preferred.flatMap { candidate in
            visibleRows.contains(where: { $0.id == candidate }) ? candidate : nil
        } ?? visibleRows.first?.id
        if let target { selectRow(target, focus: true) } else { enterPanelMode() }
    }

    func enterFirstRowModeForShell() {
        if let target = visibleRows.first?.id {
            selectRow(target, focus: true)
        } else {
            enterPanelMode()
        }
    }

    func leaveRowModeForShell() {
        if let selectedRowID { lastSelectedRowID = selectedRowID }
        enterPanelMode()
    }

    func cancelEditingForShell() {
        cancelPrefixTimeoutEditing()
        if searchIsEditing {
            searchIsEditing = false
            window?.makeFirstResponder(self)
            renderKeyboardHint()
        }
    }

    func moveSelectionForShell(by offset: Int) -> Bool {
        moveSelection(by: offset)
    }

    func selectBoundaryForShell(direction: Int) {
        guard let id = (direction < 0 ? visibleRows.last : visibleRows.first)?.id else {
            enterPanelMode()
            return
        }
        selectRow(id, focus: true)
    }

    @discardableResult
    func beginEditingSelectedRowForShell() -> Bool {
        guard !needsReconciliation, recordingRowID == nil, let selectedRowID else { return false }
        if selectedRowID == Self.prefixTimeoutRowID {
            beginPrefixTimeoutEditing()
            return true
        }
        return beginRecordingForSelection()
    }

    @discardableResult
    func resetSelectedRowForShell() -> Bool {
        resetSelection()
    }

    func currentTextForTesting(rowID: String) -> String? {
        if rowID == Self.prefixTimeoutRowID { return prefixTimeoutField.stringValue }
        return rowViews[rowID]?.displayedCurrentText
    }

    func isFlashingForTesting(rowID: String) -> Bool {
        if rowID == Self.prefixTimeoutRowID { return timeoutRowView?.isFlashing ?? false }
        return rowViews[rowID]?.isFlashing ?? false
    }

    // MARK: Layout

    private func configureHeader() {
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.setAccessibilityIdentifier("shortcutSettings.title")
        titleLabel.setContentHuggingPriority(.required, for: .vertical)

        separator.boxType = .separator
        separator.setAccessibilityIdentifier("shortcutSettings.separator")

        searchField.placeholderString = "Search actions"
        searchField.font = .systemFont(ofSize: 13)
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search shortcut actions")
        searchField.setAccessibilityIdentifier("shortcutSettings.search")
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleLabel.isHidden = isEmbedded
        separator.isHidden = isEmbedded
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 8
        headerStack.addArrangedSubview(titleLabel)
        headerStack.addArrangedSubview(separator)
        headerStack.addArrangedSubview(searchField)
        headerStack.prepareForAutoLayout()
        addSubview(headerStack)

        headerHeightConstraint = headerStack.heightAnchor.constraint(equalToConstant: isEmbedded ? 26 : Metrics.headerHeight)
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: topAnchor, constant: isEmbedded ? 8 : Metrics.inset),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.inset),
            headerHeightConstraint!,
            titleLabel.heightAnchor.constraint(equalToConstant: 20),
            separator.heightAnchor.constraint(equalToConstant: 1),
            separator.widthAnchor.constraint(equalTo: headerStack.widthAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 26),
            searchField.widthAnchor.constraint(equalTo: headerStack.widthAnchor),
        ])
    }

    private func configureList() {
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.distribution = .fill
        listStack.spacing = 8
        listStack.setAccessibilityIdentifier("shortcutSettings.list")
        listStack.prepareForAutoLayout()

        timeoutRowView = ShortcutSettingsTimeoutRowView(field: prefixTimeoutField, help: prefixTimeoutHelp, unit: prefixTimeoutUnitLabel)
        timeoutRowView.apply(theme: theme)
        timeoutRowView.onSelect = { [weak self] in
            self?.selectRow(Self.prefixTimeoutRowID, focus: true)
        }
        prefixTimeoutField.delegate = self
        prefixGroup.isHidden = true
        timeoutRowView.isHidden = true
        prefixGroup.add(timeoutRowView)
        listStack.addArrangedSubview(prefixGroup)
        prefixGroup.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.setAccessibilityLabel("Shortcut actions")
        scrollView.setAccessibilityIdentifier("shortcutSettings.scroll")
        scrollView.documentView = listStack
        scrollView.prepareForAutoLayout()
        listStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true
        listStack.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor).isActive = true
        addSubview(scrollView)

        let scrollBottomConstraint = isEmbedded
            ? scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
            : scrollView.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor, constant: -8)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.inset),
            scrollBottomConstraint,
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.minimumListHeight),
        ])
    }
    private func configureFooter() {

        guard !isEmbedded else {
            footerStatusLabel.isHidden = true
            footerHintLabel.isHidden = true
            reloadButton.isHidden = true
            discardButton.isHidden = true
            applyButton.isHidden = true
            return
        }
        footerSeparator.boxType = .separator
        footerSeparator.setAccessibilityIdentifier("shortcutSettings.footerSeparator")

        footerStatusLabel.font = .systemFont(ofSize: 11)
        footerStatusLabel.maximumNumberOfLines = 1
        footerStatusLabel.lineBreakMode = .byTruncatingTail
        footerStatusLabel.setAccessibilityLabel("Shortcut settings status")
        footerStatusLabel.setAccessibilityIdentifier("shortcutSettings.status")
        footerStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerStatusLabel.prepareForAutoLayout()
        addSubview(footerStatusLabel)

        footerHintLabel.maximumNumberOfLines = 1
        footerHintLabel.lineBreakMode = .byWordWrapping
        footerHintLabel.setAccessibilityLabel("Shortcut settings keyboard hints")
        footerHintLabel.setAccessibilityIdentifier("shortcutSettings.hint")
        footerHintLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        footerHintLabel.prepareForAutoLayout()
        addSubview(footerHintLabel)

        for button in [reloadButton, discardButton, applyButton] {
            button.controlSize = .small
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            button.keyEquivalent = ""
            button.prepareForAutoLayout()
        }
        reloadButton.title = "Reload"
        discardButton.title = "Discard"
        applyButton.title = "Apply"
        reloadButton.setAccessibilityLabel("Reload settings source")
        reloadButton.setAccessibilityIdentifier("shortcutSettings.reload")
        discardButton.setAccessibilityLabel("Discard shortcut changes")
        discardButton.setAccessibilityIdentifier("shortcutSettings.discard")
        applyButton.setAccessibilityLabel("Apply shortcut changes")
        applyButton.setAccessibilityIdentifier("shortcutSettings.apply")
        reloadButton.isHidden = true
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        footer.addArrangedSubview(footerSpacer)
        footer.addArrangedSubview(reloadButton)
        footer.addArrangedSubview(discardButton)
        footer.addArrangedSubview(applyButton)
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerSpacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 1).isActive = true
        footerSpacer.heightAnchor.constraint(equalToConstant: 1).isActive = true
        footer.prepareForAutoLayout()
        addSubview(footer)
        statusHeightConstraint = footerStatusLabel.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            footerSeparator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
            footerSeparator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.inset),
            footerSeparator.bottomAnchor.constraint(equalTo: footerStatusLabel.topAnchor, constant: -5),
            footerStatusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
            footerStatusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.inset),
            footerStatusLabel.bottomAnchor.constraint(equalTo: footerHintLabel.topAnchor, constant: -4),
            footerHintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
            footerHintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.inset),
            footerHintLabel.heightAnchor.constraint(equalToConstant: Metrics.hintHeight),
            footerHintLabel.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
            footerSeparator.heightAnchor.constraint(equalToConstant: 1),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.inset),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.inset),
            footer.heightAnchor.constraint(equalToConstant: Metrics.footerHeight),
            statusHeightConstraint!,
            reloadButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 62),
            discardButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 68),
            applyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 55),
        ])
    }

    private func configureActions() {
        reloadButton.handler = { [weak self] in
            guard let self, self.needsReconciliation, self.recordingRowID == nil else { return }
            self.onReload?()
        }
        discardButton.handler = { [weak self] in
            guard let self, self.discardButton.isEnabled, self.recordingRowID == nil else { return }
            self.onDiscard?()
        }
        applyButton.handler = { [weak self] in
            guard let self, self.applyButton.isEnabled, self.recordingRowID == nil else { return }
            self.onApply?()
        }
    }

    // MARK: Filtering and grouped list rendering

    private func updateFilteredRows() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches: (ShortcutSettingsRow) -> Bool = { row in
            query.isEmpty || row.title.lowercased().contains(query)
        }
        let timeout = ShortcutSettingsRow(
            id: Self.prefixTimeoutRowID,
            title: "Sequence timeout",
            group: "",
            current: prefixTimeoutField.stringValue,
            defaultBinding: String(BuiltInDefaults.config.input.prefixTimeoutMilliseconds)
        )
        let prefix = allRows.first(where: { $0.id == "input.prefix" && matches($0) })
        let actions = allRows.filter { $0.id != "input.prefix" && matches($0) }
        let prefixRows = (matches(timeout) ? [timeout] : []) + (prefix.map { [$0] } ?? [])
        filteredRows = prefixRows + actions
        visibleRows = filteredRows
        if let selectedRowID, !visibleRows.contains(where: { $0.id == selectedRowID }) {
            self.selectedRowID = nil
            panelMode = true
        }
        rebuildListIfNeeded()
    }

    private func rebuildListIfNeeded() {
        let prefix = visibleRows.first(where: { $0.id == "input.prefix" })
        let timeout = visibleRows.first(where: { $0.id == Self.prefixTimeoutRowID })
        let actions = visibleRows.filter { $0.id != "input.prefix" && $0.id != Self.prefixTimeoutRowID }
        let expectedGroups = displayItemKeys(for: actions)
        let actionIDs = actions.map(\.id)
        let expectedRowIDs = Set(actionIDs + (prefix.map { [$0.id] } ?? []))
        let existingGroups = listStack.arrangedSubviews.compactMap { $0.accessibilityIdentifier() }
            .filter { $0.hasPrefix("shortcutSettings.group.") && $0 != prefixGroup.groupIdentifier }

        prefixGroup.isHidden = prefix == nil && timeout == nil
        timeoutRowView.isHidden = timeout == nil
        if timeout != nil {
            timeoutRowView.render(theme: theme)
            timeoutRowView.isSelected = selectedRowID == Self.prefixTimeoutRowID
            timeoutRowView.isFlashing = errorMessage != nil && selectedRowID == Self.prefixTimeoutRowID
            timeoutRowView.editingEnabled = !needsReconciliation && recordingRowID == nil
        }

        if let prefix {
            if prefixRowView == nil {
                let rowView = makeRowView(prefix)
                prefixRowView = rowView
                prefixGroup.add(rowView)
                // Group container supplies the same full-width row constraints.
            }
            prefixRowView?.isHidden = false
            prefixRowView?.render(row: prefix, theme: theme)
            prefixRowView?.isSelected = prefix.id == selectedRowID
            prefixRowView?.isRecording = prefix.id == recordingRowID
            prefixRowView?.editingEnabled = !needsReconciliation && recordingRowID == nil
            if let prefixRowView { rowViews[prefix.id] = prefixRowView }
        } else {
            prefixRowView?.isHidden = true
            rowViews.removeValue(forKey: "input.prefix")
        }

        let structureMatches = expectedGroups == existingGroups
            && renderedListRowIDs == actionIDs
            && Set(rowViews.keys) == expectedRowIDs
        if structureMatches {
            for row in actions {
                rowViews[row.id]?.render(row: row, theme: theme)
                rowViews[row.id]?.isSelected = row.id == selectedRowID
                rowViews[row.id]?.isRecording = row.id == recordingRowID
                rowViews[row.id]?.editingEnabled = !needsReconciliation && recordingRowID == nil
            }
            updateKeyViewLoop()
            return
        }

        for card in groupCardViews.values {
            listStack.removeArrangedSubview(card)
            card.removeFromSuperview()
        }
        rowViews.removeAll(keepingCapacity: true)
        groupCardViews.removeAll(keepingCapacity: true)
        if let prefix, let prefixRowView {
            rowViews[prefix.id] = prefixRowView
        }

        var previousGroup: String?
        var currentCard: ShortcutSettingsGroupCardView?
        for row in actions {
            let group = row.group.isEmpty ? "Other" : row.group
            if group != previousGroup {
                let card = ShortcutSettingsGroupCardView(group: group)
                card.apply(theme: theme)
                listStack.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
                groupCardViews[card.groupIdentifier] = card
                currentCard = card
                previousGroup = group
            }
            let rowView = makeRowView(row)
            rowViews[row.id] = rowView
            currentCard?.add(rowView)
        }
        renderedListRowIDs = actionIDs
        updateKeyViewLoop()
    }

    private func makeRowView(_ row: ShortcutSettingsRow) -> ShortcutSettingsCompactRowView {
        let rowView = ShortcutSettingsCompactRowView(row: row)
        rowView.apply(theme: theme)
        rowView.isSelected = row.id == selectedRowID
        rowView.isRecording = row.id == recordingRowID
        rowView.editingEnabled = !needsReconciliation && recordingRowID == nil
        rowView.onSelect = { [weak self] in self?.selectRow(row.id, focus: true) }
        rowView.onRecord = { [weak self] in
            guard let self, !self.needsReconciliation, self.recordingRowID == nil else { return }
            self.selectRow(row.id, focus: true)
            self.onRecord?(row.id)
        }
        rowView.onReset = { [weak self] in
            guard let self, !self.needsReconciliation, self.recordingRowID == nil else { return }
            self.selectRow(row.id, focus: true)
            self.onReset?(row.id)
        }
        return rowView
    }

    private func displayItemKeys(for rows: [ShortcutSettingsRow]) -> [String] {
        var keys: [String] = []
        var previousGroup: String?
        for row in rows {
            let group = row.group.isEmpty ? "Other" : row.group
            if group != previousGroup {
                keys.append("shortcutSettings.group.\(group)")
                previousGroup = group
            }
        }
        return keys
    }

    // MARK: Selection and contexts

    private func selectRow(_ id: String, focus: Bool) {
        guard visibleRows.contains(where: { $0.id == id }) else { return }
        panelMode = false
        selectedRowID = id
        lastSelectedRowID = id
        onRowSelected?(id)
        for (rowID, rowView) in rowViews { rowView.isSelected = rowID == id }
        timeoutRowView?.isSelected = id == Self.prefixTimeoutRowID
        if id == Self.prefixTimeoutRowID {
            if focus { window?.makeFirstResponder(self) }
        } else if focus, let button = rowViews[id]?.titleButton, button.window != nil {
            button.window?.makeFirstResponder(button)
        }
        if let row: NSView = id == Self.prefixTimeoutRowID ? timeoutRowView : rowViews[id] {
            layoutSubtreeIfNeeded()
            row.scrollToVisible(row.bounds)
        }
        updateButtonStates()
        renderFooter()
        updateKeyViewLoop()
    }

    private func moveSelection(by offset: Int) -> Bool {
        let ids = visibleRows.map(\.id)
        guard !ids.isEmpty else { return true }
        let current: Int
        if let selectedRowID, let index = ids.firstIndex(of: selectedRowID) {
            current = index
        } else {
            current = offset < 0 ? ids.count : -1
        }
        let next = min(max(current + offset.signum(), 0), ids.count - 1)
        selectRow(ids[next], focus: true)
        return true
    }

    private func beginRecordingForSelection() -> Bool {
        guard !needsReconciliation, recordingRowID == nil, let selectedRowID,
              visibleRows.contains(where: { $0.id == selectedRowID })
        else { return false }
        selectRow(selectedRowID, focus: true)
        onRecord?(selectedRowID)
        return true
    }

    private func resetSelection() -> Bool {
        guard !needsReconciliation, recordingRowID == nil, let selectedRowID,
              visibleRows.contains(where: { $0.id == selectedRowID })
        else { return false }
        if selectedRowID == Self.prefixTimeoutRowID {
            cancelPrefixTimeoutEditing()
            let value = String(BuiltInDefaults.config.input.prefixTimeoutMilliseconds)
            prefixTimeoutField.stringValue = value
            errorMessage = nil
            onPrefixTimeoutChanged?(value)
            renderFooter()
            return true
        }
        onReset?(selectedRowID)
        return true
    }

    private func enterPanelMode() {
        if let selectedRowID { lastSelectedRowID = selectedRowID }
        panelMode = true
        selectedRowID = nil
        for rowView in rowViews.values { rowView.isSelected = false }
        timeoutRowView?.isSelected = false
        window?.makeFirstResponder(self)
        updateButtonStates()
        renderFooter()
        updateKeyViewLoop()
    }

    // MARK: Search/focus

    private func beginSearch() {
        searchIsEditing = true
        if let selectedRowID { lastSelectedRowID = selectedRowID }
        panelMode = true
        selectedRowID = nil
        for rowView in rowViews.values { rowView.isSelected = false }
        timeoutRowView?.isSelected = false
        window?.makeFirstResponder(searchField)
        renderKeyboardHint()
    }

    private func finishSearch() {
        searchIsEditing = false
        if let match = visibleRows.first {
            selectRow(match.id, focus: true)
        } else {
            enterPanelMode()
        }
        renderKeyboardHint()
    }

    private func restoreSelectedRowFocus() {
        guard let window else { return }
        guard let selectedRowID, let button = rowViews[selectedRowID]?.titleButton, button.window === window else {
            window.makeFirstResponder(self)
            return
        }
        panelMode = false
        button.window?.makeFirstResponder(button)
    }

    private var isNativeButtonFocused: Bool {
        guard let responder = window?.firstResponder as? NSButton else { return false }
        return responder !== rowViews[selectedRowID ?? ""]?.titleButton
    }

    private func updateButtonStates() {
        let editable = !needsReconciliation && recordingRowID == nil
        discardButton.isHidden = isEmbedded
        applyButton.isHidden = isEmbedded
        applyButton.isEnabled = !isEmbedded && canApply && isDirty && editable
        discardButton.isEnabled = !isEmbedded && isDirty && recordingRowID == nil
        reloadButton.isHidden = isEmbedded || !needsReconciliation
        reloadButton.isEnabled = !isEmbedded && needsReconciliation && recordingRowID == nil
        applyButton.font = .systemFont(ofSize: 12, weight: panelMode ? .bold : .regular)
        for rowView in rowViews.values {
            rowView.editingEnabled = editable
            rowView.isRecording = rowView.row.id == recordingRowID
            rowView.recordingText = rowView.row.id == recordingRowID ? recordingText : nil
            rowView.isSelected = rowView.row.id == selectedRowID
        }
        timeoutRowView?.editingEnabled = editable
        timeoutRowView?.isSelected = selectedRowID == Self.prefixTimeoutRowID
    }

    private func renderFooter() {
        let selected = visibleRows.first { $0.id == selectedRowID } ?? (searchIsEditing ? visibleRows.first : nil)
        var detail = selected.map { "Default: " + ($0.defaultBinding.map { ShortcutKeyDisplay.text(for: $0) } ?? "Unassigned") }
        if selectedRowID == Self.prefixTimeoutRowID {
            detail = "Prefix timeout: \(prefixTimeoutField.stringValue) ms"
        }
        if let source = selected?.current, let input = ShortcutKeyDisplay.inputDescription(for: source) {
            detail = "Input: \(input) · " + (detail ?? "")
        }
        if let count = selected?.additionalBindingCount, count > 0 {
            detail = (detail ?? "") + " · \(count) additional file binding(s) preserved"
        }
        let base = errorMessage ?? statusMessage ?? detail
        footerStatusLabel.stringValue = base ?? ""
        footerStatusLabel.isHidden = isEmbedded || base == nil || base?.isEmpty == true
        footerStatusLabel.textColor = errorMessage == nil ? theme[.mutedText] : theme[.error]
        statusHeightConstraint?.constant = footerStatusLabel.isHidden ? 0 : 16
        renderKeyboardHint()
        updateKeyViewLoop()
    }

    private func renderKeyboardHint() {
        let text: String
        let keys: [String]
        if recordingRowID != nil {
            text = "↩  Finish    Esc  Cancel"
            keys = ["↩", "Esc"]
        } else if searchIsEditing {
            text = "↩ / Esc  Leave search"
            keys = ["↩ / Esc"]
        } else if panelMode {
            text = "j / k  Select row    ↩  Apply    Esc  Close"
            keys = ["j / k", "↩", "Esc"]
        } else {
            text = "j / k  Move row    ↩  Record    Esc  Panel    r  Reset"
            keys = ["j / k", "↩", "Esc", "r"]
        }
        footerHintLabel.attributedStringValue = SettingsKeyboardHint.make(text: text, keys: keys, theme: theme)
    }

    private func updateFocusAppearance() {
        if isEmbedded {
            layer?.borderWidth = 0
            layer?.backgroundColor = NSColor.clear.cgColor
            shadow = nil
            return
        }
        layer?.borderColor = (showsFocusIndicator ? focusIndicatorColor : restingBorderColor).cgColor
        layer?.borderWidth = 1
    }

    private func moveFocus(backwards: Bool) -> Bool {
        guard let window else { return false }
        let controls = orderedKeyViews.filter { !$0.isHiddenOrHasHiddenAncestor && $0.acceptsFirstResponder }
        guard !controls.isEmpty else { return true }
        let responder = window.firstResponder
        let current: NSResponder? = searchField.currentEditor() === responder ? searchField : responder
        let index = controls.firstIndex { $0 === current }
        let next: Int
        if let index {
            let candidate = index + (backwards ? -1 : 1)
            guard controls.indices.contains(candidate) else { return false }
            next = candidate
        } else {
            next = backwards ? controls.count - 1 : 0
        }
        if window.makeFirstResponder(controls[next]) { controls[next].scrollToVisible(controls[next].bounds) }
        return true
    }

    private func updateKeyViewLoop() {
        let controls = orderedKeyViews
        guard !controls.isEmpty else { return }
        for (current, next) in zip(controls, controls.dropFirst()) {
            current.nextKeyView = next
        }
        controls.last?.nextKeyView = nil
    }

    private func beginPrefixTimeoutEditing() {
        guard !needsReconciliation, recordingRowID == nil else { return }
        if !prefixTimeoutEditing { prefixTimeoutPreedit = prefixTimeoutField.stringValue }
        prefixTimeoutEditing = true
        errorMessage = nil
        selectedRowID = Self.prefixTimeoutRowID
        panelMode = false
        lastSelectedRowID = Self.prefixTimeoutRowID
        onRowSelected?(Self.prefixTimeoutRowID)
        window?.makeFirstResponder(prefixTimeoutField)
        prefixTimeoutField.currentEditor()?.selectAll(nil)
        renderFooter()
    }

    @discardableResult
    private func commitPrefixTimeoutEditing() -> Bool {
        guard prefixTimeoutEditing else { return false }
        let text = prefixTimeoutField.stringValue
        guard let value = Int(text), ConfigBounds.prefixTimeoutMilliseconds.contains(value) else {
            errorMessage = "Key sequence timeout must be 100–2,000 milliseconds."
            renderFooter()
            return true
        }
        prefixTimeoutEditing = false
        prefixTimeoutPreedit = nil
        errorMessage = nil
        window?.makeFirstResponder(self)
        onPrefixTimeoutChanged?(String(value))
        renderFooter()
        return true
    }

    private func cancelPrefixTimeoutEditing() {
        guard prefixTimeoutEditing else { return }
        if let prefixTimeoutPreedit { prefixTimeoutField.stringValue = prefixTimeoutPreedit }
        prefixTimeoutEditing = false
        self.prefixTimeoutPreedit = nil
        errorMessage = nil
        window?.makeFirstResponder(self)
        renderFooter()
    }

    // MARK: NSSearchFieldDelegate

    func controlTextDidBeginEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === prefixTimeoutField {
            if !prefixTimeoutEditing { prefixTimeoutPreedit = field.stringValue }
            prefixTimeoutEditing = true
            panelMode = false
            selectedRowID = Self.prefixTimeoutRowID
            lastSelectedRowID = Self.prefixTimeoutRowID
            onRowSelected?(Self.prefixTimeoutRowID)
            timeoutRowView?.isSelected = true
            renderKeyboardHint()
            return
        }
        guard let field = notification.object as? NSSearchField, field === searchField else { return }
        searchIsEditing = true
        if let selectedRowID { lastSelectedRowID = selectedRowID }
        panelMode = true
        selectedRowID = nil
        for rowView in rowViews.values { rowView.isSelected = false }
        timeoutRowView?.isSelected = false
        renderKeyboardHint()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === prefixTimeoutField { return }
        guard let field = notification.object as? NSSearchField, field === searchField else { return }
        searchIsEditing = false
    }

    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === prefixTimeoutField {
            field.setAccessibilityValue(field.stringValue)
            timeoutRowView?.render(theme: theme)
            renderFooter()
            return
        }
        guard let field = notification.object as? NSSearchField, field === searchField else { return }
        selectedRowID = nil
        panelMode = true
        updateFilteredRows()
        renderFooter()
    }
}
@MainActor
private final class ShortcutSettingsTimeoutRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Sequence timeout")
    private let field: NSTextField
    private let helpLabel: NSTextField
    private let unitLabel: NSTextField
    private let rowStack = NSStackView()
    private var theme = AppKitTheme(themeID: .tokyoNight)

    var onSelect: (() -> Void)?
    var isSelected = false { didSet { updateAppearance() } }
    var isFlashing = false { didSet { updateAppearance() } }
    var editingEnabled = true { didSet { field.isEnabled = editingEnabled } }
    var orderedKeyViews: [NSView] { [field].filter { !$0.isHidden && $0.isEnabled } }

    init(field: NSTextField, help: NSTextField, unit: NSTextField) {
        self.field = field
        helpLabel = help
        unitLabel = unit
        super.init(frame: .zero)
        prepareForAutoLayout()
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Sequence timeout")
        setAccessibilityIdentifier("shortcutSettings.row.input.prefixTimeout")

        titleLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        titleLabel.setAccessibilityIdentifier("settings.keyboard.prefixTimeoutMilliseconds.label")
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true

        field.placeholderString = "400"
        field.font = .systemFont(ofSize: 13)
        field.alignment = .right
        field.setAccessibilityLabel("Prefix timeout")
        field.setAccessibilityIdentifier("settings.keyboard.prefixTimeoutMilliseconds")
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.widthAnchor.constraint(equalToConstant: 96).isActive = true
        field.focusRingType = .none
        field.heightAnchor.constraint(equalToConstant: 25).isActive = true

        unitLabel.font = .systemFont(ofSize: 10)
        unitLabel.setAccessibilityIdentifier("settings.keyboard.prefixTimeoutMilliseconds.unit")
        unitLabel.setContentHuggingPriority(.required, for: .horizontal)
        helpLabel.font = .systemFont(ofSize: 10)
        helpLabel.setAccessibilityIdentifier("settings.keyboard.prefixTimeoutMilliseconds.help")
        helpLabel.maximumNumberOfLines = 1
        helpLabel.lineBreakMode = .byClipping
        helpLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        helpLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        unitLabel.widthAnchor.constraint(equalToConstant: 14).isActive = true
        helpLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true

        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 5
        rowStack.addArrangedSubview(titleLabel)
        rowStack.addArrangedSubview(field)
        rowStack.addArrangedSubview(unitLabel)
        rowStack.addArrangedSubview(helpLabel)
        rowStack.prepareForAutoLayout()
        addSubview(rowStack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            rowStack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    func render(theme: AppKitTheme) {
        self.theme = theme
        titleLabel.textColor = theme[.foreground]
        unitLabel.textColor = theme[.mutedText]
        helpLabel.textColor = theme[.mutedText]
        field.textColor = theme[.foreground]
        field.backgroundColor = theme.canvasBackground
        updateAppearance()
    }

    func apply(theme: AppKitTheme) { render(theme: theme) }

    private func updateAppearance() {
        let fill = isFlashing ? theme[.error].withAlphaComponent(0.24)
            : (isSelected ? theme[.accent].withAlphaComponent(0.30) : NSColor.clear)
        layer?.backgroundColor = fill.cgColor
        field.isEnabled = editingEnabled
    }
}


@MainActor
private final class ShortcutSettingsListStackView: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class ShortcutSettingsGroupCardView: NSView {
    let groupIdentifier: String
    private let titleLabel: NSTextField
    private let rowsStack = NSStackView()
    private var theme = AppKitTheme(themeID: .tokyoNight)
    private enum Metrics {
        static let groupHeight: CGFloat = 26
    }

    init(group: String) {
        groupIdentifier = "shortcutSettings.group.\(group)"
        titleLabel = NSTextField(labelWithString: group.uppercased())
        super.init(frame: .zero)
        prepareForAutoLayout()
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(group) shortcut group")
        setAccessibilityIdentifier(groupIdentifier)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.setAccessibilityIdentifier("\(groupIdentifier).header")
        titleLabel.prepareForAutoLayout()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.prepareForAutoLayout()
        addSubview(titleLabel)
        addSubview(rowsStack)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            titleLabel.heightAnchor.constraint(equalToConstant: Metrics.groupHeight - 5),
            rowsStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func add(_ row: NSView) {
        rowsStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        layer?.backgroundColor = theme[.activeTab].withAlphaComponent(0.48).cgColor
        layer?.borderColor = theme.separator.cgColor
        titleLabel.textColor = theme[.mutedText]
        for row in rowsStack.arrangedSubviews.compactMap({ $0 as? ShortcutSettingsCompactRowView }) {
            row.apply(theme: theme)
        }
    }
}

@MainActor
private final class ShortcutSettingsCompactRowView: NSView {
    var row: ShortcutSettingsRow
    private enum Metrics {
        static let rowHeight: CGFloat = 32
    }
    let titleButton = ClosureButton(frame: .zero)
    private let currentKeycap = ShortcutSettingsKeycapView(text: "Unassigned", identifier: "")
    private let currentStack = NSStackView()
    private let contentStack = NSStackView()
    private let recordButton = ClosureButton(frame: .zero)
    private let resetButton = ClosureButton(frame: .zero)
    private var theme = AppKitTheme(themeID: .tokyoNight)

    var onSelect: (() -> Void)?
    var onRecord: (() -> Void)?
    var onReset: (() -> Void)?
    var isSelected = false { didSet { updateAppearance() } }
    var isRecording = false { didSet { updateAppearance(); renderCurrent() } }
    var isFlashing = false { didSet { updateAppearance() } }
    var editingEnabled = true { didSet { updateControls() } }
    var recordingText: String? { didSet { renderCurrent() } }
    var displayedCurrentText: String { currentKeycap.displayText }

    var orderedKeyViews: [NSView] {
        [titleButton, recordButton, resetButton].filter { !$0.isHidden && $0.isEnabled }
    }

    init(row: ShortcutSettingsRow) {
        self.row = row
        super.init(frame: .zero)
        prepareForAutoLayout()
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(row.title)
        setAccessibilityIdentifier("shortcutSettings.row.\(row.id)")

        titleButton.title = row.title
        titleButton.alignment = .left
        titleButton.isBordered = false
        titleButton.focusRingType = .none
        titleButton.font = .systemFont(ofSize: 11.5, weight: .medium)
        titleButton.lineBreakMode = .byTruncatingTail
        titleButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        titleButton.setAccessibilityLabel(row.title)
        titleButton.setAccessibilityIdentifier("shortcutSettings.row.\(row.id).title")
        titleButton.handler = { [weak self] in self?.onSelect?() }
        titleButton.prepareForAutoLayout()

        currentKeycap.setAccessibilityIdentifier("shortcutSettings.row.\(row.id).current")
        currentKeycap.prepareForAutoLayout()
        currentStack.orientation = .horizontal
        currentStack.distribution = .fill
        currentStack.alignment = .centerY
        currentStack.spacing = 5
        currentStack.addArrangedSubview(currentKeycap)
        currentStack.prepareForAutoLayout()
        currentKeycap.widthAnchor.constraint(equalTo: currentStack.widthAnchor).isActive = true
        currentStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        currentStack.setContentHuggingPriority(.required, for: .horizontal)

        recordButton.title = "Record"
        recordButton.controlSize = .small
        recordButton.setAccessibilityLabel("Record \(row.title)")
        recordButton.setAccessibilityIdentifier("shortcutSettings.row.\(row.id).record")
        recordButton.handler = { [weak self] in self?.onRecord?() }
        recordButton.prepareForAutoLayout()

        resetButton.title = "Reset"
        resetButton.controlSize = .small
        resetButton.setAccessibilityLabel("Reset \(row.title)")
        resetButton.setAccessibilityIdentifier("shortcutSettings.row.\(row.id).reset")
        resetButton.handler = { [weak self] in self?.onReset?() }
        resetButton.prepareForAutoLayout()
        for button in [recordButton, resetButton] {
            button.controlSize = .mini
            button.font = .systemFont(ofSize: 10, weight: .regular)
            button.isBordered = false
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }

        contentStack.orientation = .horizontal
        contentStack.distribution = .fill
        contentStack.alignment = .centerY
        contentStack.spacing = 5
        contentStack.addArrangedSubview(titleButton)
        contentStack.addArrangedSubview(currentStack)
        contentStack.addArrangedSubview(recordButton)
        contentStack.addArrangedSubview(resetButton)
        contentStack.prepareForAutoLayout()
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.rowHeight),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            titleButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            currentStack.widthAnchor.constraint(equalToConstant: 96),
            recordButton.widthAnchor.constraint(equalToConstant: 42),
            resetButton.widthAnchor.constraint(equalToConstant: 36),
        ])
        render(row: row, theme: theme)
        updateControls()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateTitleTooltip()
    }

    private func updateTitleTooltip() {
        titleButton.toolTip = row.title
    }

    func render(row: ShortcutSettingsRow, theme: AppKitTheme) {
        self.theme = theme
        self.row = row
        titleButton.title = row.title
        updateTitleTooltip()
        renderCurrent()
        updateAppearance()
    }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        currentKeycap.apply(theme: theme, fixed: false)
        titleButton.contentTintColor = theme[.foreground]
        recordButton.contentTintColor = theme[.foreground]
        resetButton.contentTintColor = theme[.foreground]
        updateAppearance()
    }

    private func renderCurrent() {
        let value: String
        if isRecording {
            value = recordingText?.isEmpty == false ? recordingText! : "Recording…"
        } else {
            value = row.current?.isEmpty == false ? row.current! : "Unassigned"
        }
        currentKeycap.setText(value, display: isRecording || row.current?.isEmpty != false ? value : ShortcutKeyDisplay.text(for: value))
        currentKeycap.setAccessibilityLabel("Current shortcut \(value)")
        currentKeycap.setAccessibilityValue(isRecording || row.current?.isEmpty != false ? value : ShortcutKeyDisplay.text(for: value))
        if !isRecording, let source = row.current, let input = ShortcutKeyDisplay.inputDescription(for: source) {
            currentKeycap.toolTip = "\(ShortcutKeyDisplay.text(for: source)) — Input: \(input)"
        }
        currentKeycap.apply(theme: theme, fixed: false)
    }

    private func updateControls() {
        let enabled = editingEnabled
        recordButton.isEnabled = enabled
        resetButton.isEnabled = enabled
        recordButton.title = "Record"
    }

    private func updateAppearance() {
        layer?.borderColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        let fill = isFlashing ? theme[.error].withAlphaComponent(0.24)
            : (isSelected ? theme[.accent].withAlphaComponent(0.30) : NSColor.clear)
        layer?.backgroundColor = fill.cgColor
        updateControls()
    }
}

@MainActor
private final class ShortcutSettingsKeycapView: NSView {
    private let label: NSTextField
    private var theme = AppKitTheme(themeID: .tokyoNight)
    private(set) var displayText: String

    init(text: String, identifier: String) {
        displayText = text
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier(identifier)
        label.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        label.prepareForAutoLayout()
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            heightAnchor.constraint(equalToConstant: 23),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func setText(_ text: String, display: String? = nil) {
        displayText = text
        label.stringValue = display ?? text
        toolTip = label.stringValue
    }

    func apply(theme: AppKitTheme, fixed: Bool) {
        self.theme = theme
        label.textColor = fixed ? theme[.mutedText] : theme[.foreground]
        layer?.backgroundColor = theme.canvasBackground.withAlphaComponent(0.9).cgColor
        layer?.borderColor = theme.separator.cgColor
    }
}
