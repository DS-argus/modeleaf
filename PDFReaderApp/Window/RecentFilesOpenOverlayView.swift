import AppKit
import PDFReaderCore

@MainActor
final class RecentFilesOpenOverlayView: NSView {
    private enum Metrics {
        static let width: CGFloat = 360 // matches CommandPalette; 360+32 padding+80 margins fits the 480pt minimum window
        static let maxVisibleRows = RecentFilesStore.maximumEntries + 1
    }

    var onBrowse: (() -> Void)?
    var onOpenRecent: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let queryField = NSTextField(labelWithString: "")
    private let rows = (0..<Metrics.maxVisibleRows).map { _ in RecentFilesOpenRowView() }
    private let rowStack = NSStackView()
    private var entries: [RecentFileEntry] = []
    private var filtered: [RecentFileMatch] = []
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
        setAccessibilityLabel("Open recent file")
        setAccessibilityIdentifier("recentFilesOpenOverlay")

        queryField.font = .systemFont(ofSize: 15)
        queryField.lineBreakMode = .byTruncatingTail
        queryField.setAccessibilityIdentifier("recentFiles.query")
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 2
        for row in rows {
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }

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

    func present(entries: [RecentFileEntry]) {
        self.entries = entries
        query = ""
        isHidden = false
        applyFilter(resetSelection: true)
    }

    func dismiss() {
        isHidden = true
        entries = []
        filtered = []
        query = ""
        selectedIndex = 0
    }

    var currentQuery: String { query }
    var selectedIndexForTesting: Int { selectedIndex }
    var visibleRowsForTesting: [String] {
        ["Browse…"] + filtered.prefix(Metrics.maxVisibleRows - 1).map { $0.entry.absolutePath }
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) { return false }
        switch event.keyCode {
        case 53:
            onCancel?()
            return true
        case 36, 76:
            commitSelection()
            return true
        case 51:
            if !query.isEmpty {
                query.removeLast()
                applyFilter(resetSelection: true)
            }
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
              scalar.value >= 0x20, scalar.value != 0x7F else { return false }
        query.append(Character(scalar))
        applyFilter(resetSelection: true)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !handleKeyDown(event) { super.keyDown(with: event) }
    }

    private func applyFilter(resetSelection: Bool) {
        filtered = RecentFileFilter.rank(entries, query: query)
        if resetSelection {
            selectedIndex = query.isEmpty ? 0 : (filtered.isEmpty ? 0 : 1)
        } else {
            selectedIndex = min(selectedIndex, filtered.count)
        }
        renderRows()
    }

    private func moveSelection(by offset: Int) {
        let lastIndex = min(filtered.count, Metrics.maxVisibleRows - 1)
        selectedIndex = min(max(selectedIndex + offset, 0), lastIndex)
        renderRows()
    }

    private func commitSelection() {
        if selectedIndex == 0 {
            onBrowse?()
        } else if filtered.indices.contains(selectedIndex - 1) {
            onOpenRecent?(filtered[selectedIndex - 1].entry.absolutePath)
        }
    }

    private func renderRows() {
        let placeholder = query.isEmpty
        queryField.stringValue = placeholder ? "Type to search…" : query
        queryField.textColor = theme.map { placeholder ? $0[.mutedText] : $0[.foreground] }
        setAccessibilityValue(query)
        for (index, row) in rows.enumerated() {
            if index == 0 {
                row.isHidden = false
                row.configure(title: "Browse…", path: nil, selected: selectedIndex == 0, theme: theme)
            } else if filtered.indices.contains(index - 1) {
                let entry = filtered[index - 1].entry
                row.isHidden = false
                row.configure(title: URL(fileURLWithPath: entry.absolutePath).lastPathComponent, path: entry.absolutePath, selected: selectedIndex == index, theme: theme)
            } else {
                row.isHidden = true
            }
        }
    }
}

@MainActor
private final class RecentFilesOpenRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        titleLabel.font = .systemFont(ofSize: 13)
        pathLabel.font = .systemFont(ofSize: 11)
        titleLabel.lineBreakMode = .byTruncatingTail
        pathLabel.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [titleLabel, pathLabel])
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
            stack.widthAnchor.constraint(equalTo: widthAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(title: String, path: String?, selected: Bool, theme: AppKitTheme?) {
        titleLabel.stringValue = title
        pathLabel.stringValue = path ?? ""
        pathLabel.isHidden = path == nil
        guard let theme else { return }
        titleLabel.textColor = selected ? theme[.accent] : theme[.foreground]
        titleLabel.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        pathLabel.textColor = theme[.mutedText]
        layer?.backgroundColor = (selected ? theme.separator : NSColor.clear).cgColor
    }
}
