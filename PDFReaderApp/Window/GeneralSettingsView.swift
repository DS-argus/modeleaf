import AppKit
import PDFReaderCore

/// The complete draft shown by the Settings shell. Numeric values intentionally
/// remain strings until the settings coordinator validates and applies them.
struct SettingsFormValues: Equatable, Sendable {
    var smallScrollPoints: String
    var largeScrollPercent: String
    var zoomFactor: String
    var prefixTimeoutMilliseconds: String
    var confirmExternalLinks: Bool

    init(
        smallScrollPoints: String = "32",
        largeScrollPercent: String = "80",
        zoomFactor: String = "1.10",
        prefixTimeoutMilliseconds: String = "400",
        confirmExternalLinks: Bool = true
    ) {
        self.smallScrollPoints = smallScrollPoints
        self.largeScrollPercent = largeScrollPercent
        self.zoomFactor = zoomFactor
        self.prefixTimeoutMilliseconds = prefixTimeoutMilliseconds
        self.confirmExternalLinks = confirmExternalLinks
    }
}

/// The General page of the Settings shell. It owns only editing controls;
/// validation, persistence, and conversion to the effective configuration stay
/// with the settings coordinator.
@MainActor
final class GeneralSettingsView: NSView, NSTextFieldDelegate {
    var onChanged: ((SettingsFormValues) -> Void)?
    var onRowSelected: ((Int) -> Void)?

