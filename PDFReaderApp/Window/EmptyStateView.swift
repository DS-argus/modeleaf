import AppKit
import PDFReaderCore

@MainActor
final class EmptyStateView: NSView {
    private let actionPill = PointerActionView()
    private let folderIcon = NSImageView()
    private let separator = NSView()
    private let shortcutBadge = NSView()
    private let shortcutLabel = NSTextField(labelWithString: "⌘O")
    let openButton = ClosureButton(title: "Open PDF", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("PDF reader empty state")
        setAccessibilityIdentifier("emptyState")

        actionPill.wantsLayer = true
        actionPill.layer?.cornerRadius = 25
        actionPill.setAccessibilityIdentifier("empty.openActionPill")
        actionPill.prepareForAutoLayout()
        actionPill.onPointerActivate = { [weak openButton] in
            openButton?.performClick(nil)
        }

        folderIcon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        folderIcon.imageScaling = .scaleProportionallyUpOrDown
        folderIcon.setAccessibilityIdentifier("empty.openFolderIcon")
        folderIcon.contentTintColor = .controlAccentColor
        folderIcon.prepareForAutoLayout()

        openButton.controlSize = .large
        openButton.isBordered = false
        openButton.focusRingType = .none
        openButton.wantsLayer = true
        openButton.showsPointingHandCursor = true
        openButton.setAccessibilityIdentifier("empty.openButton")
        openButton.setAccessibilityLabel("Open PDF")
        openButton.prepareForAutoLayout()

        separator.wantsLayer = true
        separator.prepareForAutoLayout()

        shortcutLabel.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        shortcutLabel.alignment = .center
        shortcutLabel.setAccessibilityIdentifier("empty.openShortcut")
        shortcutLabel.setAccessibilityLabel("Open PDF shortcut")
        shortcutLabel.prepareForAutoLayout()

        shortcutBadge.wantsLayer = true
        shortcutBadge.layer?.cornerRadius = 7
        shortcutBadge.setAccessibilityIdentifier("empty.openShortcutBadge")
        shortcutBadge.prepareForAutoLayout()
        shortcutBadge.addSubview(shortcutLabel)
        NSLayoutConstraint.activate([
            shortcutLabel.leadingAnchor.constraint(equalTo: shortcutBadge.leadingAnchor, constant: 9),
            shortcutLabel.trailingAnchor.constraint(equalTo: shortcutBadge.trailingAnchor, constant: -9),
            shortcutLabel.topAnchor.constraint(equalTo: shortcutBadge.topAnchor, constant: 5),
            shortcutLabel.bottomAnchor.constraint(equalTo: shortcutBadge.bottomAnchor, constant: -5),
        ])

        actionPill.addSubview(folderIcon)
        actionPill.addSubview(openButton)
        actionPill.addSubview(separator)
        actionPill.addSubview(shortcutBadge)
        addSubview(actionPill)

        NSLayoutConstraint.activate([
            actionPill.centerXAnchor.constraint(equalTo: centerXAnchor),
            actionPill.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionPill.widthAnchor.constraint(equalToConstant: 286),
            actionPill.heightAnchor.constraint(equalToConstant: 50),

            folderIcon.leadingAnchor.constraint(equalTo: actionPill.leadingAnchor, constant: 18),
            folderIcon.centerYAnchor.constraint(equalTo: actionPill.centerYAnchor),
            folderIcon.widthAnchor.constraint(equalToConstant: 24),
            folderIcon.heightAnchor.constraint(equalToConstant: 24),

            shortcutBadge.trailingAnchor.constraint(equalTo: actionPill.trailingAnchor, constant: -10),
            shortcutBadge.centerYAnchor.constraint(equalTo: actionPill.centerYAnchor),

            separator.trailingAnchor.constraint(equalTo: shortcutBadge.leadingAnchor, constant: -10),
            separator.centerYAnchor.constraint(equalTo: actionPill.centerYAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 24),

            openButton.leadingAnchor.constraint(equalTo: folderIcon.trailingAnchor, constant: 6),
            openButton.trailingAnchor.constraint(equalTo: separator.leadingAnchor, constant: -6),
            openButton.centerYAnchor.constraint(equalTo: actionPill.centerYAnchor),
            openButton.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        actionPill.layer?.shadowPath = CGPath(
            roundedRect: actionPill.bounds,
            cornerWidth: 25,
            cornerHeight: 25,
            transform: nil
        )
    }

    func apply(theme: AppKitTheme) {
        let accent = theme[.accent]
        actionPill.layer?.backgroundColor = theme[.background].withAlphaComponent(0.86).cgColor
        actionPill.layer?.borderWidth = 1
        actionPill.layer?.borderColor = accent.withAlphaComponent(0.62).cgColor
        actionPill.layer?.shadowColor = accent.cgColor
        actionPill.layer?.shadowOpacity = 0.34
        actionPill.layer?.shadowRadius = 14
        actionPill.layer?.shadowOffset = NSSize(width: 0, height: -2)

        folderIcon.contentTintColor = accent
        separator.layer?.backgroundColor = theme[.mutedText].withAlphaComponent(0.26).cgColor
        shortcutLabel.textColor = accent
        shortcutBadge.layer?.backgroundColor = accent.withAlphaComponent(0.06).cgColor
        shortcutBadge.layer?.borderWidth = 1
        shortcutBadge.layer?.borderColor = accent.withAlphaComponent(0.22).cgColor
        openButton.layer?.borderWidth = 0
        openButton.layer?.backgroundColor = NSColor.clear.cgColor
        openButton.attributedTitle = NSAttributedString(
            string: openButton.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 17, weight: .medium),
                .foregroundColor: theme[.foreground],
            ]
        )
    }

    func setOpenBinding(_ sequence: KeySequence?) {
        guard let sequence, !sequence.tokens.isEmpty else {
            shortcutLabel.stringValue = ""
            shortcutLabel.isHidden = true
            shortcutBadge.isHidden = true
            separator.isHidden = true
            shortcutLabel.setAccessibilityValue(nil)
            return
        }

        let displayValue = sequence.tokens.map(Self.displayValue(for:)).joined(separator: " ")
        shortcutLabel.stringValue = displayValue
        shortcutLabel.isHidden = false
        shortcutBadge.isHidden = false
        separator.isHidden = false
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
