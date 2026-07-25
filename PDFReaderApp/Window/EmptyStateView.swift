import AppKit
import PDFReaderCore

@MainActor
final class EmptyStateView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Open a PDF")
    private let subtitleLabel = NSTextField(labelWithString: "Choose a document to start reading")
    private let shortcutBadge = NSView()
    private let shortcutLabel = NSTextField(labelWithString: "⌘O")
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

        shortcutLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        shortcutLabel.alignment = .center
        shortcutLabel.setAccessibilityIdentifier("empty.openShortcut")
        shortcutLabel.setAccessibilityLabel("Open PDF shortcut")
        shortcutLabel.prepareForAutoLayout()

        shortcutBadge.wantsLayer = true
        shortcutBadge.layer?.cornerRadius = 4
        shortcutBadge.setAccessibilityIdentifier("empty.openShortcutBadge")
        shortcutBadge.prepareForAutoLayout()
        shortcutBadge.addSubview(shortcutLabel)
        NSLayoutConstraint.activate([
            shortcutLabel.leadingAnchor.constraint(equalTo: shortcutBadge.leadingAnchor, constant: 8),
            shortcutLabel.trailingAnchor.constraint(equalTo: shortcutBadge.trailingAnchor, constant: -8),
            shortcutLabel.topAnchor.constraint(equalTo: shortcutBadge.topAnchor, constant: 3),
            shortcutLabel.bottomAnchor.constraint(equalTo: shortcutBadge.bottomAnchor, constant: -3),
        ])

        footerLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        footerLabel.alignment = .center

        openButton.controlSize = .large
        openButton.isBordered = false
        openButton.focusRingType = .none
        openButton.wantsLayer = true
        openButton.layer?.cornerRadius = WindowVisualMetrics.cornerRadius
        openButton.layer?.borderWidth = 0
        openButton.setAccessibilityIdentifier("empty.openButton")
        openButton.setAccessibilityLabel("Open PDF")

        let stack = NSStackView(views: [titleLabel, subtitleLabel, openButton, shortcutBadge, footerLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(20, after: subtitleLabel)
        stack.setCustomSpacing(6, after: openButton)
        stack.setCustomSpacing(18, after: shortcutBadge)
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
        shortcutLabel.textColor = theme[.accent]
        shortcutBadge.layer?.backgroundColor = theme[.accent].withAlphaComponent(0.10).cgColor
        shortcutBadge.layer?.borderWidth = 1
        shortcutBadge.layer?.borderColor = theme[.accent].withAlphaComponent(0.32).cgColor
        footerLabel.textColor = theme[.mutedText]
        openButton.layer?.borderWidth = 0
        openButton.layer?.backgroundColor = theme[.accent].cgColor
        openButton.attributedTitle = NSAttributedString(
            string: openButton.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: theme[.background],
            ]
        )
    }

    func setOpenBinding(_ sequence: KeySequence?) {
        guard let sequence, !sequence.tokens.isEmpty else {
            shortcutLabel.stringValue = ""
            shortcutLabel.isHidden = true
            shortcutBadge.isHidden = true
            shortcutLabel.setAccessibilityValue(nil)
            return
        }

        let displayValue = sequence.tokens.map(Self.displayValue(for:)).joined(separator: " ")
        shortcutLabel.stringValue = displayValue
        shortcutLabel.isHidden = false
        shortcutBadge.isHidden = false
        shortcutLabel.setAccessibilityValue(displayValue)
    }

    private static func displayValue(for token: KeyToken) -> String {
        let modifiers = [
            token.modifiers.contains(.control) ? "⌃" : "",
            token.modifiers.contains(.option) ? "⌥" : "",
            token.modifiers.contains(.shift) ? "⇧" : "",
            token.modifiers.contains(.command) ? "⌘" : "",
        ].joined()

        let key: String
        switch token.symbol {
        case let .character(character):
            key = token.modifiers.isEmpty ? character : character.uppercased()
        case let .named(namedKey):
            key = displayValue(for: namedKey)
        case .deadKey:
            key = "Dead Key"
        case .imeComposition:
            key = "IME"
        }
        return modifiers + key
    }

    private static func displayValue(for key: NamedKey) -> String {
        switch key {
        case .escape: "Esc"
        case .carriageReturn: "↩"
        case .backspace: "⌫"
        case .deleteForward: "⌦"
        case .tab: "⇥"
        case .left: "←"
        case .right: "→"
        case .up: "↑"
        case .down: "↓"
        case .home: "↖"
        case .end: "↘"
        case .pageUp: "⇞"
        case .pageDown: "⇟"
        case .space: "Space"
        case .backtick: "`"
        case .lessThan: "<"
        case .greaterThan: ">"
        case .plus: "+"
        case .minus: "−"
        case .equal: "="
        case .slash: "/"
        case let .function(number): "F\(number)"
        }
    }
}
