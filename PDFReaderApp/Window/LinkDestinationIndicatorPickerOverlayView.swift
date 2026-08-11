import AppKit
import PDFReaderCore

@MainActor
final class LinkDestinationIndicatorPickerOverlayView: NSView {
    private enum Column: Int, CaseIterable {
        case style
        case color
        case size
        case duration

        var title: String {
            switch self {
            case .style: "STYLE"
            case .color: "COLOR"
            case .size: "SIZE"
            case .duration: "DURATION"
            }
        }
    }

    private enum Metrics {
        static let columnWidth: CGFloat = 91
        static let dividerGap: CGFloat = 4
        static let columnHeight: CGFloat = 186
    }

    private static let keyHintText = "Tab,l  Next    ⇧Tab,h  Previous    j,k  Select / Adjust    ↩  Apply    Esc  Cancel"
    private static let shortcutLabels = ["Tab,l", "⇧Tab,h", "j,k", "↩", "Esc"]
    private static let colorPresets: [LinkDestinationIndicatorColorPreset] = [.red, .amber, .cyan, .green, .purple]
    private static let styleNames: [LinkDestinationIndicatorStyle: String] = [
        .pulseRing: "Pulse Ring",
        .target: "Target",
        .beacon: "Beacon",
        .staticRing: "Static Ring",
        .diamondPulse: "Diamond Pulse",
    ]
    private static let colorNames: [LinkDestinationIndicatorColorPreset: String] = [
        .red: "Red",
        .amber: "Amber",
        .cyan: "Cyan",
        .green: "Green",
        .purple: "Purple",
    ]

    var onPreview: ((LinkDestinationIndicatorSettings) -> Void)?
    var onCommit: ((LinkDestinationIndicatorSettings) -> Void)?
    var onCancel: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Link Indicator")
    private let previewHost = NSView()
    private let previewIndicator = LinkDestinationIndicatorView(frame: .zero)
    private let keyHintLabel = NSTextField(labelWithString: LinkDestinationIndicatorPickerOverlayView.keyHintText)
    private let sizeBar = VerticalValueBarView()
    private let durationBar = VerticalValueBarView()
    private var columnViews: [NSView] = []
    private var columnTitles: [NSTextField] = []
    private var columnDividers: [NSBox] = []
    private var styleRows: [PickerOptionTextField] = []
    private var colorRows: [PickerOptionTextField] = []

    private var selectedColumn = Column.style
    private var selectedStyleIndex = 0
    private var selectedColorIndex = 0
    private var selectedSettings = LinkDestinationIndicatorSettings.standard
    private var theme = AppKitTheme(themeID: .tokyoNight)
    private var restingBorderColor = NSColor.clear
    private var focusIndicatorColor = NSColor.clear
    private var showsFocusIndicator = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = WindowVisualMetrics.cornerRadius
        layer?.masksToBounds = false
        shadow = NSShadow()
        shadow?.shadowBlurRadius = 16
        shadow?.shadowOffset = NSSize(width: 0, height: -4)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Link destination indicator settings")
        setAccessibilityIdentifier("linkIndicatorPickerOverlay")

        titleLabel.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        keyHintLabel.maximumNumberOfLines = 1
        keyHintLabel.lineBreakMode = .byTruncatingTail
        keyHintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keyHintLabel.setAccessibilityIdentifier("linkIndicator.keyHint")


        previewHost.wantsLayer = true
        previewHost.layer?.cornerRadius = 5
        previewHost.layer?.borderWidth = 1
        previewHost.setAccessibilityLabel("Selected indicator style preview")
        previewIndicator.prepareForAutoLayout()
        previewHost.addSubview(previewIndicator)
        NSLayoutConstraint.activate([
            previewIndicator.topAnchor.constraint(equalTo: previewHost.topAnchor),
            previewIndicator.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
            previewIndicator.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
            previewIndicator.bottomAnchor.constraint(equalTo: previewHost.bottomAnchor),
        ])
        styleRows = LinkDestinationIndicatorStyle.allCases.map {
            makeRow(Self.styleNames[$0] ?? $0.rawValue)
        }
        colorRows = Self.colorPresets.map {
            makeRow(Self.colorNames[$0] ?? $0.rawValue)
        }
        for (index, row) in styleRows.enumerated() {
            row.onActivate = { [weak self] in self?.selectStyle(at: index) }
        }
        for (index, row) in colorRows.enumerated() {
            row.onActivate = { [weak self] in self?.selectColor(at: index) }
        }