    private let smallScrollPointsField = NSTextField(string: "")
    private let largeScrollPercentField = NSTextField(string: "")
    private let zoomFactorField = NSTextField(string: "")
    private let confirmExternalLinksButton = NSButton(title: "True", target: nil, action: nil)
    private let confirmExternalLinksLabel = NSTextField(labelWithString: "Confirm external links")
    private let confirmExternalLinksRow = NSStackView()
    private let contentStack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "General")
    private let subtitleLabel = NSTextField(labelWithString: "Reading and link behavior")
    private var fieldRows: [NSStackView] = []
    private var foregroundLabels: [NSTextField] = []
    private var mutedLabels: [NSTextField] = []
    private var theme = AppKitTheme(themeID: .tokyoNight)
    private var draft = SettingsFormValues()
    private var selectedRowIndex: Int?
    private var selectedRowIsActive = false
    private var editingRowIndex: Int?
    private var preeditValue: String?

    private(set) var validationMessage: String?

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 270)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("General settings")
        setAccessibilityIdentifier("settings.general")

        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.setAccessibilityIdentifier("settings.general.title")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.setAccessibilityIdentifier("settings.general.subtitle")

        configure(field: smallScrollPointsField, identifier: "settings.general.smallScrollPoints", label: "Small scroll", placeholder: "32")
        configure(field: largeScrollPercentField, identifier: "settings.general.largeScrollPercent", label: "Large scroll", placeholder: "80")
        configure(field: zoomFactorField, identifier: "settings.general.zoomFactor", label: "Zoom", placeholder: "1.10")

        confirmExternalLinksButton.setAccessibilityLabel("Confirm external links")
        confirmExternalLinksButton.setAccessibilityIdentifier("settings.general.confirmExternalLinks")
        confirmExternalLinksButton.setButtonType(.toggle)
        confirmExternalLinksButton.bezelStyle = .rounded
        confirmExternalLinksButton.controlSize = .regular
        confirmExternalLinksButton.focusRingType = .none
        confirmExternalLinksButton.target = self
        confirmExternalLinksButton.action = #selector(confirmExternalLinksChanged)
        confirmExternalLinksButton.setContentHuggingPriority(.required, for: .horizontal)
        confirmExternalLinksButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        confirmExternalLinksButton.widthAnchor.constraint(equalToConstant: 72).isActive = true
        confirmExternalLinksButton.heightAnchor.constraint(equalToConstant: 25).isActive = true

        confirmExternalLinksLabel.font = .systemFont(ofSize: 13, weight: .medium)
        confirmExternalLinksLabel.setAccessibilityIdentifier("settings.general.confirmExternalLinks.label")
        confirmExternalLinksLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        confirmExternalLinksLabel.lineBreakMode = .byTruncatingTail
        confirmExternalLinksLabel.toolTip = "Confirm external links"

        let scrollRow = makeFieldRow(
            field: smallScrollPointsField,
            unit: "pt",
            help: "1–512 points per small scroll"
        )
        let largeRow = makeFieldRow(
            field: largeScrollPercentField,
            unit: "%",
            help: "10–200% of the viewport"
        )
        let zoomRow = makeFieldRow(
            field: zoomFactorField,
            unit: "×",
            help: "1.01–2.00 magnification"
        )
        fieldRows = [scrollRow, largeRow, zoomRow]

        confirmExternalLinksRow.orientation = .horizontal
        confirmExternalLinksRow.alignment = .centerY
        confirmExternalLinksRow.spacing = 8
        let confirmationSpacer = NSView()
        confirmationSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        confirmationSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        confirmExternalLinksRow.addArrangedSubview(confirmExternalLinksLabel)
        confirmExternalLinksRow.addArrangedSubview(confirmExternalLinksButton)
        confirmExternalLinksRow.addArrangedSubview(confirmationSpacer)
        confirmationSpacer.heightAnchor.constraint(equalToConstant: 1).isActive = true
        confirmExternalLinksLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        confirmExternalLinksRow.setAccessibilityIdentifier("settings.general.confirmExternalLinks.row")
        confirmExternalLinksRow.prepareForAutoLayout()
        configureSelectableRow(confirmExternalLinksRow)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(subtitleLabel)
        contentStack.addArrangedSubview(scrollRow)
        contentStack.addArrangedSubview(largeRow)
        contentStack.addArrangedSubview(zoomRow)
        contentStack.addArrangedSubview(confirmExternalLinksRow)
        contentStack.prepareForAutoLayout()
        contentStack.setCustomSpacing(3, after: titleLabel)
        contentStack.setCustomSpacing(18, after: subtitleLabel)
        contentStack.setCustomSpacing(18, after: zoomRow)
        for row in fieldRows {
            row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
            titleLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            subtitleLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            confirmExternalLinksRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])

        apply(theme: theme)
        render(values: draft)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: Public contract

    func apply(theme: AppKitTheme) {
        self.theme = theme
        layer?.backgroundColor = theme[.activeTab].withAlphaComponent(0.72).cgColor
        titleLabel.textColor = theme[.accent]
        subtitleLabel.textColor = theme[.mutedText]
        for field in fields {
            field.textColor = theme[.foreground]
            field.backgroundColor = theme.canvasBackground
            field.focusRingType = .default
        }
        for label in foregroundLabels { label.textColor = theme[.foreground] }
        for label in mutedLabels { label.textColor = theme[.mutedText] }
        confirmExternalLinksLabel.textColor = theme[.foreground]
        confirmExternalLinksButton.contentTintColor = theme[.foreground]
        updateSelectionAppearance()
    }

    func render(values: SettingsFormValues) {
        draft = values
        setValueIfNotEditing(values.smallScrollPoints, in: smallScrollPointsField)
        setValueIfNotEditing(values.largeScrollPercent, in: largeScrollPercentField)
        setValueIfNotEditing(values.zoomFactor, in: zoomFactorField)
        confirmExternalLinksButton.state = values.confirmExternalLinks ? .on : .off
        renderConfirmationButton()
        validationMessage = nil
        renderAccessibilityValues()
        updateSelectionAppearance()
    }

    /// Focus order is explicit so shell Tab navigation remains deterministic.
    var orderedKeyViews: [NSView] {
        fields + [confirmExternalLinksButton]
    }

    var valuesForTesting: SettingsFormValues { currentValues }
    var smallScrollPointsFieldForTesting: NSTextField { smallScrollPointsField }
    var largeScrollPercentFieldForTesting: NSTextField { largeScrollPercentField }
    var zoomFactorFieldForTesting: NSTextField { zoomFactorField }
    var confirmExternalLinksButtonForTesting: NSButton { confirmExternalLinksButton }
    var confirmExternalLinksCheckboxForTesting: NSButton { confirmExternalLinksButton }

    func fieldForTesting(identifier: String) -> NSTextField? {
        fields.first { $0.accessibilityIdentifier() == identifier }
    }

    /// The shell uses this method when a General row becomes active without
    /// entering native text editing yet.
    func selectRow(_ index: Int?, active: Bool = true) {
        guard let index else {
            selectedRowIndex = nil
            selectedRowIsActive = false
            updateSelectionAppearance()
            return
        }
        guard allRows.indices.contains(index) else { return }
        selectedRowIndex = index
        selectedRowIsActive = active
        updateSelectionAppearance()
    }

    func beginNumericEditing(row index: Int) {
        guard fields.indices.contains(index) else { return }
        selectRow(index, active: true)
        let field = fields[index]
        editingRowIndex = index
        preeditValue = field.stringValue
        validationMessage = nil
        onRowSelected?(index)
        guard let window else { return }
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    @discardableResult
    func commitNumericEditing() -> Bool {
        guard let index = editingRowIndex, fields.indices.contains(index) else { return false }
        let text = fields[index].stringValue
        guard validNumericValue(text, row: index) else {
            validationMessage = validationMessage(for: index)
            renderAccessibilityValues()
            return false
        }
        editingRowIndex = nil
        preeditValue = nil
        validationMessage = nil
        window?.makeFirstResponder(self)
        updateDraftAndNotify()
        return true
    }

    func cancelNumericEditing() {
        guard let index = editingRowIndex, fields.indices.contains(index) else { return }
        if let preeditValue { fields[index].stringValue = preeditValue }
        editingRowIndex = nil
        self.preeditValue = nil
        validationMessage = nil
        renderAccessibilityValues()
        window?.makeFirstResponder(self)
    }

    func toggleConfirmationDraft() {
        guard editingRowIndex == nil else { return }
        selectRow(3, active: true)
        confirmExternalLinksButton.state = confirmExternalLinksButton.state == .on ? .off : .on
        renderConfirmationButton()
        updateDraftAndNotify()
    }

    var isEditingNumeric: Bool { editingRowIndex != nil }
    var selectedRowForNavigation: Int? { selectedRowIndex }

    // MARK: NSTextFieldDelegate

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let index = fields.firstIndex(where: { $0 === field }) else { return }
        if editingRowIndex == nil {
            editingRowIndex = index
            preeditValue = field.stringValue
        }
        selectRow(index, active: true)
        onRowSelected?(index)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              fields.contains(where: { $0 === field }) else { return }
        field.setAccessibilityValue(field.stringValue)
        renderAccessibilityValues()
        if editingRowIndex == fields.firstIndex(where: { $0 === field }) { return }
        updateDraftAndNotify()
    }

    // MARK: Private

    private var fields: [NSTextField] {
        [smallScrollPointsField, largeScrollPercentField, zoomFactorField]
    }

    private var allRows: [NSView] {
        fieldRows + [confirmExternalLinksRow]
    }

    private var currentValues: SettingsFormValues {
        var values = draft
        values.smallScrollPoints = smallScrollPointsField.stringValue
        values.largeScrollPercent = largeScrollPercentField.stringValue
        values.zoomFactor = zoomFactorField.stringValue
        values.confirmExternalLinks = confirmExternalLinksButton.state == .on
        return values
    }

    private func configure(field: NSTextField, identifier: String, label: String, placeholder: String) {
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.alignment = .right
        field.delegate = self
        field.setAccessibilityLabel(label)
        field.setAccessibilityIdentifier(identifier)
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        field.heightAnchor.constraint(equalToConstant: 25).isActive = true
        field.focusRingType = .none
    }

    private func configureSelectableRow(_ row: NSStackView) {
        row.wantsLayer = true
        row.layer?.cornerRadius = 5
        row.layer?.masksToBounds = true
    }

    private func makeFieldRow(field: NSTextField, unit: String, help: String) -> NSStackView {
        let label = NSTextField(labelWithString: field.accessibilityLabel() ?? "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = theme[.foreground]
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let unitLabel = NSTextField(labelWithString: unit)
        unitLabel.font = .systemFont(ofSize: 12)
        unitLabel.textColor = theme[.mutedText]
        unitLabel.setContentHuggingPriority(.required, for: .horizontal)
        unitLabel.setAccessibilityIdentifier("\(field.accessibilityIdentifier()).unit")

        let helpLabel = NSTextField(wrappingLabelWithString: "(\(help))")
        helpLabel.font = .systemFont(ofSize: 11)
        helpLabel.textColor = theme[.mutedText]
        helpLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        helpLabel.maximumNumberOfLines = 1
        helpLabel.lineBreakMode = .byClipping
        helpLabel.setAccessibilityIdentifier("\(field.accessibilityIdentifier()).help")

        let row = NSStackView(views: [label, field, unitLabel, helpLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.setAccessibilityIdentifier("\(field.accessibilityIdentifier()).row")
        row.prepareForAutoLayout()
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true
        configureSelectableRow(row)
        helpLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        foregroundLabels.append(label)
        mutedLabels.append(contentsOf: [unitLabel, helpLabel])
        return row
    }

    private func setValueIfNotEditing(_ value: String, in field: NSTextField) {
        guard editingRowIndex == nil, field.currentEditor() == nil, field.window?.firstResponder !== field else { return }
        field.stringValue = value
    }

    private func updateDraftAndNotify() {
        draft = currentValues
        renderAccessibilityValues()
        onChanged?(draft)
    }

    private func renderConfirmationButton() {
        confirmExternalLinksButton.title = confirmExternalLinksButton.state == .on ? "True" : "False"
        confirmExternalLinksButton.setAccessibilityValue(confirmExternalLinksButton.title)
    }

    private func renderAccessibilityValues() {
        smallScrollPointsField.setAccessibilityValue(smallScrollPointsField.stringValue)
        largeScrollPercentField.setAccessibilityValue(largeScrollPercentField.stringValue)
        zoomFactorField.setAccessibilityValue(zoomFactorField.stringValue)
        confirmExternalLinksButton.setAccessibilityValue(confirmExternalLinksButton.title)
    }

    private func updateSelectionAppearance() {
        for (index, row) in allRows.enumerated() {
            let selected = selectedRowIndex == index
            let alpha: CGFloat = selected && selectedRowIsActive ? 0.30 : selected ? 0.14 : 0
            row.layer?.backgroundColor = theme[.accent].withAlphaComponent(alpha).cgColor
        }
    }

    private func validNumericValue(_ text: String, row: Int) -> Bool {
        switch row {
        case 0:
            guard let value = Double(text), value.isFinite else { return false }
            return ConfigBounds.smallScrollPoints.contains(value)
        case 1:
            guard let value = Double(text), value.isFinite else { return false }
            return ConfigBounds.largeScrollViewportFraction.contains(value / 100)
        case 2:
            guard let value = Double(text), value.isFinite else { return false }
            return ConfigBounds.zoomFactor.contains(value)
        default:
            return false
        }
    }

    private func validationMessage(for row: Int) -> String {
        switch row {
        case 0: return "Small scroll must be 1–512 points."
        case 1: return "Large scroll must be 10–200% of the viewport."
        case 2: return "Zoom factor must be 1.01–2.0."
        default: return "Invalid numeric value."
        }
    }

    @objc private func confirmExternalLinksChanged() {
        selectRow(3, active: true)
        onRowSelected?(3)
        renderConfirmationButton()
        updateDraftAndNotify()
    }
}
