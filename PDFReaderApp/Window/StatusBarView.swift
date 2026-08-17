import AppKit

enum StatusTone: Equatable {
    case normal
    case error
}

struct StatusBarPresentation: Equatable {
    var page: String
    var zoom: String
    var mode: String = ""
    var isSearchMode: Bool = false
    var transientNotice: String = ""
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
    private let fitPagePill = StatusModePillView(identifier: "status.mode", accessibilityLabel: "Fit page mode")
    private let searchModePill = StatusModePillView(identifier: "status.searchMode", accessibilityLabel: "Search mode")
    private let noticePill = StatusModePillView(identifier: "status.notice", accessibilityLabel: "Temporary status")
    private let versionLabel = StatusBarView.makeLabel(identifier: "status.version", monospaced: true)
    private let updateButton = StatusUpdateButton(title: "", target: nil, action: nil)
    private let separator = NSBox()
    private var theme: AppKitTheme?
    private static let noticeAccent = NSColor.systemOrange
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

        for view in [pageLabel, zoomLabel, prefixLabel, fitPagePill, searchModePill, noticePill] {
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let leading = NSStackView(views: [helpButton, pageLabel, zoomLabel, fitPagePill, searchModePill, noticePill, prefixLabel])
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
        updateButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        updateButton.setContentHuggingPriority(.required, for: .horizontal)
        updateButton.setAccessibilityIdentifier("status.update")
        updateButton.prepareForAutoLayout()
        updateButton.setAccessibilityLabel("View update instructions")
        updateButton.toolTip = "View update instructions"
        updateButton.onHoverChange = { [weak updateButton] hovering in
            updateButton?.layer?.backgroundColor = hovering
                ? (updateButton?.contentTintColor ?? .controlAccentColor).withAlphaComponent(0.12).cgColor
                : NSColor.clear.cgColor
        }
        addSubview(updateButton)

        detailLabel.alignment = .right
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.prepareForAutoLayout()
        addSubview(detailLabel)

        versionLabel.stringValue = Self.displayVersion
        versionLabel.setAccessibilityLabel("Modeleaf version")
        versionLabel.lineBreakMode = .byTruncatingTail
        versionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        versionLabel.setAccessibilityValue(Self.displayVersion)
        versionLabel.prepareForAutoLayout()
        addSubview(versionLabel)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            updateButton.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: 16),
            updateButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: updateButton.trailingAnchor, constant: 16),
            detailLabel.trailingAnchor.constraint(equalTo: versionLabel.leadingAnchor, constant: -16),
            versionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            versionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        updateButton.contentTintColor = theme[.accent]
        fitPagePill.render(presentation.mode, accent: theme[.accent])
        searchModePill.render(presentation.isSearchMode ? "SEARCH" : "", accent: theme[.accent])
        noticePill.render(presentation.transientNotice, accent: Self.noticeAccent)
        versionLabel.textColor = theme[.mutedText]
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
    var updateToolTipForTesting: String? { updateButton.toolTip }
    var updateIsTruncatedForTesting: Bool {
        !updateButton.isHidden && updateButton.frame.width + 0.5 < updateButton.fittingSize.width
    }
    var updateFrameForTesting: NSRect { updateButton.frame }

    func render(_ presentation: StatusBarPresentation) {
        self.presentation = presentation
        pageLabel.stringValue = presentation.page
        zoomLabel.stringValue = presentation.zoom
        let accent = theme?[.accent]
        fitPagePill.render(presentation.mode, accent: accent)
        searchModePill.render(presentation.isSearchMode ? "SEARCH" : "", accent: accent)
        noticePill.render(presentation.transientNotice, accent: Self.noticeAccent)
        prefixLabel.stringValue = presentation.pendingPrefix.isEmpty ? "" : "prefix  \(presentation.pendingPrefix)"
        detailLabel.stringValue = presentation.detail
        detailLabel.setAccessibilityValue(presentation.detail)
        detailLabel.setAccessibilityHelp(presentation.expandedDetail)
        detailLabel.toolTip = presentation.expandedDetail
        let visibleModes = [presentation.mode, presentation.isSearchMode ? "SEARCH" : ""].filter { !$0.isEmpty }
        let modeDescription = visibleModes.isEmpty ? "" : ", modes \(visibleModes.joined(separator: ", "))"
        let noticeDescription = presentation.transientNotice.isEmpty ? "" : ", status \(presentation.transientNotice)"
        setAccessibilityValue(
            [
                "Keyboard help available. Page \(presentation.page), zoom \(presentation.zoom)\(modeDescription)\(noticeDescription), \(presentation.detail). Version \(Self.displayVersion)",
                presentation.expandedDetail,
            ].compactMap { $0 }.joined(separator: ". ")
        )
        versionLabel.setAccessibilityValue(Self.displayVersion)
        if let theme {
            detailLabel.textColor = presentation.tone == .error ? theme[.error] : theme[.mutedText]
        }
    }

    private static var displayVersion: String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "v\(raw.flatMap { $0.isEmpty ? nil : $0 } ?? "dev")"
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
@MainActor
private final class StatusUpdateButton: NSButton {
    var onHoverChange: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

@MainActor
private final class StatusModePillView: NSView {
    private let label: NSTextField

    init(identifier: String, accessibilityLabel: String) {
        label = NSTextField(labelWithString: "")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.lineBreakMode = .byTruncatingTail
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(accessibilityLabel)
        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.setAccessibilityIdentifier(identifier)
        label.prepareForAutoLayout()
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func render(_ text: String, accent: NSColor?) {
        label.stringValue = text
        isHidden = text.isEmpty
        setAccessibilityValue(text)
        label.isHidden = text.isEmpty
        guard let accent else { return }
        label.textColor = accent
        layer?.backgroundColor = accent.withAlphaComponent(0.16).cgColor
        layer?.borderColor = accent.withAlphaComponent(0.55).cgColor
        layer?.borderWidth = 1
    }
}
