import AppKit
import PDFReaderCore

@MainActor
final class UpdateInstructionsOverlayView: NSView {
    private enum Metrics {
        static let outerWidth: CGFloat = 410
        static let horizontalInset: CGFloat = 20
        static let contentWidth: CGFloat = outerWidth - (horizontalInset * 2)
        static let topInset: CGFloat = 20
        static let bottomInset: CGFloat = 16
        static let maximumSummaryHeight: CGFloat = 132
        static let minimumSummaryHeight: CGFloat = 18
        static let summarySpacing: CGFloat = 12
        static let footerSpacing: CGFloat = 10
        static let actionSpacing: CGFloat = 4
        static let footerActionSpacing: CGFloat = 8
    }

    private static let updateCommand = "modeleaf update"
    private static let copyTitle = "Copy update command"
    private static let copiedTitle = "Copied · Paste in Terminal"
    private static let releaseNotesTitle = "Release notes"
    private static let closeTitle = "Close"

    var onCancel: (() -> Void)?
    var copyHandler: (String) -> Void = { value in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
    var openHandler: (URL) -> Void = { url in
        _ = NSWorkspace.shared.open(url)
    }

    private let titleLabel = NSTextField(labelWithString: "Update available")
    private let versionLabel = NSTextField(labelWithString: "")
    private let headerRow = NSStackView()
    private let summaryScrollView = NSScrollView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let footerSeparator = NSBox()
    private let footerRow = NSStackView()
    private let copyKeyLabel = NSTextField(labelWithString: "↵")
    private let footerSpacer = NSView()
    private let copyButton = NSButton(title: UpdateInstructionsOverlayView.copyTitle, target: nil, action: nil)
    private let releaseNotesKeyLabel = NSTextField(labelWithString: "⇧↵")
    private let releaseNotesButton = NSButton(title: UpdateInstructionsOverlayView.releaseNotesTitle, target: nil, action: nil)
    private let closeKeyLabel = NSTextField(labelWithString: "Esc")
    private let closeButton = NSButton(title: UpdateInstructionsOverlayView.closeTitle, target: nil, action: nil)
    private let contentStack = NSStackView()
    private var summaryHeightConstraint: NSLayoutConstraint!
    private var summaryDocumentHeightConstraint: NSLayoutConstraint!
    private var copyButtonWidthConstraint: NSLayoutConstraint!
    private var theme: AppKitTheme?
    private var restingBorderColor = NSColor.clear
    private var focusIndicatorColor = NSColor.clear
    private var showsFocusIndicator = false
    private var highlightsText: String?
    private var releaseURL: URL?

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
        setAccessibilityLabel("Modeleaf update release details")
        setAccessibilityIdentifier("updateInstructionsOverlay")

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setAccessibilityIdentifier("updateInstructions.title")

        versionLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        versionLabel.alignment = .right
        versionLabel.setContentHuggingPriority(.required, for: .horizontal)
        versionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        versionLabel.setAccessibilityIdentifier("updateInstructions.version")

        headerRow.orientation = .horizontal
        headerRow.alignment = .firstBaseline
        headerRow.distribution = .fill
        headerRow.spacing = 8
        headerRow.addArrangedSubview(titleLabel)
        headerRow.addArrangedSubview(versionLabel)
        headerRow.prepareForAutoLayout()

        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.alignment = .left
        summaryLabel.setAccessibilityIdentifier("updateInstructions.highlights")
        summaryLabel.setAccessibilityLabel("Release summary")
        summaryLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        summaryLabel.setContentHuggingPriority(.required, for: .vertical)
        summaryLabel.prepareForAutoLayout()

        summaryScrollView.borderType = .noBorder
        summaryScrollView.drawsBackground = false
        summaryScrollView.hasVerticalScroller = true
        summaryScrollView.autohidesScrollers = true
        summaryScrollView.hasHorizontalScroller = false
        summaryScrollView.documentView = summaryLabel
        summaryScrollView.setAccessibilityIdentifier("updateInstructions.highlightsScroll")
        summaryScrollView.prepareForAutoLayout()
        summaryHeightConstraint = summaryScrollView.heightAnchor.constraint(equalToConstant: Metrics.minimumSummaryHeight)
        summaryHeightConstraint.isActive = true
        summaryDocumentHeightConstraint = summaryLabel.heightAnchor.constraint(equalToConstant: Metrics.minimumSummaryHeight)
        summaryDocumentHeightConstraint.isActive = true
        summaryLabel.widthAnchor.constraint(equalTo: summaryScrollView.contentView.widthAnchor).isActive = true

        footerSeparator.boxType = .separator
        footerSeparator.setAccessibilityIdentifier("updateInstructions.footerSeparator")
        footerSeparator.prepareForAutoLayout()

        configureActionKeyLabel(copyKeyLabel, identifier: "updateInstructions.copyShortcut")
        configureActionKeyLabel(releaseNotesKeyLabel, identifier: "updateInstructions.releaseNotesShortcut")
        configureActionKeyLabel(closeKeyLabel, identifier: "updateInstructions.closeShortcut")

        configureActionButton(
            copyButton,
            identifier: "updateInstructions.copy",
            accessibilityLabel: "Copy modeleaf update command",
            action: #selector(copyCommand)
        )
        configureActionButton(
            releaseNotesButton,
            identifier: "updateInstructions.releaseNotes",
            accessibilityLabel: "Open release notes",
            action: #selector(openReleaseNotes)
        )
        configureActionButton(
            closeButton,
            identifier: "updateInstructions.close",
            accessibilityLabel: "Close update details",
            action: #selector(cancelUpdate)
        )
        releaseNotesButton.isEnabled = false
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerSpacer.setContentHuggingPriority(.required, for: .vertical)
        footerSpacer.setContentCompressionResistancePriority(.required, for: .vertical)
        footerSpacer.heightAnchor.constraint(equalToConstant: 1).isActive = true
        footerSpacer.prepareForAutoLayout()

        copyButtonWidthConstraint = copyButton.widthAnchor.constraint(equalToConstant: copyButtonWidth())
        copyButtonWidthConstraint.isActive = true

        let copyAction = actionStack(key: copyKeyLabel, button: copyButton)
        let releaseNotesAction = actionStack(key: releaseNotesKeyLabel, button: releaseNotesButton)
        let closeAction = actionStack(key: closeKeyLabel, button: closeButton)
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.distribution = .fill
        footerRow.spacing = Metrics.footerActionSpacing
        footerRow.addArrangedSubview(copyAction)
        footerRow.addArrangedSubview(releaseNotesAction)
        footerRow.addArrangedSubview(closeAction)
        footerRow.addArrangedSubview(footerSpacer)
        footerRow.setAccessibilityIdentifier("updateInstructions.footer")
        footerRow.prepareForAutoLayout()

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
        contentStack.addArrangedSubview(headerRow)
        contentStack.addArrangedSubview(summaryScrollView)
        contentStack.addArrangedSubview(footerSeparator)
        contentStack.addArrangedSubview(footerRow)
        contentStack.setCustomSpacing(Metrics.summarySpacing, after: headerRow)
        contentStack.setCustomSpacing(Metrics.footerSpacing, after: summaryScrollView)
        contentStack.setCustomSpacing(Metrics.footerSpacing, after: footerSeparator)
        contentStack.prepareForAutoLayout()
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.topInset),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalInset),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalInset),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.bottomInset),
            contentStack.widthAnchor.constraint(equalToConstant: Metrics.contentWidth),
            headerRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            summaryScrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            footerSeparator.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            footerRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let fittedHeight = contentStack.fittingSize.height + Metrics.topInset + Metrics.bottomInset
        return NSSize(width: Metrics.outerWidth, height: max(1, ceil(fittedHeight)))
    }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        layer?.backgroundColor = theme[.activeTab].withAlphaComponent(0.95).cgColor
        restingBorderColor = theme.separator
        focusIndicatorColor = theme.focusRing
        shadow?.shadowColor = theme.overlayShadow
        titleLabel.textColor = theme[.foreground]
        versionLabel.textColor = theme[.accent]
        footerSeparator.borderColor = theme.separator
        summaryLabel.textColor = theme[.foreground]
        copyButton.contentTintColor = theme[.mutedText]
        releaseNotesButton.contentTintColor = theme[.mutedText]
        closeButton.contentTintColor = theme[.mutedText]
        for keyLabel in [copyKeyLabel, releaseNotesKeyLabel, closeKeyLabel] {
            keyLabel.textColor = theme[.accent]
        }
        renderSummary()
        updateFocusAppearance()
    }

    func present(update: AvailableUpdate) {
        highlightsText = update.highlights
        releaseURL = update.releaseURL
        versionLabel.stringValue = update.version.description
        versionLabel.setAccessibilityValue(update.version.description)
        copyButton.title = Self.copyTitle
        copyButton.setAccessibilityValue(nil)
        releaseNotesButton.isEnabled = releaseURL != nil
        renderSummary()
        summaryScrollView.contentView.scroll(to: .zero)
        summaryScrollView.reflectScrolledClipView(summaryScrollView.contentView)
        setAccessibilityValue(accessibilitySummary(for: update))
        isHidden = false
        invalidateIntrinsicContentSize()
        setFocusAppearance(true)
    }

    func dismiss() {
        setFocusAppearance(false)
        isHidden = true
        copyButton.title = Self.copyTitle
        copyButton.setAccessibilityValue(nil)
        highlightsText = nil
        releaseURL = nil
        versionLabel.stringValue = ""
        versionLabel.setAccessibilityValue(nil)
        renderSummary()
        releaseNotesButton.isEnabled = false
        setAccessibilityValue(nil)
        invalidateIntrinsicContentSize()
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            onCancel?()
            return true
        case 36, 76:
            let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
            guard event.modifierFlags.intersection(blockedModifiers).isEmpty else { return true }
            if event.modifierFlags.contains(.shift) {
                openReleaseNotes()
            } else {
                copyCommand()
            }
            return true
        default:
            return false
        }
    }

    override func keyDown(with event: NSEvent) {
        if !handleKeyDown(event) { super.keyDown(with: event) }
    }

    func setFocusAppearance(_ focused: Bool) {
        showsFocusIndicator = focused
        updateFocusAppearance()
    }

    var titleForTesting: String { titleLabel.stringValue }
    var versionForTesting: String { versionLabel.stringValue }
    var summaryForTesting: String? { highlightsText }
    var summaryRenderedTextForTesting: String { summaryLabel.stringValue }
    var summaryAttributedStringForTesting: NSAttributedString { summaryLabel.attributedStringValue }
    var summaryIsHiddenForTesting: Bool { summaryScrollView.isHidden }
    var releaseNotesEnabledForTesting: Bool { releaseNotesButton.isEnabled }
    var copyButtonForTesting: NSButton { copyButton }
    var releaseNotesButtonForTesting: NSButton { releaseNotesButton }
    var closeButtonForTesting: NSButton { closeButton }
    var summaryScrollViewForTesting: NSScrollView { summaryScrollView }
    var footerActionTitlesForTesting: [String] {
        [
            "\(copyKeyLabel.stringValue) \(copyButton.title)",
            "\(releaseNotesKeyLabel.stringValue) \(releaseNotesButton.title)",
            "\(closeKeyLabel.stringValue) \(closeButton.title)",
        ]
    }
    var copiedMessageForTesting: String {
        copyButton.title == Self.copiedTitle ? Self.copiedTitle : ""
    }
    var listRequiresScrollingForTesting: Bool {
        layoutSubtreeIfNeeded()
        return summaryDocumentHeightConstraint.constant > summaryHeightConstraint.constant + 0.5
    }
    var footerIsWithinBoundsForTesting: Bool {
        layoutSubtreeIfNeeded()
        return bounds.contains(convert(footerRow.bounds, from: footerRow))
    }
    func copyForTesting() { copyCommand() }
    func openReleaseNotesForTesting() { openReleaseNotes() }

    @objc private func copyCommand() {
        copyHandler(Self.updateCommand)
        copyButton.title = Self.copiedTitle
        copyButton.setAccessibilityValue(Self.copiedTitle)
    }

    @objc private func openReleaseNotes() {
        guard let releaseURL else { return }
        openHandler(releaseURL)
    }

    @objc private func cancelUpdate() {
        onCancel?()
    }

    private func configureActionKeyLabel(_ label: NSTextField, identifier: String) {
        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.alignment = .center
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setAccessibilityIdentifier(identifier)
        label.setAccessibilityLabel("Keyboard shortcut")
        label.prepareForAutoLayout()
    }

    private func configureActionButton(
        _ button: NSButton,
        identifier: String,
        accessibilityLabel: String,
        action: Selector
    ) {
        button.isBordered = false
        button.bezelStyle = .inline
        button.controlSize = .small
        button.focusRingType = .none
        button.font = .systemFont(ofSize: 10, weight: .regular)
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.setButtonType(.momentaryChange)
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = accessibilityLabel
        button.prepareForAutoLayout()
    }

    private func actionStack(key: NSTextField, button: NSButton) -> NSStackView {
        let stack = NSStackView(views: [key, button])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Metrics.actionSpacing
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.prepareForAutoLayout()
        return stack
    }
    private func copyButtonWidth() -> CGFloat {
        let initialWidth = copyButton.intrinsicContentSize.width
        copyButton.title = Self.copiedTitle
        let copiedWidth = copyButton.intrinsicContentSize.width
        copyButton.title = Self.copyTitle
        return max(1, max(initialWidth, copiedWidth) + 2)
    }

    private func renderSummary() {
        guard let highlightsText,
              !highlightsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            summaryScrollView.isHidden = true
            summaryLabel.isHidden = true
            summaryLabel.attributedStringValue = NSAttributedString(string: "")
            summaryLabel.setAccessibilityValue(nil)
            summaryHeightConstraint.constant = Metrics.minimumSummaryHeight
            summaryDocumentHeightConstraint.constant = Metrics.minimumSummaryHeight
            invalidateIntrinsicContentSize()
            return
        }

        summaryScrollView.isHidden = false
        summaryLabel.isHidden = false
        let attributed = Self.attributedSummary(
            highlightsText,
            color: theme?[.foreground] ?? .labelColor,
            bulletColor: theme?[.mutedText] ?? .secondaryLabelColor
        )
        summaryLabel.attributedStringValue = attributed
        summaryLabel.setAccessibilityValue(highlightsText)
        updateSummaryMetrics(for: attributed)
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        guard !isHidden, !summaryScrollView.isHidden else { return }
        updateSummaryMetrics(for: summaryLabel.attributedStringValue)
    }

    private func updateSummaryMetrics(for attributed: NSAttributedString) {
        let contentWidth = summaryScrollView.contentView.bounds.width
        let width = max(1, contentWidth > 1 ? contentWidth : Metrics.contentWidth)
        let measured = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let documentHeight = max(Metrics.minimumSummaryHeight, ceil(measured.height) + 1)
        summaryDocumentHeightConstraint.constant = documentHeight
        summaryHeightConstraint.constant = min(Metrics.maximumSummaryHeight, documentHeight)
        summaryLabel.preferredMaxLayoutWidth = width
    }

    private func updateFocusAppearance() {
        let borderColor = showsFocusIndicator
            ? focusIndicatorColor.withAlphaComponent(0.72)
            : restingBorderColor
        layer?.borderColor = borderColor.cgColor
        layer?.borderWidth = WindowVisualMetrics.canvasFocusRingWidth
    }

    private func accessibilitySummary(for update: AvailableUpdate) -> String {
        var summary = "Update available: Modeleaf \(update.version). Press Return to copy \(Self.updateCommand)."
        if let highlights = update.highlights,
           !highlights.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            summary += " Release summary: \(highlights)"
        }
        if update.releaseURL != nil {
            summary += " Press Shift+Return for release notes."
        }
        return summary
    }

    private static func attributedSummary(
        _ text: String,
        color: NSColor,
        bulletColor: NSColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let lines = text.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let (content, isBullet) = normalizedBulletLine(line)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 1
            paragraphStyle.paragraphSpacing = 2
            if isBullet {
                paragraphStyle.headIndent = 13
                paragraphStyle.firstLineHeadIndent = 0
            }
            let regularAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle,
            ]
            let codeAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle,
            ]
            if isBullet {
                result.append(NSAttributedString(
                    string: "• ",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12),
                        .foregroundColor: bulletColor,
                        .paragraphStyle: paragraphStyle,
                    ]
                ))
            }
            appendInlineCode(
                content,
                to: result,
                regularAttributes: regularAttributes,
                codeAttributes: codeAttributes
            )
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: regularAttributes))
            }
        }
        return result
    }

    private static func normalizedBulletLine(_ line: String) -> (String, Bool) {
        var marker = line.startIndex
        while marker < line.endIndex,
              line[marker] == " " || line[marker] == "\t" {
            marker = line.index(after: marker)
        }
        guard marker < line.endIndex,
              line[marker] == "-" || line[marker] == "*" || line[marker] == "+"
        else { return (line, false) }

        let afterMarker = line.index(after: marker)
        guard afterMarker < line.endIndex,
              line[afterMarker].isWhitespace
        else { return (line, false) }

        var contentStart = afterMarker
        while contentStart < line.endIndex, line[contentStart].isWhitespace {
            contentStart = line.index(after: contentStart)
        }
        return (contentStart == line.endIndex ? "" : String(line[contentStart...]), true)
    }

    private static func appendInlineCode(
        _ text: String,
        to result: NSMutableAttributedString,
        regularAttributes: [NSAttributedString.Key: Any],
        codeAttributes: [NSAttributedString.Key: Any]
    ) {
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard let opening = text[cursor...].firstIndex(of: "`") else {
                result.append(NSAttributedString(string: String(text[cursor...]), attributes: regularAttributes))
                return
            }
            if opening > cursor {
                result.append(NSAttributedString(string: String(text[cursor..<opening]), attributes: regularAttributes))
            }
            let contentStart = text.index(after: opening)
            guard contentStart <= text.endIndex,
                  let closing = text[contentStart...].firstIndex(of: "`")
            else {
                result.append(NSAttributedString(string: String(text[opening...]), attributes: regularAttributes))
                return
            }
            if closing > contentStart {
                result.append(NSAttributedString(string: String(text[contentStart..<closing]), attributes: codeAttributes))
            }
            cursor = text.index(after: closing)
        }
    }
}
