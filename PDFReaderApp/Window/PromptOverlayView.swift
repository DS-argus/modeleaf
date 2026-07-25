import AppKit

enum ReaderPromptKind: Equatable {
    case page
    case search
}

struct PromptPresentation: Equatable {
    let kind: ReaderPromptKind
    var text: String
    var validationMessage: String?
}

@MainActor
final class PromptOverlayView: NSView {
    private let prefixLabel = NSTextField(labelWithString: "/")
    let textField = NSTextField(string: "")
    let commitButton = ClosureButton(title: "Commit", target: nil, action: nil)
    let cancelButton = ClosureButton(title: "Cancel", target: nil, action: nil)
    private let validationLabel = NSTextField(labelWithString: "")
    private(set) var activeKind: ReaderPromptKind?
    private var restingBorderColor = NSColor.clear
    private var focusIndicatorColor = NSColor.clear
    private var showsFocusIndicator = false
    var activeText: String { textField.stringValue }

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
        setAccessibilityLabel("Reader prompt")
        setAccessibilityIdentifier("promptOverlay")

        prefixLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        prefixLabel.setContentHuggingPriority(.required, for: .horizontal)
        prefixLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 13)
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.setAccessibilityIdentifier("prompt.textField")

        validationLabel.font = .systemFont(ofSize: 10, weight: .medium)
        validationLabel.lineBreakMode = .byTruncatingTail
        validationLabel.maximumNumberOfLines = 1
        validationLabel.isHidden = true
        validationLabel.setAccessibilityIdentifier("prompt.validation")
        validationLabel.setAccessibilityLabel("Prompt validation")

        for button in [commitButton, cancelButton] {
            button.bezelStyle = .inline
            button.controlSize = .small
            button.font = .systemFont(ofSize: 10, weight: .medium)
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        commitButton.setAccessibilityIdentifier("prompt.commitButton")
        commitButton.setAccessibilityLabel("Commit prompt")
        cancelButton.setAccessibilityIdentifier("prompt.cancelButton")
        cancelButton.setAccessibilityLabel("Cancel prompt")

        let buttons = NSStackView(views: [commitButton, cancelButton])
        buttons.orientation = .horizontal
        buttons.spacing = 4

        let inputRow = NSStackView(views: [prefixLabel, textField, buttons])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 10

        let stack = NSStackView(views: [inputRow, validationLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.prepareForAutoLayout()
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            inputRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            validationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            textField.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])

        isHidden = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    func apply(theme: AppKitTheme) {
        layer?.backgroundColor = theme[.activeTab].cgColor
        restingBorderColor = theme.separator
        focusIndicatorColor = theme.focusRing
        updateFocusAppearance()
        shadow?.shadowColor = theme.overlayShadow
        prefixLabel.textColor = theme[.accent]
        textField.textColor = theme[.foreground]
        validationLabel.textColor = theme[.error]
        commitButton.contentTintColor = theme[.foreground]
        cancelButton.contentTintColor = theme[.mutedText]
    }

    func present(_ presentation: PromptPresentation) {
        activeKind = presentation.kind
        prefixLabel.stringValue = presentation.kind == .search ? "/" : "go to page"
        textField.stringValue = presentation.text
        textField.placeholderString = presentation.kind == .search ? "Search embedded text" : "Page number"
        validationLabel.stringValue = presentation.validationMessage ?? ""
        validationLabel.isHidden = presentation.validationMessage == nil
        textField.setAccessibilityLabel(presentation.kind == .search ? "Search query" : "Page number")
        setAccessibilityValue(presentation.kind == .search ? "Search prompt" : "Page prompt")
        isHidden = false
        setFocusAppearance(true)
    }

    func showValidation(_ message: String) {
        validationLabel.stringValue = message
        validationLabel.isHidden = false
        validationLabel.setAccessibilityValue(message)
        textField.setAccessibilityHelp(message)
    }

    @discardableResult
    func discardMarkedComposition() -> Bool {
        guard let editor = textField.currentEditor() as? NSTextView,
              editor.hasMarkedText()
        else {
            return false
        }
        editor.unmarkText()
        return true
    }

    func dismiss() {
        setFocusAppearance(false)
        activeKind = nil
        isHidden = true
        textField.stringValue = ""
        validationLabel.stringValue = ""
        validationLabel.isHidden = true
        validationLabel.setAccessibilityValue(nil)
        textField.setAccessibilityHelp(nil)
        setAccessibilityValue(nil)
    }

    func setFocusAppearance(_ focused: Bool) {
        showsFocusIndicator = focused
        updateFocusAppearance()
    }

    private func updateFocusAppearance() {
        layer?.borderColor = (showsFocusIndicator ? focusIndicatorColor : restingBorderColor).cgColor
        layer?.borderWidth = showsFocusIndicator ? WindowVisualMetrics.focusIndicatorWidth : 1
    }
}
