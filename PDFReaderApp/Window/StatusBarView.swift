import AppKit

enum StatusTone: Equatable {
    case normal
    case error
}

struct StatusBarPresentation: Equatable {
    var page: String
    var zoom: String
    var pendingPrefix: String
    var detail: String
    var expandedDetail: String?
    var tone: StatusTone

    static let empty = StatusBarPresentation(
        page: ReaderStatusSnapshot.empty.page,
        zoom: ReaderStatusSnapshot.empty.zoom,
        pendingPrefix: "",
        detail: ReaderStatusSnapshot.empty.detail,
        expandedDetail: nil,
        tone: .normal
    )
}

@MainActor
final class StatusBarView: NSView {
    private let helpButton = NSButton(title: "? help", target: nil, action: nil)
    private let pageLabel = StatusBarView.makeLabel(identifier: "status.page", monospaced: true)
    private let zoomLabel = StatusBarView.makeLabel(identifier: "status.zoom", monospaced: true)
    private let prefixLabel = StatusBarView.makeLabel(identifier: "status.prefix", monospaced: true)
    private let detailLabel = StatusBarView.makeLabel(identifier: "status.diagnostic", monospaced: false)
    private let updateButton = NSButton(title: "", target: nil, action: nil)
    private let separator = NSBox()
    private var theme: AppKitTheme?
    private(set) var presentation = StatusBarPresentation.empty

    /// Invoked when the user clicks the keyboard help hint.
    var onHelpTap: (() -> Void)?
    /// Non-nil while an update banner is shown (the plain, unstyled text).
    private(set) var updateText: String?
    /// Invoked when the user clicks the update banner.
    var onUpdateClicked: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Reader status and keyboard help")
        setAccessibilityIdentifier("statusBar")

        separator.boxType = .separator
        separator.prepareForAutoLayout()
        addSubview(separator)

        helpButton.isBordered = false
        helpButton.bezelStyle = .inline
        helpButton.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        helpButton.target = self
        helpButton.action = #selector(helpTapped)
        helpButton.setButtonType(.momentaryChange)
        helpButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        helpButton.setContentHuggingPriority(.required, for: .horizontal)
        helpButton.setAccessibilityIdentifier("status.help")
        helpButton.setAccessibilityLabel("Keyboard help")
        helpButton.setAccessibilityValue("? help")

        let leading = NSStackView(views: [helpButton, pageLabel, zoomLabel, prefixLabel])
        leading.orientation = .horizontal
        leading.alignment = .centerY
        leading.spacing = 16
        leading.prepareForAutoLayout()
        addSubview(leading)

        updateButton.isBordered = false
        updateButton.bezelStyle = .inline
        updateButton.font = .systemFont(ofSize: 11, weight: .semibold)
        updateButton.target = self
        updateButton.action = #selector(updateClicked)
        updateButton.isHidden = true
        updateButton.setButtonType(.momentaryChange)
        updateButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        updateButton.setContentHuggingPriority(.required, for: .horizontal)
        updateButton.setAccessibilityIdentifier("status.update")
        updateButton.prepareForAutoLayout()
        addSubview(updateButton)

        detailLabel.alignment = .right
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.prepareForAutoLayout()
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            updateButton.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: 16),
            updateButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: updateButton.trailingAnchor, constant: 16),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        render(.empty)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        layer?.backgroundColor = theme[.statusline].cgColor
        separator.borderColor = theme.separator
        helpButton.contentTintColor = theme[.accent]
        pageLabel.textColor = theme[.mutedText]
        zoomLabel.textColor = theme[.mutedText]
        prefixLabel.textColor = theme[.accent]
        detailLabel.textColor = presentation.tone == .error ? theme[.error] : theme[.mutedText]
        restyleUpdateButton()
    }

    /// Shows the update banner (accent, clickable) or clears it when `text` is nil.
    func presentUpdate(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        updateText = (trimmed?.isEmpty == false) ? trimmed : nil
        updateButton.isHidden = updateText == nil
        updateButton.toolTip = updateText
        restyleUpdateButton()
    }

    private func restyleUpdateButton() {
        guard let updateText else {
            updateButton.attributedTitle = NSAttributedString(string: "")
            return
        }
        let accent = theme?[.accent] ?? .controlAccentColor
        updateButton.attributedTitle = NSAttributedString(
            string: updateText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: accent,
            ]
        )
        updateButton.setAccessibilityValue(updateText)
    }

    @objc private func helpTapped() {
        onHelpTap?()
    }

    @objc private func updateClicked() {
        onUpdateClicked?()
    }

    func performHelpTapForTesting() { helpButton.performClick(nil) }
    func performUpdateClickForTesting() { updateButton.performClick(nil) }

    func render(_ presentation: StatusBarPresentation) {
        self.presentation = presentation
        pageLabel.stringValue = presentation.page
        zoomLabel.stringValue = presentation.zoom
        prefixLabel.stringValue = presentation.pendingPrefix.isEmpty ? "" : "prefix  \(presentation.pendingPrefix)"
        detailLabel.stringValue = presentation.detail
        detailLabel.setAccessibilityValue(presentation.detail)
        detailLabel.setAccessibilityHelp(presentation.expandedDetail)
        detailLabel.toolTip = presentation.expandedDetail
        setAccessibilityValue(
            [
                "Keyboard help available. Page \(presentation.page), zoom \(presentation.zoom), \(presentation.detail)",
                presentation.expandedDetail,
            ].compactMap { $0 }.joined(separator: ". ")
        )
        if let theme {
            detailLabel.textColor = presentation.tone == .error ? theme[.error] : theme[.mutedText]
        }
    }

    private static func makeLabel(identifier: String, monospaced: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = monospaced
            ? .monospacedSystemFont(ofSize: 11, weight: .medium)
            : .systemFont(ofSize: 11, weight: .regular)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setAccessibilityIdentifier(identifier)
        return label
    }
}