        let styleColumn = makeColumn(.style)
        let colorColumn = makeColumn(.color)
        let sizeColumn = makeColumn(.size)
        let durationColumn = makeColumn(.duration)
        columnViews = [styleColumn, colorColumn, sizeColumn, durationColumn]
        installRows(styleRows, in: styleColumn, top: 42, spacing: 5)
        installRows(colorRows, in: colorColumn, top: 42, spacing: 7)

        sizeBar.prepareForAutoLayout()
        durationBar.prepareForAutoLayout()
        sizeColumn.addSubview(sizeBar)
        durationColumn.addSubview(durationBar)
        NSLayoutConstraint.activate([
            sizeBar.centerXAnchor.constraint(equalTo: sizeColumn.centerXAnchor),
            sizeBar.topAnchor.constraint(equalTo: sizeColumn.topAnchor, constant: 38),
            sizeBar.widthAnchor.constraint(equalToConstant: 88),
            sizeBar.heightAnchor.constraint(equalToConstant: 142),
            durationBar.centerXAnchor.constraint(equalTo: durationColumn.centerXAnchor),
            durationBar.topAnchor.constraint(equalTo: durationColumn.topAnchor, constant: 38),
            durationBar.widthAnchor.constraint(equalToConstant: 88),
            durationBar.heightAnchor.constraint(equalToConstant: 142),
        ])
        sizeBar.onValueChanged = { [weak self] value in
            guard let self else { return }
            self.selectedColumn = .size
            self.replaceSettings(size: value.rounded())
        }
        durationBar.onValueChanged = { [weak self] value in
            guard let self else { return }
            self.selectedColumn = .duration
            self.replaceSettings(durationMilliseconds: self.clampedDuration(Int((value / 100).rounded()) * 100))
        }

        columnDividers = (0..<3).map { _ in
            let divider = NSBox()
            divider.boxType = .separator
            divider.prepareForAutoLayout()
            addSubview(divider)
            return divider
        }

        for view in [titleLabel, previewHost, keyHintLabel] + columnViews {
            view.prepareForAutoLayout()
            addSubview(view)
        }
        let firstDivider = columnDividers[0]
        let secondDivider = columnDividers[1]
        let thirdDivider = columnDividers[2]
        NSLayoutConstraint.activate([
            previewHost.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            previewHost.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            previewHost.widthAnchor.constraint(equalToConstant: 34),
            previewHost.heightAnchor.constraint(equalToConstant: 34),
            titleLabel.centerYAnchor.constraint(equalTo: previewHost.centerYAnchor),

            styleColumn.topAnchor.constraint(equalTo: previewHost.bottomAnchor, constant: 5),
            styleColumn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            firstDivider.leadingAnchor.constraint(equalTo: styleColumn.trailingAnchor, constant: Metrics.dividerGap),
            colorColumn.leadingAnchor.constraint(equalTo: firstDivider.trailingAnchor, constant: Metrics.dividerGap),
            secondDivider.leadingAnchor.constraint(equalTo: colorColumn.trailingAnchor, constant: Metrics.dividerGap),
            sizeColumn.leadingAnchor.constraint(equalTo: secondDivider.trailingAnchor, constant: Metrics.dividerGap),
            thirdDivider.leadingAnchor.constraint(equalTo: sizeColumn.trailingAnchor, constant: Metrics.dividerGap),
            durationColumn.leadingAnchor.constraint(equalTo: thirdDivider.trailingAnchor, constant: Metrics.dividerGap),
            durationColumn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            colorColumn.topAnchor.constraint(equalTo: styleColumn.topAnchor),
            sizeColumn.topAnchor.constraint(equalTo: styleColumn.topAnchor),
            durationColumn.topAnchor.constraint(equalTo: styleColumn.topAnchor),
            firstDivider.topAnchor.constraint(equalTo: styleColumn.topAnchor, constant: 6),
            secondDivider.topAnchor.constraint(equalTo: firstDivider.topAnchor),
            thirdDivider.topAnchor.constraint(equalTo: firstDivider.topAnchor),
            firstDivider.bottomAnchor.constraint(equalTo: styleColumn.bottomAnchor, constant: -6),
            secondDivider.bottomAnchor.constraint(equalTo: firstDivider.bottomAnchor),
            thirdDivider.bottomAnchor.constraint(equalTo: firstDivider.bottomAnchor),
            firstDivider.widthAnchor.constraint(equalToConstant: 1),
            secondDivider.widthAnchor.constraint(equalToConstant: 1),
            thirdDivider.widthAnchor.constraint(equalToConstant: 1),

            keyHintLabel.topAnchor.constraint(equalTo: styleColumn.bottomAnchor, constant: 7),
            keyHintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            keyHintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            keyHintLabel.heightAnchor.constraint(equalToConstant: 16),
            keyHintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        isHidden = true
        apply(theme: theme)
        updatePresentation()
    }

    required init?(coder: NSCoder) { nil }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        layer?.backgroundColor = theme[.activeTab].withAlphaComponent(0.97).cgColor
        restingBorderColor = theme.separator
        focusIndicatorColor = theme.focusRing
        shadow?.shadowColor = theme.overlayShadow
        titleLabel.textColor = theme[.accent]
        previewHost.layer?.backgroundColor = theme.canvasBackground.cgColor
        previewHost.layer?.borderColor = theme.separator.cgColor
        columnDividers.forEach { $0.borderColor = theme.separator }
        sizeBar.apply(theme: theme)
        durationBar.apply(theme: theme)
        renderKeyHint()
        updateFocusAppearance()
        updatePresentation()
        renderStylePreview()
    }

