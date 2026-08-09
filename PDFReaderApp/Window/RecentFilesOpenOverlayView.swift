import AppKit
import PDFReaderCore

@MainActor
final class RecentFilesOpenOverlayView: NSView {
    private enum Metrics {
        static let maxVisibleRows = RecentFilesStore.maximumEntries + 1 // Browse + all 15 recents visible at once; scrolls only when the window is too small
        static let rowHeight: CGFloat = 32
    }

    private static let keyHintText = "⌃j / ⌃k  Move selection    ⌃c  Clear recents    ↩  Open    Esc  Close"
    private static let shortcutLabels = ["⌃j / ⌃k", "⌃c", "↩", "Esc"]

    var onBrowse: (() -> Void)?
    var onOpenRecent: ((String) -> Void)?
    var onClear: (() -> Void)?
    var onCancel: (() -> Void)?

    private let queryField = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let keyHintLabel = NSTextField(labelWithString: RecentFilesOpenOverlayView.keyHintText)
    private let rows = (0...RecentFilesStore.maximumEntries).map { _ in RecentFilesOpenRowView() }
    private let rowStack = NSStackView()
    private let scrollView = NSScrollView()
    private var listHeightConstraint: NSLayoutConstraint!
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
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.isHidden = true
        errorLabel.setAccessibilityIdentifier("recentFiles.error")
        keyHintLabel.font = .systemFont(ofSize: 11)
        keyHintLabel.maximumNumberOfLines = 1
        keyHintLabel.lineBreakMode = .byTruncatingTail
        keyHintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keyHintLabel.setAccessibilityIdentifier("recentFiles.keyHint")
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 2
        for (index, row) in rows.enumerated() {
            row.onPointerEnter = { [weak self] in self?.selectRow(at: index, commit: false) }
            row.onPointerActivate = { [weak self] in self?.selectRow(at: index, commit: true) }
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = rowStack
        scrollView.prepareForAutoLayout()
        rowStack.prepareForAutoLayout()
        listHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: Metrics.rowHeight)
        listHeightConstraint.isActive = true

        listHeightConstraint.priority = .defaultHigh
        let stack = NSStackView(views: [queryField, errorLabel, scrollView, keyHintLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.prepareForAutoLayout()
        let preferredWidth = max(360, ceil(keyHintLabel.intrinsicContentSize.width))
        let overlayWidth = stack.widthAnchor.constraint(equalToConstant: preferredWidth)
        overlayWidth.priority = .fittingSizeCompression
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            overlayWidth,
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: preferredWidth),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rowStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        layer?.backgroundColor = theme[.activeTab].withAlphaComponent(0.9).cgColor
        layer?.borderColor = theme.focusRing.cgColor
        layer?.borderWidth = 1
        shadow?.shadowColor = theme.overlayShadow
        errorLabel.textColor = theme[.error]
        keyHintLabel.textColor = theme[.mutedText]
        renderKeyHint()
        renderRows()
    }

    func present(entries: [RecentFileEntry]) {
        self.entries = entries.filter { Self.isPDFPath($0.absolutePath) }
        query = ""
        errorLabel.isHidden = true
        isHidden = false
        applyFilter(resetSelection: true)
    }

    func refresh(entries: [RecentFileEntry]) {
        self.entries = entries.filter { Self.isPDFPath($0.absolutePath) }
        applyFilter(resetSelection: false)
    }

    func showInlineError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    func clearInlineError() { errorLabel.isHidden = true }

    func dismiss() {
        isHidden = true
        entries = []
        filtered = []
        query = ""
        selectedIndex = 0
        errorLabel.isHidden = true
    }

