import AppKit
import PDFReaderCore

@MainActor
final class UpdateInstructionsOverlayView: NSView {
    private enum Metrics { static let width: CGFloat = 388 }
    private static let homebrewCommand = "brew upgrade --cask modeleaf"
    private static let reliableHomebrewCommand = "brew update --force && brew upgrade --cask modeleaf"
    private static let homebrewKeyHintText = "↩  Copy commands    o  Open Releases    Esc  Close"
    private static let manualKeyHintText = "↩  Copy Releases URL    o  Open Releases    Esc  Close"
    private static let shortcutLabels = ["↩", "o", "Esc"]

    var onOpenReleases: (() -> Void)?
    var onCancel: (() -> Void)?
    var copyHandler: (String) -> Void = { value in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private let titleLabel = NSTextField(labelWithString: "Update Modeleaf")
    private let versionLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()
    private let primaryCaption = NSTextField(labelWithString: "")
    private let primaryCommand = UpdateCommandBlockView()
    private let fallbackCaption = NSTextField(labelWithString: "")
    private let fallbackCommand = UpdateCommandBlockView()
    private let copiedLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy Commands", target: nil, action: nil)
    private let releasesButton = NSButton(title: "Open Releases", target: nil, action: nil)
    private let keyHintLabel = NSTextField(labelWithString: UpdateInstructionsOverlayView.homebrewKeyHintText)
    private var source = InstallSource.homebrew
    private var theme: AppKitTheme?
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
        setAccessibilityLabel("Modeleaf update instructions")
        setAccessibilityIdentifier("updateInstructionsOverlay")

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        versionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        separator.boxType = .separator
        for caption in [primaryCaption, fallbackCaption] {
            caption.font = .systemFont(ofSize: 11, weight: .medium)
        }
        copiedLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        copiedLabel.alignment = .right

        copyButton.target = self
        copyButton.action = #selector(copyCommands)
        releasesButton.target = self
        releasesButton.action = #selector(openReleases)
        for button in [copyButton, releasesButton] {
            button.bezelStyle = .rounded
            button.setButtonType(.momentaryPushIn)
        }

        keyHintLabel.maximumNumberOfLines = 1
        keyHintLabel.lineBreakMode = .byTruncatingTail
        keyHintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keyHintLabel.setAccessibilityIdentifier("updateInstructions.keyHint")

        let actions = NSStackView(views: [copyButton, releasesButton, copiedLabel])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        let stack = NSStackView(views: [
            titleLabel, separator, versionLabel,
            primaryCaption, primaryCommand,
            fallbackCaption, fallbackCommand,
            actions, keyHintLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.setCustomSpacing(10, after: titleLabel)
        stack.setCustomSpacing(10, after: separator)
        stack.setCustomSpacing(12, after: fallbackCommand)
        stack.setCustomSpacing(10, after: actions)
        stack.prepareForAutoLayout()
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            stack.widthAnchor.constraint(equalToConstant: Metrics.width),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            versionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            primaryCommand.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fallbackCommand.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            keyHintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        layer?.backgroundColor = theme[.activeTab].withAlphaComponent(0.95).cgColor
        restingBorderColor = theme.separator
        focusIndicatorColor = theme.focusRing
        shadow?.shadowColor = theme.overlayShadow
        titleLabel.textColor = theme[.accent]
        versionLabel.textColor = theme[.foreground]
        separator.borderColor = theme.separator
        primaryCaption.textColor = theme[.mutedText]
        fallbackCaption.textColor = theme[.mutedText]
        copiedLabel.textColor = theme[.accent]
        primaryCommand.apply(theme: theme)
        fallbackCommand.apply(theme: theme)
        copyButton.contentTintColor = theme[.accent]
        releasesButton.contentTintColor = theme[.accent]
        renderKeyHint()
        updateFocusAppearance()
    }

    func present(update: AvailableUpdate) {
        source = update.source
        versionLabel.stringValue = "Modeleaf \(update.version) is available"
        copiedLabel.stringValue = ""
        switch update.source {
        case .homebrew:
            primaryCaption.stringValue = "Normal update"
            primaryCommand.render(Self.homebrewCommand)
            fallbackCaption.stringValue = "If Homebrew says it is already current"
            fallbackCommand.render(Self.reliableHomebrewCommand)
            fallbackCaption.isHidden = false
            fallbackCommand.isHidden = false
            copyButton.title = "Copy Commands"
        case .manual:
            primaryCaption.stringValue = "Download the latest build from GitHub Releases"
            primaryCommand.render("github.com/DS-argus/modeleaf/releases/latest")
            fallbackCaption.isHidden = true
            fallbackCommand.isHidden = true
            copyButton.title = "Copy Releases URL"
        }
        renderKeyHint()
        isHidden = false
        setFocusAppearance(true)
    }

    func dismiss() {
        setFocusAppearance(false)
        isHidden = true
        copiedLabel.stringValue = ""
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 76: copyCommands(); return true
        case 53: onCancel?(); return true
        default:
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  event.charactersIgnoringModifiers?.lowercased() == "o"
            else { return false }
            openReleases()
            return true
        }
    }

    override func keyDown(with event: NSEvent) {
        if !handleKeyDown(event) { super.keyDown(with: event) }
    }

    func setFocusAppearance(_ focused: Bool) {
        showsFocusIndicator = focused
        updateFocusAppearance()
    }

    var copiedMessageForTesting: String { copiedLabel.stringValue }
    var keyHintForTesting: NSAttributedString { keyHintLabel.attributedStringValue }
    var displayedCommandsForTesting: [String] {
        fallbackCommand.isHidden ? [primaryCommand.value] : [primaryCommand.value, fallbackCommand.value]
    }
    func copyForTesting() { copyCommands() }
    func openReleasesForTesting() { openReleases() }

    @objc private func copyCommands() {
        let value = source == .homebrew
            ? Self.reliableHomebrewCommand
            : UpdateChecker.releasesPage.absoluteString
        copyHandler(value)
        copiedLabel.stringValue = "Copied"
    }

    private var keyHintText: String {
        source == .homebrew ? Self.homebrewKeyHintText : Self.manualKeyHintText
    }
    @objc private func openReleases() { onOpenReleases?() }

    private func renderKeyHint() {
        let mutedText = theme?[.mutedText] ?? .secondaryLabelColor
        let accent = theme?[.accent] ?? .controlAccentColor
        let attributed = NSMutableAttributedString(
            string: keyHintText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: mutedText,
            ]
        )
        let fullText = keyHintText as NSString
        for shortcut in Self.shortcutLabels {
            attributed.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: accent,
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
private final class UpdateCommandBlockView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var theme: AppKitTheme?
    var value: String { label.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.prepareForAutoLayout()
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.canvasBackground.withAlphaComponent(0.75).cgColor
        layer?.borderColor = theme.separator.cgColor
        layer?.borderWidth = 1
        label.textColor = theme[.foreground]
    }

    func render(_ value: String) {
        label.stringValue = value
        label.setAccessibilityValue(value)
        toolTip = value
    }
}
