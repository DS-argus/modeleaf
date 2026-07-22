import AppKit

@MainActor
final class EmptyStateView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Open a PDF")
    private let subtitleLabel = NSTextField(labelWithString: "Use your configured open binding or the button below")
    private let footerLabel = NSTextField(labelWithString: "read-only  ·  tabs  ·  vim keys")
    let openButton = ClosureButton(title: "Open PDF…", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("PDF reader empty state")
        setAccessibilityIdentifier("emptyState")

        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 1

        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 2

        footerLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        footerLabel.alignment = .center

        openButton.controlSize = .large
        openButton.isBordered = false
        openButton.wantsLayer = true
        openButton.layer?.cornerRadius = WindowVisualMetrics.cornerRadius
        openButton.setAccessibilityIdentifier("empty.openButton")
        openButton.setAccessibilityLabel("Open PDF")

        let stack = NSStackView(views: [titleLabel, subtitleLabel, openButton, footerLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(20, after: subtitleLabel)
        stack.setCustomSpacing(18, after: openButton)
        stack.prepareForAutoLayout()
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            openButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 132),
            openButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func apply(theme: AppKitTheme) {
        titleLabel.textColor = theme[.foreground]
        subtitleLabel.textColor = theme[.mutedText]
        footerLabel.textColor = theme[.mutedText]
        openButton.layer?.backgroundColor = theme[.accent].cgColor
        openButton.attributedTitle = NSAttributedString(
            string: openButton.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: theme[.background],
            ]
        )
    }
}