    var currentQuery: String { query }
    var selectedIndexForTesting: Int { selectedIndex }
    var visibleRowsForTesting: [String] { ["Browse…"] + filtered.map { $0.entry.absolutePath } }
    var displayedDirectoriesForTesting: [String] { filtered.map { Self.displayDirectory(for: $0.entry.absolutePath) } }
    var inlineErrorForTesting: String? { errorLabel.isHidden ? nil : errorLabel.stringValue }
    var keyHintForTesting: String { keyHintLabel.stringValue }
    var keyHintAttributedForTesting: NSAttributedString { keyHintLabel.attributedStringValue }
    var selectedRowIsVisibleForTesting: Bool {
        layoutSubtreeIfNeeded()
        let row = rows[selectedIndex]
        let rowRect = row.convert(row.bounds, to: rowStack)
        return scrollView.documentVisibleRect.contains(rowRect)
    }
    var keyHintIsWithinBoundsForTesting: Bool {
        layoutSubtreeIfNeeded()
        return bounds.contains(convert(keyHintLabel.bounds, from: keyHintLabel))
    }
    var widthFitsKeyHintForTesting: Bool {
        layoutSubtreeIfNeeded()
        let preferredWidth = max(360, ceil(keyHintLabel.intrinsicContentSize.width))
        return bounds.width + 0.5 >= keyHintLabel.intrinsicContentSize.width + 32
            && bounds.width <= preferredWidth + 33
    }
    var listRequiresScrollingForTesting: Bool {
        layoutSubtreeIfNeeded()
        return rowStack.frame.height > scrollView.documentVisibleRect.height + 0.5
    }
    func pointerEnterRowForTesting(at index: Int) { rows[index].pointerEnterForTesting() }
    func pointerActivateRowForTesting(at index: Int) { rows[index].pointerActivateForTesting() }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) { return false }
        switch event.keyCode {
        case 53: onCancel?(); return true
        case 36, 76: commitSelection(); return true
        case 51:
            if !query.isEmpty { query.removeLast(); applyFilter(resetSelection: true) }
            return true
        case 125: moveSelection(by: 1); return true // down arrow = Ctrl+j
        case 126: moveSelection(by: -1); return true // up arrow = Ctrl+k
        case 123, 124: return true // left/right arrows: swallow (no tofu in the query)
        default: break
        }
        if event.modifierFlags.contains(.control), let characters = event.charactersIgnoringModifiers?.lowercased() {
            switch characters {
            case "j": moveSelection(by: 1); return true
            case "k": moveSelection(by: -1); return true
            case "c": onClear?(); return true
            default: return false
            }
        }
        guard let typed = event.characters, typed.count == 1, let scalar = typed.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value != 0x7F, !(0xF700...0xF8FF).contains(scalar.value) else { return false }
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
        updateListHeight()
        scrollSelectedRowToVisible()
    }

    private func moveSelection(by offset: Int) {
        selectedIndex = min(max(selectedIndex + offset, 0), filtered.count)
        renderRows()
        scrollSelectedRowToVisible()
    }

    private func selectRow(at index: Int, commit: Bool) {
        guard (0...filtered.count).contains(index) else { return }
        selectedIndex = index
        renderRows()
        scrollSelectedRowToVisible()
        if commit { commitSelection() }
    }

    private func commitSelection() {
        if selectedIndex == 0 {
            onBrowse?()
        } else if filtered.indices.contains(selectedIndex - 1) {
            onOpenRecent?(filtered[selectedIndex - 1].entry.absolutePath)
        }
    }

    private func updateListHeight() {
        rowStack.layoutSubtreeIfNeeded()
        listHeightConstraint.constant = rowStack.fittingSize.height
    }

    private func scrollSelectedRowToVisible() {
        layoutSubtreeIfNeeded()
        rows[selectedIndex].scrollToVisible(rows[selectedIndex].bounds)
    }

    private static func isPDFPath(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
    }

    private func renderKeyHint() {
        guard let theme else {
            keyHintLabel.stringValue = Self.keyHintText
            return
        }
        let attributed = NSMutableAttributedString(
            string: Self.keyHintText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: theme[.mutedText],
            ]
        )
        let fullText = Self.keyHintText as NSString
        for label in Self.shortcutLabels {
            attributed.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: theme[.accent],
            ], range: fullText.range(of: label))
        }
        keyHintLabel.attributedStringValue = attributed
    }
    private static func displayDirectory(for path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }
    private func renderRows() {
        let placeholder = query.isEmpty
        queryField.stringValue = placeholder ? "Type to search…" : query
        queryField.textColor = theme.map { placeholder ? $0[.mutedText] : $0[.foreground] }
        setAccessibilityValue(query)
        for (index, row) in rows.enumerated() {
            if index == 0 {
                row.isHidden = false
                row.configure(title: "Browse…", path: nil, matchedIndices: [], selected: selectedIndex == 0, theme: theme)
            } else if filtered.indices.contains(index - 1) {
                let match = filtered[index - 1]
                row.isHidden = false
                row.configure(title: URL(fileURLWithPath: match.entry.absolutePath).lastPathComponent, path: Self.displayDirectory(for: match.entry.absolutePath), matchedIndices: match.matchedIndices, selected: selectedIndex == index, theme: theme)
            } else {
                row.isHidden = true
            }
        }
    }
}

@MainActor
private final class RecentFilesOpenRowView: PointerActionView {
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
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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

    func configure(title: String, path: String?, matchedIndices: [Int], selected: Bool, theme: AppKitTheme?) {
        pathLabel.stringValue = path ?? ""
        pathLabel.isHidden = path == nil
        guard let theme else { titleLabel.stringValue = title; return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .regular),
            .foregroundColor: selected ? theme[.accent] : theme[.foreground],
        ]
        let attributedTitle = NSMutableAttributedString(string: title, attributes: attributes)
        for index in matchedIndices {
            guard let start = title.index(title.startIndex, offsetBy: index, limitedBy: title.endIndex), start < title.endIndex else { continue }
            attributedTitle.addAttributes([
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: theme[.accent],
            ], range: NSRange(start..<title.index(after: start), in: title))
        }
        titleLabel.attributedStringValue = attributedTitle
        pathLabel.textColor = theme[.mutedText]
        layer?.backgroundColor = (selected ? theme.separator : NSColor.clear).cgColor
    }
}
