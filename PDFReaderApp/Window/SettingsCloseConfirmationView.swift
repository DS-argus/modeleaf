import AppKit

/// The keyboard-first close decision shown when Settings has an unsaved draft.
/// This is deliberately not an NSAlert: h/l, n/y, and Escape have explicit
/// meanings and must never leak into the settings window underneath it.
@MainActor
final class SettingsCloseConfirmationView: NSView {
    enum Choice: Equatable {
        case continueEditing
        case discardAndClose
        case saveAndClose
    }

    private let titleLabel = NSTextField(labelWithString: "Unsaved Changes")
    private let messageLabel = NSTextField(labelWithString: "Save changes before closing Settings?")
    private let hintLabel = NSTextField(labelWithString: "")
    private let buttonStack = NSStackView()
    private let continueButton = ClosureButton(frame: .zero)
    private let discardButton = ClosureButton(frame: .zero)
    private let saveButton = ClosureButton(frame: .zero)
    private var buttons: [ClosureButton] { [continueButton, discardButton, saveButton] }
    private var theme = AppKitTheme(themeID: .tokyoNight)
    private var selectedIndex = 2
    private var result: Choice?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 440, height: 140) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = WindowVisualMetrics.cornerRadius
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Unsaved settings changes")
        setAccessibilityIdentifier("settings.closeConfirmation")

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.setAccessibilityIdentifier("settings.closeConfirmation.title")
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.setAccessibilityIdentifier("settings.closeConfirmation.message")
        messageLabel.maximumNumberOfLines = 2
        messageLabel.lineBreakMode = .byWordWrapping
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.maximumNumberOfLines = 1
        hintLabel.setAccessibilityIdentifier("settings.closeConfirmation.hint")

        configureButton(continueButton, title: "Continue Editing", identifier: "settings.closeConfirmation.continue")
        configureButton(discardButton, title: "Discard and Close", identifier: "settings.closeConfirmation.discard")
        configureButton(saveButton, title: "Save and Close", identifier: "settings.closeConfirmation.save")
        continueButton.handler = { [weak self] in self?.resolve(.continueEditing) }
        discardButton.handler = { [weak self] in self?.resolve(.discardAndClose) }
        saveButton.handler = { [weak self] in self?.resolve(.saveAndClose) }

        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        buttonStack.addArrangedSubview(continueButton)
        buttonStack.addArrangedSubview(discardButton)
        buttonStack.addArrangedSubview(saveButton)
        buttonStack.prepareForAutoLayout()

        for view in [titleLabel, messageLabel, hintLabel] { view.prepareForAutoLayout() }
        addSubview(titleLabel)
        addSubview(messageLabel)
        addSubview(buttonStack)
        addSubview(hintLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            buttonStack.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 12),
            buttonStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            buttonStack.heightAnchor.constraint(equalToConstant: 28),
            hintLabel.topAnchor.constraint(equalTo: buttonStack.bottomAnchor, constant: 9),
            hintLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])

        apply(theme: theme)
    }

    required init?(coder: NSCoder) { nil }

    /// The default is intentionally Save and Close, matching the approved
    /// close contract while keeping Escape an explicit Continue action.
    var selectedChoiceForTesting: Choice {
        choice(for: selectedIndex)
    }

    var selectedIndexForTesting: Int { selectedIndex }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        appearance = NSAppearance(named: theme.id == .catppuccinLatte ? .aqua : .darkAqua)
        layer?.backgroundColor = theme[.activeTab].withAlphaComponent(0.98).cgColor
        layer?.borderColor = theme.focusRing.cgColor
        layer?.borderWidth = 1
        titleLabel.textColor = theme[.accent]
        messageLabel.textColor = theme[.foreground]
        hintLabel.attributedStringValue = SettingsKeyboardHint.make(
            text: "h / l  Select    ↩  Choose    Esc  Continue    n  Discard    y  Save",
            keys: ["h / l", "↩", "Esc", "n", "y"], theme: theme
        )
        for button in buttons {
            button.contentTintColor = theme[.foreground]
        }
        updateSelectionAppearance()
    }

    /// Runs a synchronous app-modal panel so existing Bool window-close and
    /// app-quit callers can continue to decide whether the close is allowed.
    static func runModal(
        attachedTo parent: NSWindow?,
        theme: AppKitTheme,
        ignoring triggerEvent: NSEvent? = nil
    ) -> Choice {
        let prompt = SettingsCloseConfirmationView(frame: NSRect(x: 0, y: 0, width: 440, height: 140))
        prompt.apply(theme: theme)
        let panel = SettingsCloseConfirmationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 140),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .modalPanel
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false
        panel.ignoredTriggerEvent = triggerEvent
        panel.contentView = prompt
        panel.initialFirstResponder = prompt

        if let parent {
            parent.addChildWindow(panel, ordered: .above)
            let parentFrame = parent.frame
            panel.setFrameOrigin(NSPoint(
                x: parentFrame.midX - panel.frame.width / 2,
                y: parentFrame.midY - panel.frame.height / 2
            ))
        } else {
            panel.center()
        }

        panel.makeKeyAndOrderFront(nil)
        _ = NSApp.runModal(for: panel)
        let choice = prompt.result ?? .continueEditing
        if let parent { parent.removeChildWindow(panel) }
        panel.orderOut(nil)
        panel.contentView = nil
        return choice
    }

    /// All key-down events are consumed by the modal panel, including unknown
    /// keys and held repeats. This prevents a prompt trigger from being reused
    /// by the settings shell after the modal loop exits.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard !event.isARepeat else { return true }
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if event.keyCode == 53 {
            resolve(.continueEditing)
            return true
        }
        if plain, [36, 76].contains(event.keyCode) {
            resolve(choice(for: selectedIndex))
            return true
        }
        if plain && (event.keyCode == 123 || event.charactersIgnoringModifiers?.lowercased() == "h") {
            select(index: selectedIndex - 1)
            return true
        }
        if plain && (event.keyCode == 124 || event.charactersIgnoringModifiers?.lowercased() == "l") {
            select(index: selectedIndex + 1)
            return true
        }
        if plain, event.charactersIgnoringModifiers?.lowercased() == "n" {
            resolve(.discardAndClose)
            return true
        }
        if plain, event.charactersIgnoringModifiers?.lowercased() == "y" {
            resolve(.saveAndClose)
            return true
        }
        return true
    }

    private func configureButton(_ button: ClosureButton, title: String, identifier: String) {
        button.title = title
        button.font = .systemFont(ofSize: 11.5)
        button.controlSize = .regular
        button.isBordered = false
        button.focusRingType = .none
        button.keyEquivalent = ""
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(identifier)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.layer?.masksToBounds = true
        button.prepareForAutoLayout()
    }

    private func select(index: Int) {
        selectedIndex = min(max(index, 0), buttons.count - 1)
        updateSelectionAppearance()
    }

    private func choice(for index: Int) -> Choice {
        switch index {
        case 0: return .continueEditing
        case 1: return .discardAndClose
        default: return .saveAndClose
        }
    }

    private func resolve(_ choice: Choice) {
        result = choice
        guard NSApp.modalWindow?.contentView === self else { return }
        NSApp.stopModal(withCode: .OK)
    }

    private func updateSelectionAppearance() {
        for (index, button) in buttons.enumerated() {
            let selected = index == selectedIndex
            button.font = .systemFont(ofSize: 11.5, weight: selected ? .semibold : .regular)
            button.layer?.backgroundColor = selected
                ? theme[.accent].withAlphaComponent(0.24).cgColor
                : NSColor.clear.cgColor
        }
    }

}

@MainActor
private final class SettingsCloseConfirmationPanel: NSPanel {
    var ignoredTriggerEvent: NSEvent?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event === ignoredTriggerEvent { return true }
        guard let prompt = contentView as? SettingsCloseConfirmationView else { return true }
        return prompt.handleKeyDown(event)
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if event === ignoredTriggerEvent {
                return
            }
            if let prompt = contentView as? SettingsCloseConfirmationView {
                _ = prompt.handleKeyDown(event)
                return
            }
        }
        super.sendEvent(event)
    }
}