    func present(settings: LinkDestinationIndicatorSettings) {
        selectedStyleIndex = LinkDestinationIndicatorStyle.allCases.firstIndex(of: settings.style) ?? 0
        let visibleColor: LinkDestinationIndicatorColorPreset
        if case let .preset(preset) = settings.color, Self.colorPresets.contains(preset) {
            visibleColor = preset
        } else {
            visibleColor = .red
        }
        selectedColorIndex = Self.colorPresets.firstIndex(of: visibleColor) ?? 0
        selectedSettings = LinkDestinationIndicatorSettings(
            style: settings.style,
            color: .preset(visibleColor),
            size: settings.size,
            durationMilliseconds: settings.durationMilliseconds
        )
        selectedColumn = .style
        isHidden = false
        setFocusAppearance(true)
        updatePresentation()
        renderStylePreview()
    }

    func dismiss() {
        previewIndicator.cancel()
        setFocusAppearance(false)
        isHidden = true
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 76:
            onCommit?(selectedSettings)
            return true
        case 53:
            onCancel?()
            return true
        case 48:
            moveColumn(by: event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        case 123:
            moveColumn(by: -1)
            return true
        case 124:
            moveColumn(by: 1)
            return true
        case 125:
            adjustSelection(by: 1)
            return true
        case 126:
            adjustSelection(by: -1)
            return true
        default:
            break
        }

        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let character = event.charactersIgnoringModifiers?.lowercased()
        else { return true }
        switch character {
        case "h": moveColumn(by: -1)
        case "l": moveColumn(by: 1)
        case "j": adjustSelection(by: 1)
        case "k": adjustSelection(by: -1)
        case "r": resetPressed()
        default: break
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        _ = handleKeyDown(event)
    }

    func setFocusAppearance(_ focused: Bool) {
        showsFocusIndicator = focused
        updateFocusAppearance()
    }

    var initialFocusView: NSView { self }
    var selectedSettingsForTesting: LinkDestinationIndicatorSettings { selectedSettings }
    var applyEnabledForTesting: Bool { true }
    var selectedColumnForTesting: String { selectedColumn.title }
    var visibleStylesForTesting: [String] { styleRows.map(\.stringValue) }
    var visibleColorsForTesting: [String] { colorRows.map(\.stringValue) }
    var sizeBarPositionForTesting: Double { sizeBar.normalizedPosition }
    var durationBarPositionForTesting: Double { durationBar.normalizedPosition }
    var keyHintAttributedForTesting: NSAttributedString { keyHintLabel.attributedStringValue }

    var dividerCountForTesting: Int { columnDividers.count }
    var previewStyleForTesting: LinkDestinationIndicatorStyle { previewIndicator.settingsForTesting.style }
    var previewHostSizeForTesting: NSSize { previewHost.bounds.size }
    var columnHeaderFontSizeForTesting: CGFloat { columnTitles.first?.font?.pointSize ?? 0 }
    var styleRowsAreCenteredForTesting: Bool { styleRows.allSatisfy { $0.alignment == .center } }
    func pointerSelectStyleForTesting(at index: Int) { styleRows[index].onActivate?() }
    func pointerSelectColorForTesting(at index: Int) { colorRows[index].onActivate?() }
    func pointerSetSizeForTesting(normalized: Double) { sizeBar.setNormalizedForTesting(normalized) }
    func pointerSetDurationForTesting(normalized: Double) { durationBar.setNormalizedForTesting(normalized) }
    func selectStyleForTesting(_ style: LinkDestinationIndicatorStyle) {
        selectedStyleIndex = LinkDestinationIndicatorStyle.allCases.firstIndex(of: style) ?? 0
        replaceSettings(style: style)
    }
    func selectColorForTesting(_ color: LinkDestinationIndicatorColor) {
        guard case let .preset(preset) = color,
              let index = Self.colorPresets.firstIndex(of: preset)
        else { return }
        selectedColorIndex = index
        replaceSettings(color: .preset(preset))
    }
    func setSizeForTesting(_ value: Double) { replaceSettings(size: value.rounded()) }
    func setDurationForTesting(_ milliseconds: Int) {
        replaceSettings(durationMilliseconds: clampedDuration(milliseconds))
    }
    func pressResetForTesting() { resetPressed() }
    func pressApplyForTesting() { onCommit?(selectedSettings) }
    func pressCancelForTesting() { onCancel?() }

    private func makeColumn(_ column: Column) -> NSView {
        let container = NSView()
        container.prepareForAutoLayout()
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityLabel(column.title.capitalized)

        let heading = NSTextField(labelWithString: column.title)
        heading.font = .monospacedSystemFont(ofSize: 12.5, weight: .bold)
        heading.alignment = .center
        heading.prepareForAutoLayout()
        columnTitles.append(heading)
        container.addSubview(heading)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Metrics.columnWidth),
            container.heightAnchor.constraint(equalToConstant: Metrics.columnHeight),
            heading.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            heading.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            heading.heightAnchor.constraint(equalToConstant: 17),
        ])
        return container
    }

    private func installRows(_ rows: [PickerOptionTextField], in container: NSView, top: CGFloat, spacing: CGFloat) {
        var previous: PickerOptionTextField?
        for row in rows {
            row.prepareForAutoLayout()
            container.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 3),
                row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -3),
                row.heightAnchor.constraint(equalToConstant: 22),
                previous.map { row.topAnchor.constraint(equalTo: $0.bottomAnchor, constant: spacing) }
                    ?? row.topAnchor.constraint(equalTo: container.topAnchor, constant: top),
            ])
            previous = row
        }
    }

    private func makeRow(_ text: String) -> PickerOptionTextField {
        let label = PickerOptionTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func selectStyle(at index: Int) {
        guard LinkDestinationIndicatorStyle.allCases.indices.contains(index) else { return }
        selectedColumn = .style
        selectedStyleIndex = index
        replaceSettings(style: LinkDestinationIndicatorStyle.allCases[index])
    }

    private func selectColor(at index: Int) {
        guard Self.colorPresets.indices.contains(index) else { return }
        selectedColumn = .color
        selectedColorIndex = index
        replaceSettings(color: .preset(Self.colorPresets[index]))
    }

    private func moveColumn(by delta: Int) {
        let columns = Column.allCases
        selectedColumn = columns[(selectedColumn.rawValue + delta + columns.count) % columns.count]
        updatePresentation()
    }

    private func adjustSelection(by delta: Int) {
        switch selectedColumn {
        case .style:
            let styles = LinkDestinationIndicatorStyle.allCases
            selectedStyleIndex = min(max(selectedStyleIndex + delta, 0), styles.count - 1)
            replaceSettings(style: styles[selectedStyleIndex])
        case .color:
            selectedColorIndex = min(max(selectedColorIndex + delta, 0), Self.colorPresets.count - 1)
            replaceSettings(color: .preset(Self.colorPresets[selectedColorIndex]))
        case .size:
            let direction = delta > 0 ? -1.0 : 1.0
            let value = min(
                max(selectedSettings.size + direction, LinkDestinationIndicatorSettings.sizeRange.lowerBound),
                LinkDestinationIndicatorSettings.sizeRange.upperBound
            )
            replaceSettings(size: value)
        case .duration:
            let direction = delta > 0 ? -100 : 100
            replaceSettings(durationMilliseconds: clampedDuration(selectedSettings.durationMilliseconds + direction))
        }
    }

    private func resetPressed() {
        selectedSettings = .standard
        selectedStyleIndex = LinkDestinationIndicatorStyle.allCases.firstIndex(of: .pulseRing) ?? 0
        selectedColorIndex = Self.colorPresets.firstIndex(of: .red) ?? 0
        emitPreview()
        updatePresentation()
    }

    private func replaceSettings(
        style: LinkDestinationIndicatorStyle? = nil,
        color: LinkDestinationIndicatorColor? = nil,
        size: Double? = nil,
        durationMilliseconds: Int? = nil
    ) {
        selectedSettings = LinkDestinationIndicatorSettings(
            style: style ?? selectedSettings.style,
            color: color ?? selectedSettings.color,
            size: size ?? selectedSettings.size,
            durationMilliseconds: durationMilliseconds ?? selectedSettings.durationMilliseconds
        )
        emitPreview()
        updatePresentation()
    }

    private func clampedDuration(_ value: Int) -> Int {
        min(
            max(value, LinkDestinationIndicatorSettings.durationMillisecondsRange.lowerBound),
            LinkDestinationIndicatorSettings.durationMillisecondsRange.upperBound
        )
    }

    private func emitPreview() {
        onPreview?(selectedSettings)
        renderStylePreview()
    }

    private func renderStylePreview() {
        guard !isHidden else { return }
        previewHost.layoutSubtreeIfNeeded()
        let previewSettings = LinkDestinationIndicatorSettings(
            style: selectedSettings.style,
            color: selectedSettings.color,
            size: 24,
            durationMilliseconds: 900
        )
        previewIndicator.configure(
            previewSettings,
            accentColor: theme[.accent],
            backgroundColor: theme.canvasBackground
        )
        previewIndicator.present(at: CGPoint(x: previewHost.bounds.midX, y: previewHost.bounds.midY))
    }
    private func updatePresentation() {
        guard columnViews.count == Column.allCases.count else { return }
        for (index, heading) in columnTitles.enumerated() {
            heading.textColor = index == selectedColumn.rawValue ? theme[.accent] : theme[.mutedText]
        }
        for (index, row) in styleRows.enumerated() {
            updateRow(row, selected: index == selectedStyleIndex, active: selectedColumn == .style, color: nil)
        }
        let fixedColors: [NSColor] = [.systemRed, .systemOrange, .systemCyan, .systemGreen, .systemPurple]
        for (index, row) in colorRows.enumerated() {
            updateRow(
                row,
                selected: index == selectedColorIndex,
                active: selectedColumn == .color,
                color: fixedColors[index]
            )
        }
        sizeBar.configure(
            value: selectedSettings.size,
            range: LinkDestinationIndicatorSettings.sizeRange,
            display: "\(Int(selectedSettings.size)) pt",
            active: selectedColumn == .size
        )
        durationBar.configure(
            value: Double(selectedSettings.durationMilliseconds),
            range: Double(LinkDestinationIndicatorSettings.durationMillisecondsRange.lowerBound)...Double(LinkDestinationIndicatorSettings.durationMillisecondsRange.upperBound),
            display: String(format: "%.1f s", Double(selectedSettings.durationMilliseconds) / 1_000),
            active: selectedColumn == .duration
        )
    }

    private func updateRow(
        _ row: NSTextField,
        selected: Bool,
        active: Bool,
        color: NSColor?
    ) {
        row.font = .monospacedSystemFont(ofSize: 10, weight: selected ? .semibold : .medium)
        row.textColor = color ?? (selected ? theme[.foreground] : theme[.mutedText])
        if selected {
            row.layer?.backgroundColor = (active ? theme[.accent] : theme[.foreground])
                .withAlphaComponent(active ? 0.20 : 0.10).cgColor
        } else {
            row.layer?.backgroundColor = theme[.background].withAlphaComponent(0.32).cgColor
        }
    }

    private func renderKeyHint() {
        let attributed = NSMutableAttributedString(
            string: Self.keyHintText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: theme[.mutedText],
            ]

        )
        let fullText = Self.keyHintText as NSString
        for shortcut in Self.shortcutLabels {
            attributed.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: theme[.accent],
            ], range: fullText.range(of: shortcut))
        }
        keyHintLabel.attributedStringValue = attributed
    }

    private func updateFocusAppearance() {
        layer?.borderColor = (showsFocusIndicator ? focusIndicatorColor : restingBorderColor).cgColor
        layer?.borderWidth = showsFocusIndicator ? WindowVisualMetrics.focusIndicatorWidth : 1
    }
}

