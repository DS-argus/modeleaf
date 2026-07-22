import AppKit

enum StatusTone: Equatable {
    case normal
    case error
}

struct StatusBarPresentation: Equatable {
    var context: String
    var page: String
    var zoom: String
    var pendingPrefix: String
    var detail: String
    var expandedDetail: String?
    var tone: StatusTone

    static let empty = StatusBarPresentation(
        context: ReaderStatusSnapshot.empty.context,
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
    private let contextLabel = StatusBarView.makeLabel(identifier: "status.context", monospaced: true)
    private let pageLabel = StatusBarView.makeLabel(identifier: "status.page", monospaced: true)
    private let zoomLabel = StatusBarView.makeLabel(identifier: "status.zoom", monospaced: true)
    private let prefixLabel = StatusBarView.makeLabel(identifier: "status.prefix", monospaced: true)
    private let detailLabel = StatusBarView.makeLabel(identifier: "status.diagnostic", monospaced: false)
    private let separator = NSBox()
    private var theme: AppKitTheme?
    private(set) var presentation = StatusBarPresentation.empty

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Reader status")
        setAccessibilityIdentifier("statusBar")

        separator.boxType = .separator
        separator.prepareForAutoLayout()
        addSubview(separator)

        let leading = NSStackView(views: [contextLabel, pageLabel, zoomLabel, prefixLabel])
        leading.orientation = .horizontal
        leading.alignment = .centerY
        leading.spacing = 16
        leading.prepareForAutoLayout()
        addSubview(leading)

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
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 16),
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
        contextLabel.textColor = theme[.accent]
        pageLabel.textColor = theme[.mutedText]
        zoomLabel.textColor = theme[.mutedText]
        prefixLabel.textColor = theme[.accent]
        detailLabel.textColor = presentation.tone == .error ? theme[.error] : theme[.mutedText]
    }

    func render(_ presentation: StatusBarPresentation) {
        self.presentation = presentation
        contextLabel.stringValue = presentation.context
        pageLabel.stringValue = presentation.page
        zoomLabel.stringValue = presentation.zoom
        prefixLabel.stringValue = presentation.pendingPrefix.isEmpty ? "" : "prefix  \(presentation.pendingPrefix)"
        detailLabel.stringValue = presentation.detail
        detailLabel.setAccessibilityValue(presentation.detail)
        detailLabel.setAccessibilityHelp(presentation.expandedDetail)
        detailLabel.toolTip = presentation.expandedDetail
        setAccessibilityValue(
            [
                "\(presentation.context), page \(presentation.page), zoom \(presentation.zoom), \(presentation.detail)",
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
