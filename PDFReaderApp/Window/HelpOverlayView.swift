import AppKit
import PDFReaderCore

struct HelpOverlaySection {
    let title: String
    let entries: [(keyText: String, commandTitle: String)]
}

@MainActor
final class HelpOverlayView: NSView {
    private enum Metrics {
        static let preferredWidth: CGFloat = 840
        static let maximumListHeight: CGFloat = 520
        static let minimumListHeight: CGFloat = 120
    }

    var onDismiss: (() -> Void)?

    private let grid = NSStackView()
    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()
    private var listHeightConstraint: NSLayoutConstraint!
    private var sections: [HelpOverlaySection] = []
    private var cards: [HelpSectionCardView] = []
    private var columnCount = 0
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
        setAccessibilityLabel("Keyboard help")
        setAccessibilityIdentifier("helpOverlay")

        grid.orientation = .horizontal
        grid.alignment = .top
        grid.distribution = .fillEqually
        grid.spacing = 12
        grid.prepareForAutoLayout()

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = grid
        scrollView.prepareForAutoLayout()
        listHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: Metrics.minimumListHeight)
        listHeightConstraint.isActive = true

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.addArrangedSubview(scrollView)
        contentStack.prepareForAutoLayout()
        addSubview(contentStack)
        let preferredWidth = contentStack.widthAnchor.constraint(equalToConstant: Metrics.preferredWidth)
        preferredWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            preferredWidth,
            scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            grid.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
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
        cards.forEach { $0.apply(theme: theme) }
    }

    func present(sections: [HelpOverlaySection]) {
        self.sections = sections
        cards = sections.map { HelpSectionCardView(section: $0) }
        cards.forEach { if let theme { $0.apply(theme: theme) } }
        columnCount = 0
        isHidden = false
        rebuildGridIfNeeded()
        updateListHeight()
    }

    func dismiss() {
        isHidden = true
        sections = []
        cards = []
        rebuildGrid(columns: 1)
    }

    var visibleSectionsForTesting: [String] { sections.map(\.title) }
    var visibleEntriesForTesting: [(String, String)] {
        sections.flatMap { $0.entries.map { ($0.keyText, $0.commandTitle) } }
    }
    var listRequiresScrollingForTesting: Bool {
        layoutSubtreeIfNeeded()
        return grid.fittingSize.height > scrollView.documentVisibleRect.height + 0.5
    }
    var isWithinBoundsForTesting: Bool {
        guard let superview else { return false }
        return superview.bounds.contains(superview.convert(bounds, from: self))
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 || event.characters == "?" {
            onDismiss?()
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        _ = handleKeyDown(event)
    }

    override func layout() {
        super.layout()
        guard !isHidden else { return }
        rebuildGridIfNeeded()
        updateListHeight()
    }

    private func rebuildGridIfNeeded() {
        let availableWidth = max(bounds.width, superview?.bounds.width ?? 0)
        let desiredColumns: Int
        switch availableWidth {
        case 0..<520: desiredColumns = 1
        case 520..<760: desiredColumns = 2
        default: desiredColumns = 3
        }
        guard desiredColumns != columnCount else { return }
        rebuildGrid(columns: desiredColumns)
    }

    private func rebuildGrid(columns: Int) {
        for view in grid.arrangedSubviews {
            grid.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        columnCount = columns
        guard !cards.isEmpty else { return }
        let stacks = (0..<columns).map { _ -> NSStackView in
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 12
            stack.prepareForAutoLayout()
            grid.addArrangedSubview(stack)
            return stack
        }
        for (index, card) in cards.enumerated() {
            let stack = stacks[index % stacks.count]
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func updateListHeight() {
        guard !isHidden else { return }
        grid.layoutSubtreeIfNeeded()
        let availableHeight = max(
            Metrics.minimumListHeight,
            (superview?.bounds.height ?? Metrics.maximumListHeight) - 64
        )
        listHeightConstraint.constant = min(
            grid.fittingSize.height,
            min(Metrics.maximumListHeight, availableHeight)
        )
    }
}

@MainActor
private final class HelpSectionCardView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let entriesStack = NSStackView()
    private let section: HelpOverlaySection

    init(section: HelpOverlaySection) {
        self.section = section
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        titleLabel.stringValue = section.title
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        entriesStack.orientation = .vertical
        entriesStack.alignment = .leading
        entriesStack.spacing = 2
        for entry in section.entries {
            entriesStack.addArrangedSubview(HelpEntryRowView(keyText: entry.keyText, commandTitle: entry.commandTitle))
        }
        let stack = NSStackView(views: [titleLabel, entriesStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.prepareForAutoLayout()
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func apply(theme: AppKitTheme) {
        titleLabel.textColor = theme[.accent]
        layer?.backgroundColor = theme[.background].withAlphaComponent(0.35).cgColor
        for case let row as HelpEntryRowView in entriesStack.arrangedSubviews {
            row.apply(theme: theme)
        }
    }
}

@MainActor
private final class HelpEntryRowView: NSView {
    private let keyLabel: NSTextField
    private let commandLabel: NSTextField

    init(keyText: String, commandTitle: String) {
        keyLabel = NSTextField(labelWithString: keyText)
        commandLabel = NSTextField(labelWithString: commandTitle)
        super.init(frame: .zero)
        keyLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        commandLabel.font = .systemFont(ofSize: 10)
        keyLabel.lineBreakMode = .byTruncatingTail
        commandLabel.lineBreakMode = .byTruncatingTail
        keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        commandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [keyLabel, commandLabel])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 7
        stack.prepareForAutoLayout()
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func apply(theme: AppKitTheme) {
        keyLabel.textColor = theme[.mutedText]
        commandLabel.textColor = theme[.foreground]
    }
}
