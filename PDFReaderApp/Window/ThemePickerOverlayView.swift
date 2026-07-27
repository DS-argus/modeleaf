import AppKit
import PDFReaderCore

@MainActor
final class ThemePickerOverlayView: NSView {
    var onPreview: ((ThemeID) -> Void)?
    var onCommit: ((ThemeID) -> Void)?
    var onCancel: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Theme")
    private let rows = ThemeID.allCases.map { ThemePickerRowView(themeID: $0) }
    private var selectedIndex = 0
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
        setAccessibilityLabel("Theme picker")
        setAccessibilityIdentifier("themePickerOverlay")

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let stack = NSStackView(views: [titleLabel] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.prepareForAutoLayout()
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            stack.widthAnchor.constraint(equalToConstant: 240),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func apply(theme: AppKitTheme) {
        layer?.backgroundColor = theme[.activeTab].withAlphaComponent(0.8).cgColor
        restingBorderColor = theme.separator
        focusIndicatorColor = theme.focusRing
        shadow?.shadowColor = theme.overlayShadow
        titleLabel.textColor = theme[.foreground]
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

    private func updateFocusAppearance() {
        layer?.borderColor = (showsFocusIndicator ? focusIndicatorColor : restingBorderColor).cgColor
        layer?.borderWidth = showsFocusIndicator ? WindowVisualMetrics.focusIndicatorWidth : 1
    }
}
@MainActor
private final class ThemePickerRowView: NSTextField {
    let themeID: ThemeID
    var isSelected = false { didSet { updateAppearance() } }
    private var theme: AppKitTheme?

    init(themeID: ThemeID) {
        self.themeID = themeID
        super.init(frame: .zero)
        stringValue = BuiltInThemes.theme(for: themeID).displayName
        isBezeled = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        font = .systemFont(ofSize: 13)
        setContentHuggingPriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { nil }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        updateAppearance()
    }

    private func updateAppearance() {
        guard let theme else { return }
        textColor = isSelected ? theme[.accent] : theme[.foreground]
        font = .systemFont(ofSize: 13, weight: isSelected ? .semibold : .regular)
    }
}

