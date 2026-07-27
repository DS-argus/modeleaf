import AppKit
import PDFReaderCore

/// A transient, keyboard-driven command palette. Like the theme picker it is a
/// self-contained overlay that becomes first responder while visible; the window
/// routes key events straight to `handleKeyDown`. The query is a manual ASCII
/// buffer (command titles are English) so no field editor / IME plumbing is
/// needed. Rows show the command title, its bound shortcut, and dim when the
/// command cannot run in the current context.
@MainActor
final class CommandPaletteOverlayView: NSView {
    private enum Metrics {
        static let width: CGFloat = 360
        static let maxVisibleRows = 12
    }

    var onCommit: ((ActionID) -> Void)?
    var onCancel: (() -> Void)?

    private let queryField = NSTextField(labelWithString: "")
    private let rows: [PaletteRowView]
    private let rowStack = NSStackView()

    private var commands: [PaletteCommand] = []
    private var filtered: [PaletteCommand] = []
    private var query = ""
    private var selectedIndex = 0
    private var theme: AppKitTheme?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        rows = (0..<Metrics.maxVisibleRows).map { _ in PaletteRowView() }
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = WindowVisualMetrics.cornerRadius
        layer?.masksToBounds = false
        shadow = NSShadow()
        shadow?.shadowBlurRadius = 16
        shadow?.shadowOffset = NSSize(width: 0, height: -4)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Command palette")
        setAccessibilityIdentifier("commandPaletteOverlay")

        queryField.font = .systemFont(ofSize: 15, weight: .regular)
        queryField.lineBreakMode = .byTruncatingTail
        queryField.setAccessibilityIdentifier("commandPalette.query")

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 2
        for row in rows { rowStack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true }

        let stack = NSStackView(views: [queryField, rowStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.prepareForAutoLayout()
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            stack.widthAnchor.constraint(equalToConstant: Metrics.width),
            rowStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        layer?.backgroundColor = theme[.activeTab].withAlphaComponent(0.8).cgColor
        layer?.borderColor = theme.focusRing.cgColor
        layer?.borderWidth = 1
        shadow?.shadowColor = theme.overlayShadow
        renderRows()
    }

    /// Present with the full command list already resolved (title, shortcut, and
    /// enabled state) by the caller.
    func present(commands: [PaletteCommand]) {
        self.commands = commands
        query = ""
        isHidden = false
        applyFilter(resetSelection: true)
    }

    func dismiss() {
        isHidden = true
        commands = []
        filtered = []
        query = ""
    }

    /// Test seam: the query the user has typed so far.
    var currentQuery: String { query }
    /// Test seam: the id currently highlighted, if any.
    var selectedCommandID: ActionID? { filtered.indices.contains(selectedIndex) ? filtered[selectedIndex].id : nil }
    /// Test seam: the ids currently visible, in order.
    var visibleCommandIDs: [ActionID] { filtered.prefix(Metrics.maxVisibleRows).map(\.id) }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        // Let Command chords (⌘Q, ⌘W, …) fall through to the normal router.
        if event.modifierFlags.contains(.command) { return false }

        switch event.keyCode {
        case 53: // esc
            onCancel?()
            return true
        case 36, 76: // return / enter
            commitSelection()
            return true
        case 125: // down arrow
            moveSelection(by: 1)
            return true
        case 126: // up arrow
            moveSelection(by: -1)
            return true
        case 51: // delete / backspace
            if !query.isEmpty {
                query.removeLast()
                applyFilter(resetSelection: true)
            }
            return true
        default:
            break
        }

        // Ctrl-n / Ctrl-p mirror the arrow keys for keyboard-home users.
        if event.modifierFlags.contains(.control), let characters = event.charactersIgnoringModifiers?.lowercased() {
            switch characters {
            case "n": moveSelection(by: 1); return true
            case "p": moveSelection(by: -1); return true
            default: return false
            }
        }

        guard let typed = event.characters, typed.count == 1, let scalar = typed.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value != 0x7F else {
            return false
        }
        query.append(Character(scalar))
        applyFilter(resetSelection: true)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !handleKeyDown(event) { super.keyDown(with: event) }
    }

    private func applyFilter(resetSelection: Bool) {
        filtered = CommandPaletteFilter.rank(commands, query: query)
        if resetSelection {
            selectedIndex = filtered.firstIndex(where: \.isEnabled) ?? 0
        } else {
            selectedIndex = min(selectedIndex, max(0, filtered.count - 1))
        }
        renderRows()
    }

    private func moveSelection(by offset: Int) {
        let visible = min(filtered.count, Metrics.maxVisibleRows)
        guard visible > 0 else { return }
        selectedIndex = min(max(selectedIndex + offset, 0), visible - 1)
        renderRows()
    }

    private func commitSelection() {
        guard filtered.indices.contains(selectedIndex) else { return }
        let command = filtered[selectedIndex]
        guard command.isEnabled else { return }
        onCommit?(command.id)
    }

    private func renderRows() {
        let placeholder = query.isEmpty
        queryField.stringValue = placeholder ? "Type a command…" : query
        if let theme {
            queryField.textColor = placeholder ? theme[.mutedText] : theme[.foreground]
        }
        setAccessibilityValue(query)

        let visible = Array(filtered.prefix(Metrics.maxVisibleRows))
        for (index, row) in rows.enumerated() {
            if index < visible.count {
                row.isHidden = false
                row.configure(visible[index], selected: index == selectedIndex, theme: theme)
            } else {
                row.isHidden = true
            }
        }
    }
}

@MainActor
private final class PaletteRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcutLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        shortcutLabel.alignment = .right
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [titleLabel, shortcutLabel])
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.spacing = 12
        stack.prepareForAutoLayout()
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ command: PaletteCommand, selected: Bool, theme: AppKitTheme?) {
        titleLabel.stringValue = command.title
        shortcutLabel.stringValue = command.shortcut ?? ""
        guard let theme else { return }
        let base = command.isEnabled ? theme[.foreground] : theme[.mutedText].withAlphaComponent(0.35)
        titleLabel.textColor = selected && command.isEnabled ? theme[.accent] : base
        titleLabel.font = .systemFont(ofSize: 13, weight: selected && command.isEnabled ? .semibold : .regular)
        shortcutLabel.textColor = theme[.mutedText].withAlphaComponent(command.isEnabled ? 1.0 : 0.35)
        layer?.backgroundColor = (selected ? theme.separator : NSColor.clear).cgColor
    }
}