@MainActor
private final class PickerOptionTextField: NSTextField {
    var onActivate: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: textColor ?? NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let measured = (stringValue as NSString).size(withAttributes: attributes)
        let textRect = NSRect(
            x: 2,
            y: floor((bounds.height - measured.height) / 2),
            width: bounds.width - 4,
            height: ceil(measured.height)
        )
        (stringValue as NSString).draw(in: textRect, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

@MainActor
private final class VerticalValueBarView: NSView {
    var onValueChanged: ((Double) -> Void)?
    private var value = 0.0
    private var range = 0.0...1.0
    private var display = ""
    private var active = false
    private var theme = AppKitTheme(themeID: .tokyoNight)

    var normalizedPosition: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    override var isOpaque: Bool { false }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        needsDisplay = true
    }

    func configure(value: Double, range: ClosedRange<Double>, display: String, active: Bool) {
        self.value = min(max(value, range.lowerBound), range.upperBound)
        self.range = range
        self.display = display
        self.active = active
        setAccessibilityValue(display)
        needsDisplay = true
    }

    func setNormalizedForTesting(_ normalized: Double) {
        let clamped = min(max(normalized, 0), 1)
        onValueChanged?(range.lowerBound + clamped * (range.upperBound - range.lowerBound))
    }

    override func mouseDown(with event: NSEvent) {
        updateValue(from: event)
    }

    override func mouseDragged(with event: NSEvent) {
        updateValue(from: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func updateValue(from event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let railMinY: CGFloat = 18
        let railMaxY = bounds.height - 32
        let position = min(max(point.y, railMinY), railMaxY)
        let normalized = Double((position - railMinY) / (railMaxY - railMinY))
        onValueChanged?(range.lowerBound + normalized * (range.upperBound - range.lowerBound))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let centerX = bounds.midX
        let railMinY: CGFloat = 18
        let railMaxY = bounds.height - 32
        let knobY = railMinY + CGFloat(normalizedPosition) * (railMaxY - railMinY)
        let railColor = theme.separator.withAlphaComponent(0.65)
        let accent = active ? theme[.accent] : theme[.foreground]

        let rail = NSBezierPath()
        rail.move(to: NSPoint(x: centerX, y: railMinY))
        rail.line(to: NSPoint(x: centerX, y: railMaxY))
        rail.lineWidth = 3
        rail.lineCapStyle = .round
        railColor.setStroke()
        rail.stroke()

        let filled = NSBezierPath()
        filled.move(to: NSPoint(x: centerX, y: railMinY))
        filled.line(to: NSPoint(x: centerX, y: knobY))
        filled.lineWidth = 4
        filled.lineCapStyle = .round
        accent.setStroke()
        filled.stroke()

        let knobRect = NSRect(x: centerX - 6, y: knobY - 6, width: 12, height: 12)
        accent.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
        theme[.activeTab].setFill()
        NSBezierPath(ovalIn: knobRect.insetBy(dx: 3, dy: 3)).fill()

        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: accent,
        ]
        let valueSize = (display as NSString).size(withAttributes: valueAttributes)
        (display as NSString).draw(
            at: NSPoint(x: centerX - valueSize.width / 2, y: bounds.height - 17),
            withAttributes: valueAttributes
        )

        let rangeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular),
            .foregroundColor: theme[.mutedText],
        ]
        let minimum = range.lowerBound >= 100 ? String(format: "%.1f", range.lowerBound / 1_000) : String(format: "%.0f", range.lowerBound)
        let maximum = range.upperBound >= 100 ? String(format: "%.1f", range.upperBound / 1_000) : String(format: "%.0f", range.upperBound)
        (minimum as NSString).draw(at: NSPoint(x: 4, y: 4), withAttributes: rangeAttributes)
        let maximumSize = (maximum as NSString).size(withAttributes: rangeAttributes)
        (maximum as NSString).draw(at: NSPoint(x: bounds.width - maximumSize.width - 4, y: 4), withAttributes: rangeAttributes)
    }
}
