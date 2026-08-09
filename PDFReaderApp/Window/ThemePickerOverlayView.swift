import AppKit
import PDFReaderCore

@MainActor
final class ThemePickerOverlayView: NSView {
    private enum Metrics {
        static let width: CGFloat = 300
    }

    private static let keyHintText = "j / k  Move selection    ↩  Apply    Esc  Close"
    private static let shortcutLabels = ["j / k", "↩", "Esc"]

    var onPreview: ((ThemeID) -> Void)?
    var onCommit: ((ThemeID) -> Void)?
    var onCancel: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Theme")
    private let separator = NSBox()
    private let keyHintLabel = NSTextField(labelWithString: ThemePickerOverlayView.keyHintText)
    private let rows = ThemeID.allCases.map { ThemePickerRowView(themeID: $0) }
    private var selectedIndex = 0
    private var restingBorderColor = NSColor.clear
    private var focusIndicatorColor = NSColor.clear
    private var showsFocusIndicator = false
    private var theme: AppKitTheme?

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
        setAccessibilityLabel("Theme picker")
        setAccessibilityIdentifier("themePickerOverlay")

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.setAccessibilityIdentifier("themePicker.title")

        separator.boxType = .separator
        separator.setAccessibilityIdentifier("themePicker.separator")

        keyHintLabel.font = .systemFont(ofSize: 11)
        keyHintLabel.maximumNumberOfLines = 1
        keyHintLabel.lineBreakMode = .byTruncatingTail
        keyHintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keyHintLabel.setAccessibilityIdentifier("themePicker.keyHint")

        for (index, row) in rows.enumerated() {
            row.onPointerEnter = { [weak self] in self?.selectTheme(at: index, commit: false) }
            row.onPointerActivate = { [weak self] in self?.selectTheme(at: index, commit: true) }
        }
        let rowStack = NSStackView(views: rows)
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 5
        rowStack.prepareForAutoLayout()

        let stack = NSStackView(views: [titleLabel, separator, rowStack, keyHintLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(10, after: titleLabel)
        stack.setCustomSpacing(10, after: separator)
        stack.setCustomSpacing(12, after: rowStack)
        stack.prepareForAutoLayout()
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            stack.widthAnchor.constraint(equalToConstant: Metrics.width),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rowStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            keyHintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        layer?.backgroundColor = theme[.activeTab].withAlphaComponent(0.9).cgColor
        restingBorderColor = theme.separator
        focusIndicatorColor = theme.focusRing
        shadow?.shadowColor = theme.overlayShadow
        titleLabel.textColor = theme[.accent]
        separator.borderColor = theme.separator
        renderKeyHint()
        for row in rows { row.apply(theme: theme) }
        updateFocusAppearance()
    }

    func present(selectedThemeID: ThemeID) {
        selectedIndex = ThemeID.allCases.firstIndex(of: selectedThemeID) ?? 0
        isHidden = false
        setFocusAppearance(true)
        // The presented selection is already the active theme, so render the
        // highlight without re-applying it; preview fires only on movement.
        updateSelection(preview: false)
    }

    func dismiss() {
        setFocusAppearance(false)
        isHidden = true
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 126:
            moveSelection(by: -1)
        case 125:
            moveSelection(by: 1)
        case 36, 76:
            onCommit?(selectedThemeID)
        case 53:
            onCancel?()
        default:
            guard let characters = event.charactersIgnoringModifiers?.lowercased() else { return false }
            switch characters {
            case "k": moveSelection(by: -1)
            case "j": moveSelection(by: 1)
            default: return false
            }
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !handleKeyDown(event) { super.keyDown(with: event) }
    }

    func setFocusAppearance(_ focused: Bool) {
        showsFocusIndicator = focused
        updateFocusAppearance()
    }

    var keyHintForTesting: String { keyHintLabel.stringValue }
    var keyHintIsWithinBoundsForTesting: Bool {
        layoutSubtreeIfNeeded()
        return bounds.contains(convert(keyHintLabel.bounds, from: keyHintLabel))
    }
    var titleIsSeparatedForTesting: Bool {
        layoutSubtreeIfNeeded()
        let titleFrame = convert(titleLabel.bounds, from: titleLabel)
        let separatorFrame = convert(separator.bounds, from: separator)
        let firstRowFrame = rows.first.map { convert($0.bounds, from: $0) }
        return separatorFrame.minY < titleFrame.minY
            && firstRowFrame.map { separatorFrame.maxY <= $0.minY || separatorFrame.minY >= $0.maxY } == true
    }

    func pointerEnterRowForTesting(at index: Int) { rows[index].pointerEnterForTesting() }
    func pointerActivateRowForTesting(at index: Int) { rows[index].pointerActivateForTesting() }
    private var selectedThemeID: ThemeID { ThemeID.allCases[selectedIndex] }

    private func moveSelection(by offset: Int) {
        let next = min(max(selectedIndex + offset, 0), ThemeID.allCases.count - 1)
        guard next != selectedIndex else { return }
        selectedIndex = next
        updateSelection(preview: true)
    }

    private func updateSelection(preview: Bool) {
        for (index, row) in rows.enumerated() { row.isSelected = index == selectedIndex }
        setAccessibilityValue(BuiltInThemes.theme(for: selectedThemeID).displayName)
        if preview { onPreview?(selectedThemeID) }
    }

    private func selectTheme(at index: Int, commit: Bool) {
        guard rows.indices.contains(index) else { return }
        let changed = selectedIndex != index
        selectedIndex = index
        updateSelection(preview: changed)
        if commit { onCommit?(selectedThemeID) }
    }

    private func updateFocusAppearance() {
        layer?.borderColor = (showsFocusIndicator ? focusIndicatorColor : restingBorderColor).cgColor
        layer?.borderWidth = showsFocusIndicator ? WindowVisualMetrics.focusIndicatorWidth : 1
    }

    private func renderKeyHint() {
        guard let theme else {
            keyHintLabel.stringValue = Self.keyHintText
            return
        }
        let attributed = NSMutableAttributedString(
            string: Self.keyHintText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: theme[.mutedText],
            ]
        )
        let fullText = Self.keyHintText as NSString
        for label in Self.shortcutLabels {
            attributed.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: theme[.accent],
            ], range: fullText.range(of: label))
        }
        keyHintLabel.attributedStringValue = attributed
    }
}

@MainActor
private final class ThemePickerRowView: PointerActionView {
    let themeID: ThemeID
    var isSelected = false { didSet { updateAppearance() } }
    private let label = NSTextField(labelWithString: "")
    private var theme: AppKitTheme?

    init(themeID: ThemeID) {
        self.themeID = themeID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        label.stringValue = BuiltInThemes.theme(for: themeID).displayName
        label.font = .systemFont(ofSize: 13)
        label.prepareForAutoLayout()
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        setContentHuggingPriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { nil }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        updateAppearance()
    }

    private func updateAppearance() {
        guard let theme else { return }
        label.textColor = isSelected ? theme[.accent] : theme[.foreground]
        label.font = .systemFont(ofSize: 13, weight: isSelected ? .semibold : .regular)
        layer?.backgroundColor = (isSelected ? theme.separator : NSColor.clear).cgColor
    }
}
