import AppKit
import PDFReaderCore

/// The sections shown by the official Settings shell.
enum SettingsOverlaySection: String, CaseIterable, Sendable {
    case general
    case keyboardShortcuts
}

/// A themed, two-section Settings host. The shell owns draft presentation and
/// keyboard focus; persistence and validation remain in the coordinator.
@MainActor
final class SettingsOverlayView: NSView, NSTextFieldDelegate {
    let shortcuts: ShortcutSettingsOverlayView
    let general: GeneralSettingsView

    var onApply: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onRestoreDefaults: (() -> Void)?
    var onClose: (() -> Void)?
    var onReload: (() -> Void)?
    var onGeneralChanged: ((SettingsFormValues) -> Void)?
    var onSectionChanged: ((SettingsOverlaySection) -> Void)?

    private enum FocusMode {
        case left
        case rightRow
    }

    private enum Metrics {
        static let preferredWidth: CGFloat = 680
        static let preferredHeight: CGFloat = 600
        static let sidebarWidth: CGFloat = 130
        static let inset: CGFloat = 16
        static let footerHintHeight: CGFloat = 18
        static let footerButtonHeight: CGFloat = 25
    }

    private let sidebar = NSStackView()
    private let sidebarTitle = NSTextField(labelWithString: "Settings")
    private let generalButton = ClosureButton(frame: .zero)
    private let keyboardButton = ClosureButton(frame: .zero)
    private let sidebarDivider = NSBox()
    private let contentHost = NSView()
    private let keyboardHeader = NSTextField(labelWithString: "Key Bindings")
    private let keyboardSubtitle = NSTextField(labelWithString: "Search and edit the active key bindings")
    private let keyboardContent = NSView()
    private let footerSeparator = NSBox()
    private let footerStatusLabel = NSTextField(labelWithString: "")
    private let footerHintLabel = NSTextField(labelWithString: "")
    private let footer = NSStackView()
    private let footerSpacer = NSView()
    private let reloadButton = ClosureButton(frame: .zero)
    private let restoreDefaultsButton = ClosureButton(frame: .zero)
    private let discardButton = ClosureButton(frame: .zero)
    private let applyButton = ClosureButton(frame: .zero)
    private let bodyStack = NSStackView()
    private let footerStack = NSStackView()
    private var preferredWidthConstraint: NSLayoutConstraint?
    private var generalConstraints: [NSLayoutConstraint] = []
    private var keyboardContentConstraints: [NSLayoutConstraint] = []
    private var preferredHeightConstraint: NSLayoutConstraint?
    private var theme = AppKitTheme(themeID: .tokyoNight)
    private var draft = SettingsFormValues()
    private(set) var selectedSection: SettingsOverlaySection = .general
    private var focusMode: FocusMode = .left
    private final class CloseFocusSnapshot {
        let focusMode: FocusMode
        let generalRowIndex: Int?
        let shortcutRowID: String?
        let searchIsEditing: Bool
        weak var responder: NSResponder?
        weak var responderOwner: NSView?

        init(focusMode: FocusMode, generalRowIndex: Int?, shortcutRowID: String?, searchIsEditing: Bool,
             responder: NSResponder?, responderOwner: NSView?) {
            self.focusMode = focusMode
            self.generalRowIndex = generalRowIndex
            self.shortcutRowID = shortcutRowID
            self.searchIsEditing = searchIsEditing
            self.responder = responder
            self.responderOwner = responderOwner
        }
    }

