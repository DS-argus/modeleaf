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
        static let rowHeight: CGFloat = 26
    }

    var onCommit: ((ActionID) -> Void)?
    var onCancel: (() -> Void)?

    private let queryField = NSTextField(labelWithString: "")
    private var rows: [PaletteRowView] = []
    private let rowStack = NSStackView()
    private let scrollView = NSScrollView()
    private var listHeightConstraint: NSLayoutConstraint!
    private var bottomBoundaryConstraint: NSLayoutConstraint?

    private var commands: [PaletteCommand] = []
    private var filtered: [PaletteCommand] = []
    private var query = ""
    private var selectedIndex = 0
    private var theme: AppKitTheme?

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
        setAccessibilityLabel("Command palette")
        setAccessibilityIdentifier("commandPaletteOverlay")

        queryField.font = .systemFont(ofSize: 15, weight: .regular)
        queryField.lineBreakMode = .byTruncatingTail
        queryField.setAccessibilityIdentifier("commandPalette.query")

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 2
        rowStack.prepareForAutoLayout()

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = rowStack
        scrollView.prepareForAutoLayout()
        listHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: Metrics.rowHeight)
        listHeightConstraint.priority = .defaultHigh
        listHeightConstraint.isActive = true
        scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: CGFloat(Metrics.maxVisibleRows) * Metrics.rowHeight).isActive = true

        let stack = NSStackView(views: [queryField, scrollView])
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
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rowStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let superview, bottomBoundaryConstraint == nil else { return }
        bottomBoundaryConstraint = bottomAnchor.constraint(lessThanOrEqualTo: superview.bottomAnchor, constant: -40)
        bottomBoundaryConstraint?.isActive = true
    }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        layer?.backgroundColor = theme[.activeTab].withAlphaComponent(0.9).cgColor
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
        selectedIndex = 0
    }

    /// Test seam: the query the user has typed so far.
    var currentQuery: String { query }
    /// Test seam: the id currently highlighted, if any.
    var selectedCommandID: ActionID? { filtered.indices.contains(selectedIndex) ? filtered[selectedIndex].id : nil }
    /// Test seam: the complete filtered result ids, in order.
    var visibleCommandIDs: [ActionID] { filtered.map(\.id) }
    /// Test seam: complete filtered rows, including their displayed shortcut text.
    var visibleCommandsForTesting: [PaletteCommand] { filtered }
    var selectedRowIsVisibleForTesting: Bool {
        guard filtered.indices.contains(selectedIndex), rows.indices.contains(selectedIndex) else { return false }
        layoutSubtreeIfNeeded()
        let row = rows[selectedIndex]
        return scrollView.documentVisibleRect.contains(row.convert(row.bounds, to: rowStack))
    }
    var listRequiresScrollingForTesting: Bool {
        layoutSubtreeIfNeeded()
        return rowStack.frame.height > scrollView.documentVisibleRect.height + 0.5
    }

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
        case 123, 124: // left/right arrows must not become query text
            return true
        default:
            break
        }

        if event.modifierFlags.contains(.control), let characters = event.charactersIgnoringModifiers?.lowercased() {
            switch characters {
            case "j": moveSelection(by: 1); return true
            case "k": moveSelection(by: -1); return true
            default: return false
            }
        }

        guard let typed = event.characters, typed.count == 1, let scalar = typed.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value != 0x7F, !(0xF700...0xF8FF).contains(scalar.value) else {
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
        let ranked = CommandPaletteFilter.rank(commands, query: query)
        filtered = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? ranked.filter(\.isEnabled) + ranked.filter { !$0.isEnabled }
            : ranked
        if resetSelection {
            selectedIndex = filtered.firstIndex(where: \.isEnabled) ?? 0
        } else {
            selectedIndex = min(selectedIndex, max(0, filtered.count - 1))
        }
        renderRows()
        updateListHeight()
        scrollSelectedRowToVisible()
    }

    private func moveSelection(by offset: Int) {
        guard !filtered.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + offset, 0), filtered.count - 1)
        renderRows()
        scrollSelectedRowToVisible()
    }

    private func commitSelection() {
        guard filtered.indices.contains(selectedIndex) else { return }
        let command = filtered[selectedIndex]
        guard command.isEnabled else { return }
        onCommit?(command.id)
    }

    private func ensureRows(for count: Int) {
        while rows.count < count {
            let row = PaletteRowView()
            rows.append(row)
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
    }

    private func updateListHeight() {
        rowStack.layoutSubtreeIfNeeded()
        listHeightConstraint.constant = min(
            rowStack.fittingSize.height,
            CGFloat(Metrics.maxVisibleRows) * Metrics.rowHeight
        )
    }

    private func scrollSelectedRowToVisible() {
        guard rows.indices.contains(selectedIndex) else { return }
        layoutSubtreeIfNeeded()
        rows[selectedIndex].scrollToVisible(rows[selectedIndex].bounds)
    }

    private func renderRows() {
        let placeholder = query.isEmpty
        queryField.stringValue = placeholder ? "Type a command…" : query
        if let theme {
            queryField.textColor = placeholder ? theme[.mutedText] : theme[.foreground]
        }
        setAccessibilityValue(query)

        ensureRows(for: filtered.count)
        for (index, row) in rows.enumerated() {
            if filtered.indices.contains(index) {
                row.isHidden = false
                row.configure(filtered[index], selected: index == selectedIndex, theme: theme)
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
    private let reasonLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcutLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        shortcutLabel.alignment = .right
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        reasonLabel.font = .systemFont(ofSize: 10)
        reasonLabel.lineBreakMode = .byTruncatingTail

        let titleStack = NSStackView(views: [titleLabel, shortcutLabel])
        titleStack.orientation = .horizontal
        titleStack.distribution = .fill
        titleStack.spacing = 12
        let stack = NSStackView(views: [titleStack, reasonLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.prepareForAutoLayout()
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            reasonLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ command: PaletteCommand, selected: Bool, theme: AppKitTheme?) {
        titleLabel.stringValue = command.title
        shortcutLabel.stringValue = command.shortcut ?? ""
        reasonLabel.stringValue = command.disabledReason ?? ""
        reasonLabel.isHidden = command.disabledReason == nil
        guard let theme else { return }
        let base = command.isEnabled ? theme[.foreground] : theme[.mutedText].withAlphaComponent(0.35)
        titleLabel.textColor = selected && command.isEnabled ? theme[.accent] : base
        titleLabel.font = .systemFont(ofSize: 12, weight: selected && command.isEnabled ? .semibold : .regular)
        shortcutLabel.textColor = theme[.mutedText].withAlphaComponent(command.isEnabled ? 1.0 : 0.35)
        reasonLabel.textColor = theme[.mutedText].withAlphaComponent(0.55)
        layer?.backgroundColor = (selected ? theme.separator : NSColor.clear).cgColor
    }
}