    private var closeFocusSnapshot: CloseFocusSnapshot?
    private var lastGeneralRowIndex = 0
    private var canApply = false
    private var isDirty = false
    private var blocked = false
    private var statusMessage: String?
    private var showsFocusIndicator = false
    private var restingBorderColor = NSColor.clear
    private var focusIndicatorColor = NSColor.clear

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Metrics.preferredWidth, height: Metrics.preferredHeight)
    }

    override init(frame frameRect: NSRect) {
        shortcuts = ShortcutSettingsOverlayView(frame: .zero, embedded: true)
        general = GeneralSettingsView(frame: .zero)
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

        let preferredWidth = widthAnchor.constraint(equalToConstant: Metrics.preferredWidth)
        let preferredHeight = heightAnchor.constraint(equalToConstant: Metrics.preferredHeight)
        preferredWidth.priority = .required
        preferredHeight.priority = .required
        NSLayoutConstraint.activate([preferredWidth, preferredHeight])
        preferredWidthConstraint = preferredWidth
        preferredHeightConstraint = preferredHeight

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Settings")
        setAccessibilityIdentifier("settingsOverlay")

        configureSidebar()
        configureKeyboardHeader()
        configureFooter()

        general.onChanged = { [weak self] values in
            guard let self else { return }
            self.draft = values
            self.notifyDraftChanged()
        }
        general.onRowSelected = { [weak self] index in
            guard let self else { return }
            self.lastGeneralRowIndex = index
            self.focusMode = .rightRow
            self.updateFocusSurface()
            self.renderFooter()
        }
        shortcuts.onRowSelected = { [weak self] _ in
            guard let self else { return }
            self.focusMode = .rightRow
            self.updateFocusSurface()
            self.renderFooter()
        }
        shortcuts.onPrefixTimeoutChanged = { [weak self] value in
            guard let self else { return }
            self.draft.prefixTimeoutMilliseconds = value
            self.notifyDraftChanged()
        }
        shortcuts.onApply = { [weak self] in self?.triggerApply() }
        shortcuts.onDiscard = { [weak self] in self?.onDiscard?() }
        shortcuts.onReload = { [weak self] in self?.onReload?() }
        shortcuts.onClose = { [weak self] in self?.onClose?() }

        apply(theme: theme)
        updateContentVisibility()
        updateButtonStates()
        render(values: draft, status: nil, canApply: false, isDirty: false, blocked: false)
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updatePreferredSize()
    }

    override func layout() {
        updatePreferredSize()
        super.layout()
    }

    func updatePreferredSize() {
        guard let host = superview else { return }
        preferredWidthConstraint?.priority = .required
        preferredHeightConstraint?.priority = .required
        preferredWidthConstraint?.constant = min(Metrics.preferredWidth, max(0, host.bounds.width - 32))
        preferredHeightConstraint?.constant = min(Metrics.preferredHeight, max(0, host.bounds.height - 24))
    }

    // MARK: Public contract

    func apply(theme: AppKitTheme) {
        self.theme = theme
        layer?.backgroundColor = theme[.activeTab].withAlphaComponent(0.98).cgColor
        restingBorderColor = theme.separator
        focusIndicatorColor = theme.focusRing
        shadow?.shadowColor = theme.overlayShadow
        appearance = NSAppearance(named: theme.id == .catppuccinLatte ? .aqua : .darkAqua)

        sidebarTitle.textColor = theme[.accent]
        sidebarDivider.borderColor = theme.separator
        footerSeparator.borderColor = theme.separator
        footerStatusLabel.textColor = theme[.mutedText]
        footerHintLabel.textColor = theme[.mutedText]
        keyboardHeader.textColor = theme[.accent]
        keyboardSubtitle.textColor = theme[.mutedText]
        general.apply(theme: theme)
        general.layer?.backgroundColor = NSColor.clear.cgColor
        keyboardContent.layer?.backgroundColor = NSColor.clear.cgColor
        shortcuts.apply(theme: theme)
        updateSidebarAppearance()
        updateFocusAppearance()
        renderFooter()
    }

    func present() {
        isHidden = false
        selectedSection = .general
        closeFocusSnapshot = nil
        focusMode = .left
        lastGeneralRowIndex = 0
        general.selectRow(nil)
        showsFocusIndicator = true
        shortcuts.present()
        updateContentVisibility()
        updateSidebarAppearance()
        updateFocusAppearance()
        updateButtonStates()
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(generalButton)
        renderFooter()
    }

    func dismiss() {
        if general.isEditingNumeric { general.cancelNumericEditing() }
        shortcuts.dismiss()
        closeFocusSnapshot = nil
        focusMode = .left
        showsFocusIndicator = false
        updateFocusAppearance()
        isHidden = true
    }

    var hasPendingEditorForClose: Bool {
        general.isEditingNumeric || shortcuts.isEditingPrefixTimeout
    }

    func runCloseConfirmation() -> SettingsCloseConfirmationView.Choice {
        captureCloseFocus()
        return SettingsCloseConfirmationView.runModal(
            attachedTo: window,
            theme: theme,
            ignoring: NSApp.currentEvent
        )
    }

    func restoreCloseFocusAfterConfirmation() {
        guard let snapshot = closeFocusSnapshot else { return }
        closeFocusSnapshot = nil
        focusMode = snapshot.focusMode
        if selectedSection == .general {
            general.selectRow(snapshot.generalRowIndex, active: focusMode == .rightRow)
            shortcuts.leaveRowModeForShell()
        } else {
            general.selectRow(nil)
            if !snapshot.searchIsEditing && !shortcuts.isEditingPrefixTimeout {
                if focusMode == .rightRow {
                    shortcuts.enterRowModeForShell(preferredRowID: snapshot.shortcutRowID)
                } else {
                    shortcuts.leaveRowModeForShell()
                }
            }
        }
        updateContentVisibility()
        updateSidebarAppearance()
        window?.makeKey()
        updateFocusSurface()
        updateKeyViewLoop()
        if let owner = snapshot.responderOwner, owner.window === window {
            window?.makeFirstResponder(owner)
        } else if let responder = snapshot.responder {
            window?.makeFirstResponder(responder)
        } else {
            window?.makeFirstResponder(selectedSection == .general ? generalButton : keyboardButton)
        }
        renderFooter()
    }

    func cancelEditingForClose() {
        if general.isEditingNumeric { general.cancelNumericEditing() }
        shortcuts.cancelEditingForShell()
        updateButtonStates()
        renderFooter()
    }

    func render(
        values: SettingsFormValues,
        status: String? = nil,
        canApply: Bool,
        isDirty: Bool,
        blocked: Bool = false
    ) {
        draft = values
        statusMessage = status
        self.canApply = canApply
        self.isDirty = isDirty
        self.blocked = blocked
        general.render(values: values)
        shortcuts.render(prefixTimeoutMilliseconds: values.prefixTimeoutMilliseconds)
        updateButtonStates()
        renderFooter()
    }

    func selectSection(_ section: SettingsOverlaySection) {
        selectedSection = section
        if general.isEditingNumeric { general.cancelNumericEditing() }
        shortcuts.cancelEditingForShell()
        focusMode = .left
        general.selectRow(nil)
        shortcuts.leaveRowModeForShell()
        updateContentVisibility()
        updateSidebarAppearance()
        updateFocusSurface()
        updateKeyViewLoop()
        onSectionChanged?(section)
        window?.makeFirstResponder(section == .general ? generalButton : keyboardButton)
        renderFooter()
    }

    /// The application window routes modal key events through this method. The
    /// shell owns LEFT/RIGHT transitions; child views only own text search,
    /// numeric editing, and the active recording session.
    func handleNavigation(_ event: NSEvent) -> Bool {
        if shortcuts.isRecording { return false }

        if general.isEditingNumeric {
            if isReturn(event) {
                _ = general.commitNumericEditing()
                updateButtonStates()
                renderFooter()
                return true
            }
            if event.keyCode == 53 {
                general.cancelNumericEditing()
                updateButtonStates()
                renderFooter()
                return true
            }
            return false
        }

        if selectedSection == .keyboardShortcuts,
           shortcuts.isEditingPrefixTimeout || shortcuts.ownsSearchInput {
            let handled = shortcuts.handleNavigation(event)
            if handled {
                focusMode = .rightRow
                updateFocusSurface()
                renderFooter()
            }
            return handled
        }

        if selectedSection == .keyboardShortcuts,
           isPlainSlash(event) {
            let handled = shortcuts.handleNavigation(event)
            if handled {
                focusMode = .rightRow
                updateFocusSurface()
                renderFooter()
            }
            return handled
        }


        if isFooterButtonFocused,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           [36, 76, 49].contains(event.keyCode),
           let button = window?.firstResponder as? NSButton {
            if button.isEnabled { button.performClick(nil) }
            return true
        }
        if event.keyCode == 48,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            return moveFocus(backwards: event.modifierFlags.contains(.shift))
        }

        switch focusMode {
        case .left:
            if isReturn(event) || isPlainCharacter(event, "l") {
                enterRight()
                return true
            }
            if event.keyCode == 53 {
                onClose?()
                return true
            }
            if isPlainCharacter(event, "j") { return moveSidebar(by: 1) }
            if isPlainCharacter(event, "k") { return moveSidebar(by: -1) }
            return false

        case .rightRow:
            if isPlainCharacter(event, "h") {
                returnToLeft()
                return true
            }
            if event.keyCode == 53 {
                onClose?()
                return true
            }
            if event.keyCode == 126 { moveSelectedRow(by: -1); return true }
            if event.keyCode == 125 { moveSelectedRow(by: 1); return true }
            if isPlainCharacter(event, "k") { moveSelectedRow(by: -1); return true }
            if isPlainCharacter(event, "j") { moveSelectedRow(by: 1); return true }
            if isReturn(event) {
                beginSelectedRowEditing()
                return true
            }
            if selectedSection == .keyboardShortcuts, isPlainCharacter(event, "r") {
                _ = shortcuts.resetSelectedRowForShell()
                renderFooter()
                return true
            }
            return false
        }

    }
    override func keyDown(with event: NSEvent) {
        if !handleNavigation(event) { super.keyDown(with: event) }
    }

    // MARK: Testing and focus surface

    var selectedSectionForTesting: SettingsOverlaySection { selectedSection }
    var generalButtonForTesting: NSButton { generalButton }
    var keyboardButtonForTesting: NSButton { keyboardButton }
    var timeoutFieldForTesting: NSTextField { shortcuts.prefixTimeoutFieldForTesting }
    var reloadButtonForTesting: NSButton { reloadButton }
    var restoreDefaultsButtonForTesting: NSButton { restoreDefaultsButton }
    var discardButtonForTesting: NSButton { discardButton }
    var applyButtonForTesting: NSButton { applyButton }
    var footerStatusForTesting: NSTextField { footerStatusLabel }
    var footerHintForTesting: NSTextField { footerHintLabel }
    var blockedForTesting: Bool { blocked }
    var isDirtyForTesting: Bool { isDirty }
    var valuesForTesting: SettingsFormValues { draft }
    var statusForTesting: String? { statusMessage }
    var canApplyForTesting: Bool { canApply }
    var orderedKeyViews: [NSView] {
        let controls: [NSView] = [generalButton, keyboardButton]
            + (selectedSection == .general ? general.orderedKeyViews : shortcuts.orderedKeyViews)
            + [reloadButton, restoreDefaultsButton, discardButton, applyButton]
        return controls.filter { !$0.isHidden && (($0 as? NSControl)?.isEnabled ?? true) }
    }

    // MARK: Layout

    private func configureSidebar() {
        sidebarTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        sidebarTitle.setAccessibilityIdentifier("settings.sidebar.title")
        sidebarTitle.setContentHuggingPriority(.required, for: .vertical)
        configureSidebarButton(generalButton, title: "General", identifier: "settings.sidebar.general")
        configureSidebarButton(keyboardButton, title: "Key Bindings", identifier: "settings.sidebar.keyboardShortcuts")
        generalButton.handler = { [weak self] in self?.selectSection(.general) }
        keyboardButton.handler = { [weak self] in self?.selectSection(.keyboardShortcuts) }

        sidebarDivider.boxType = .separator
        sidebarDivider.setAccessibilityIdentifier("settings.sidebar.separator")
        sidebarDivider.prepareForAutoLayout()

        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.distribution = .fill
        sidebar.spacing = 4
        sidebar.addArrangedSubview(sidebarTitle)
        sidebar.setCustomSpacing(18, after: sidebarTitle)
        sidebar.addArrangedSubview(generalButton)
        sidebar.addArrangedSubview(keyboardButton)
        sidebar.prepareForAutoLayout()
        sidebarTitle.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        generalButton.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        keyboardButton.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true

        let sidebarHost = NSView()
        sidebarHost.prepareForAutoLayout()
        sidebarHost.addSubview(sidebar)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: sidebarHost.topAnchor, constant: 24),
            sidebar.leadingAnchor.constraint(equalTo: sidebarHost.leadingAnchor, constant: 8),
            sidebar.trailingAnchor.constraint(equalTo: sidebarHost.trailingAnchor, constant: -8),
            sidebar.bottomAnchor.constraint(lessThanOrEqualTo: sidebarHost.bottomAnchor, constant: -18),
        ])

        contentHost.prepareForAutoLayout()
        contentHost.wantsLayer = true
        contentHost.layer?.backgroundColor = NSColor.clear.cgColor
        sidebarHost.addSubview(sidebarDivider)
        NSLayoutConstraint.activate([
            sidebarDivider.topAnchor.constraint(equalTo: sidebarHost.topAnchor),
            sidebarDivider.trailingAnchor.constraint(equalTo: sidebarHost.trailingAnchor),
            sidebarDivider.bottomAnchor.constraint(equalTo: sidebarHost.bottomAnchor),
            sidebarDivider.widthAnchor.constraint(equalToConstant: 1),
        ])

        configureKeyboardContent()
        contentHost.addSubview(general)
        contentHost.addSubview(keyboardContent)
        general.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        general.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        general.prepareForAutoLayout()
        keyboardContent.prepareForAutoLayout()
        generalConstraints = [
            general.topAnchor.constraint(equalTo: contentHost.topAnchor),
            general.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            general.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            general.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ]
        keyboardContentConstraints = [
            keyboardContent.topAnchor.constraint(equalTo: contentHost.topAnchor),
            keyboardContent.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            keyboardContent.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            keyboardContent.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ]
        // Both pages occupy the identical rectangle for the lifetime of the
        // popup. Switching sections must not change the layout constraint set.
        NSLayoutConstraint.activate(generalConstraints + keyboardContentConstraints)

        bodyStack.orientation = .horizontal
        bodyStack.alignment = .top
        bodyStack.distribution = .fill
        bodyStack.spacing = 0
        bodyStack.addArrangedSubview(sidebarHost)
        bodyStack.addArrangedSubview(contentHost)
        sidebarHost.widthAnchor.constraint(equalToConstant: Metrics.sidebarWidth).isActive = true
        sidebarHost.heightAnchor.constraint(equalTo: bodyStack.heightAnchor).isActive = true
        contentHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentHost.heightAnchor.constraint(equalTo: bodyStack.heightAnchor).isActive = true
        bodyStack.prepareForAutoLayout()
    }

    private func configureSidebarButton(_ button: ClosureButton, title: String, identifier: String) {
        button.title = title
        button.font = .systemFont(ofSize: 12.5)
        button.alignment = .left
        button.isBordered = false
        button.focusRingType = .none
        button.controlSize = .regular
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.layer?.masksToBounds = true
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(identifier)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        button.prepareForAutoLayout()
    }

    private func configureKeyboardHeader() {
        keyboardHeader.font = .systemFont(ofSize: 17, weight: .semibold)
        keyboardHeader.setAccessibilityIdentifier("settings.keyboard.title")
        keyboardSubtitle.font = .systemFont(ofSize: 12)
        keyboardSubtitle.setAccessibilityIdentifier("settings.keyboard.subtitle")
        for view in [keyboardHeader, keyboardSubtitle] { view.prepareForAutoLayout() }
    }

    private func configureKeyboardContent() {
        let headerStack = NSStackView(views: [keyboardHeader, keyboardSubtitle])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4
        headerStack.prepareForAutoLayout()
        keyboardContent.addSubview(headerStack)
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: keyboardContent.topAnchor, constant: 20),
            headerStack.leadingAnchor.constraint(equalTo: keyboardContent.leadingAnchor, constant: 20),
            headerStack.trailingAnchor.constraint(equalTo: keyboardContent.trailingAnchor, constant: -20),
        ])
        shortcuts.prepareForAutoLayout()
        keyboardContent.addSubview(shortcuts)
        NSLayoutConstraint.activate([
            shortcuts.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 8),
            shortcuts.leadingAnchor.constraint(equalTo: keyboardContent.leadingAnchor),
            shortcuts.trailingAnchor.constraint(equalTo: keyboardContent.trailingAnchor),
            shortcuts.bottomAnchor.constraint(equalTo: keyboardContent.bottomAnchor),
        ])
    }

    private func configureFooter() {
        footerSeparator.boxType = .separator
        footerSeparator.setAccessibilityIdentifier("settings.footerSeparator")
        footerSeparator.prepareForAutoLayout()

        footerStatusLabel.font = .systemFont(ofSize: 11)
        footerStatusLabel.maximumNumberOfLines = 1
        footerStatusLabel.lineBreakMode = .byTruncatingTail
        footerStatusLabel.setAccessibilityLabel("Settings status")
        footerStatusLabel.setAccessibilityIdentifier("settings.status")
        footerStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerStatusLabel.prepareForAutoLayout()

        footerHintLabel.font = .systemFont(ofSize: 10)
        footerHintLabel.maximumNumberOfLines = 1
        footerHintLabel.lineBreakMode = .byTruncatingTail
        footerHintLabel.setAccessibilityLabel("Settings keyboard hints")
        footerHintLabel.setAccessibilityIdentifier("settings.hint")
        footerHintLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        footerHintLabel.prepareForAutoLayout()

        configureFooterButton(reloadButton, title: "Reload saved settings", identifier: "settings.reload")
        configureFooterButton(restoreDefaultsButton, title: "Restore Defaults", identifier: "settings.restoreDefaults")
        configureFooterButton(discardButton, title: "Discard", identifier: "settings.discard")
        configureFooterButton(applyButton, title: "Apply", identifier: "settings.apply")
        reloadButton.handler = { [weak self] in self?.onReload?() }
        restoreDefaultsButton.handler = { [weak self] in self?.onRestoreDefaults?() }
        discardButton.handler = { [weak self] in self?.onDiscard?() }
        applyButton.handler = { [weak self] in self?.onApply?() }

        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        footer.addArrangedSubview(footerSpacer)
        footer.addArrangedSubview(reloadButton)
        footer.addArrangedSubview(restoreDefaultsButton)
        footer.addArrangedSubview(discardButton)
        footer.addArrangedSubview(applyButton)
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerSpacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 1).isActive = true
        footerSpacer.heightAnchor.constraint(equalToConstant: 1).isActive = true
        footer.prepareForAutoLayout()

        footerStack.orientation = .vertical
        footerStack.alignment = .leading
        footerStack.spacing = 4
        footerStack.addArrangedSubview(footerSeparator)
        footerStack.addArrangedSubview(footerHintLabel)
        footerStack.addArrangedSubview(footer)
        footerStack.prepareForAutoLayout()

        footerStack.addSubview(footerStatusLabel)
        NSLayoutConstraint.activate([
            footerSeparator.widthAnchor.constraint(equalTo: footerStack.widthAnchor),
            footerSeparator.heightAnchor.constraint(equalToConstant: 1),
            footerStatusLabel.leadingAnchor.constraint(equalTo: footerHintLabel.leadingAnchor),
            footerStatusLabel.trailingAnchor.constraint(equalTo: footerHintLabel.trailingAnchor),
            footerStatusLabel.topAnchor.constraint(equalTo: footerHintLabel.topAnchor),
            footerStatusLabel.heightAnchor.constraint(equalToConstant: Metrics.footerHintHeight),
            footerStack.heightAnchor.constraint(equalToConstant: 52),
            footerHintLabel.widthAnchor.constraint(equalTo: footerStack.widthAnchor),
            footerHintLabel.heightAnchor.constraint(equalToConstant: Metrics.footerHintHeight),
            footer.widthAnchor.constraint(equalTo: footerStack.widthAnchor),
            footer.heightAnchor.constraint(equalToConstant: Metrics.footerButtonHeight),
            reloadButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            restoreDefaultsButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 118),
            discardButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 68),
            applyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 55),
        ])

        bodyStack.setContentHuggingPriority(.defaultLow, for: .vertical)
        footerStack.setContentHuggingPriority(.required, for: .vertical)
        addSubview(bodyStack)
        addSubview(footerStack)
        NSLayoutConstraint.activate([
            bodyStack.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.inset),
            bodyStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
            bodyStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.inset),
            bodyStack.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -8),
            bodyStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            footerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
            footerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.inset),
            footerStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.inset),
        ])
    }

    private func configureFooterButton(_ button: ClosureButton, title: String, identifier: String) {
        button.title = title
        button.controlSize = .small
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(identifier)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.heightAnchor.constraint(equalToConstant: Metrics.footerButtonHeight).isActive = true
        button.keyEquivalent = ""
        button.prepareForAutoLayout()
    }

    // MARK: Rendering and focus

    private func updateContentVisibility() {
        let showingKeyboard = selectedSection == .keyboardShortcuts
        general.isHidden = showingKeyboard
        keyboardContent.isHidden = !showingKeyboard
        shortcuts.isHidden = !showingKeyboard
    }

    private func updateSidebarAppearance() {
        let generalSelected = selectedSection == .general
        let keyboardSelected = selectedSection == .keyboardShortcuts
        let sidebarFocused = focusMode == .left
        generalButton.contentTintColor = generalSelected ? theme[.accent] : theme[.foreground]
        keyboardButton.contentTintColor = keyboardSelected ? theme[.accent] : theme[.foreground]
        generalButton.font = .systemFont(ofSize: 12.5, weight: generalSelected ? .semibold : .regular)
        keyboardButton.font = .systemFont(ofSize: 12.5, weight: keyboardSelected ? .semibold : .regular)
        generalButton.layer?.backgroundColor = generalSelected && sidebarFocused ? theme[.accent].withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor
        keyboardButton.layer?.backgroundColor = keyboardSelected && sidebarFocused ? theme[.accent].withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor

    }
    private func updateButtonStates() {
        reloadButton.isHidden = !blocked
        reloadButton.isEnabled = blocked
        let editing = !shortcuts.isRecording && !general.isEditingNumeric && !shortcuts.isEditingPrefixTimeout
        applyButton.isEnabled = canApply && isDirty && !blocked && editing
        discardButton.isEnabled = isDirty && !blocked && editing
        restoreDefaultsButton.isEnabled = !blocked && editing
        updateKeyViewLoop()
    }

    private func renderFooter() {
        let localMessage: String? = selectedSection == .general
            ? general.validationMessage
            : shortcuts.validationMessageForParent
        let message = localMessage ?? statusMessage
        footerStatusLabel.stringValue = message ?? ""
        footerStatusLabel.isHidden = message?.isEmpty != false
        footerStatusLabel.textColor = localMessage == nil ? theme[.mutedText] : theme[.error]

        let hint: (String, [String])
        if general.isEditingNumeric || shortcuts.isEditingPrefixTimeout {
            hint = ("↩  Commit    Esc  Cancel", ["↩", "Esc"])
        } else if shortcuts.isRecording {
            hint = ("↩  Finish    Esc  Cancel", ["↩", "Esc"])
        } else if shortcuts.ownsSearchInput {
            hint = ("↩ / Esc  Leave search", ["↩ / Esc"])
        } else {
            switch focusMode {
            case .left:
                hint = ("j / k  Section    l / ↩  Open    Esc  Close", ["j / k", "l / ↩", "Esc"])
            case .rightRow:
                hint = selectedSection == .keyboardShortcuts
                    ? ("h  Left    j / k / ↑ / ↓  Move row    ↩  Edit / Record    Esc  Close    r  Reset", ["h", "j / k / ↑ / ↓", "↩", "Esc", "r"])
                    : ("h  Left    j / k / ↑ / ↓  Move row    ↩  Edit / Toggle    Esc  Close", ["h", "j / k / ↑ / ↓", "↩", "Esc"])
            }
        }
        footerHintLabel.attributedStringValue = SettingsKeyboardHint.make(text: hint.0, keys: hint.1, theme: theme)
        footerHintLabel.alphaValue = message?.isEmpty == false ? 0 : 1
    }


    private func updateFocusAppearance() {
        layer?.borderColor = (showsFocusIndicator ? focusIndicatorColor : restingBorderColor).cgColor
        layer?.borderWidth = 1
    }

    private func updateFocusSurface() {
        updateSidebarAppearance()
        if selectedSection == .general {
            general.selectRow(general.selectedRowForNavigation, active: focusMode == .rightRow)
        } else {
            general.selectRow(nil)
        }
        updateButtonStates()
        renderFooter()
    }

    private var isFooterButtonFocused: Bool {
        guard let responder = window?.firstResponder as? NSButton else { return false }
        return [reloadButton, restoreDefaultsButton, discardButton, applyButton].contains { $0 === responder }
    }

    private func updateKeyViewLoop() {
        let controls = orderedKeyViews
        guard !controls.isEmpty else { return }
        for (current, next) in zip(controls, controls.dropFirst()) {
            current.nextKeyView = next
        }
        controls.last?.nextKeyView = nil
    }

    private func moveFocus(backwards: Bool) -> Bool {
        guard let window else { return false }
        let controls = orderedKeyViews.filter { !$0.isHiddenOrHasHiddenAncestor && $0.acceptsFirstResponder }
        guard !controls.isEmpty else { return true }
        let responder = window.firstResponder
        let current: NSResponder?
        if let field = general.orderedKeyViews.compactMap({ $0 as? NSTextField }).first(where: { $0.currentEditor() === responder }) {
            current = field
        } else if shortcuts.prefixTimeoutFieldForTesting.currentEditor() === responder {
            current = shortcuts.prefixTimeoutFieldForTesting
        } else if shortcuts.searchFieldForTesting.currentEditor() === responder {
            current = shortcuts.searchFieldForTesting
        } else {
            current = responder
        }
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

    // MARK: State transitions
    private func captureCloseFocus() {
        let responder = window?.firstResponder
        var owner = responder as? NSView
        if let responder {
            if let field = general.orderedKeyViews.compactMap({ $0 as? NSTextField }).first(where: { $0.currentEditor() === responder }) {
                owner = field
            } else if shortcuts.prefixTimeoutFieldForTesting.currentEditor() === responder {
                owner = shortcuts.prefixTimeoutFieldForTesting
            } else if shortcuts.searchFieldForTesting.currentEditor() === responder {
                owner = shortcuts.searchFieldForTesting
            }
        }
        closeFocusSnapshot = CloseFocusSnapshot(
            focusMode: focusMode,
            generalRowIndex: general.selectedRowForNavigation,
            shortcutRowID: shortcuts.selectedRowIDValue,
            searchIsEditing: shortcuts.ownsSearchInput,
            responder: responder,
            responderOwner: owner
        )
    }


    private func enterRight() {
        focusMode = .rightRow
        if selectedSection == .general {
            lastGeneralRowIndex = 0
            general.selectRow(lastGeneralRowIndex, active: true)
            window?.makeFirstResponder(general)
        } else {
            shortcuts.enterFirstRowModeForShell()
        }
        updateFocusSurface()
    }

    private func returnToLeft() {
        if selectedSection == .general {
            general.selectRow(nil)
        } else {
            shortcuts.leaveRowModeForShell()
        }
        focusMode = .left
        window?.makeFirstResponder(selectedSection == .general ? generalButton : keyboardButton)
        updateFocusSurface()
    }


    private func moveSelectedRow(by offset: Int) {
        if selectedSection == .general {
            let current = general.selectedRowForNavigation ?? lastGeneralRowIndex
            lastGeneralRowIndex = min(max(current + offset.signum(), 0), 3)
            general.selectRow(lastGeneralRowIndex, active: true)
            window?.makeFirstResponder(general)
        } else {
            _ = shortcuts.moveSelectionForShell(by: offset)
        }
        updateFocusSurface()
    }

    private func beginSelectedRowEditing() {
        if selectedSection == .general {
            let index = general.selectedRowForNavigation ?? lastGeneralRowIndex
            if index < 3 {
                general.beginNumericEditing(row: index)
            } else {
                general.toggleConfirmationDraft()
            }
        } else {
            _ = shortcuts.beginEditingSelectedRowForShell()
        }
        updateButtonStates()
        renderFooter()
    }

    private func moveSidebar(by offset: Int) -> Bool {
        let target: SettingsOverlaySection = selectedSection == .general
            ? (offset > 0 ? .keyboardShortcuts : .general)
            : (offset < 0 ? .general : .keyboardShortcuts)
        selectSection(target)
        return true
    }

    private func triggerApply() {
        guard applyButton.isEnabled else { return }
        onApply?()
    }

    private func notifyDraftChanged() {
        onGeneralChanged?(draft)
    }

    private func isReturn(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        return [36, 76].contains(event.keyCode)
    }

    private func isPlainCharacter(_ event: NSEvent, _ character: String) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == character
    }

    private func isPlainSlash(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        return event.keyCode == 44 || event.charactersIgnoringModifiers == "/"
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === shortcuts.prefixTimeoutFieldForTesting else { return }
        shortcuts.controlTextDidChange(notification)
    }
}
