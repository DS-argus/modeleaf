import AppKit
import PDFReaderCore

@MainActor
private final class TOCWidgetTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
}

private struct TOCWidgetReducer {
    enum State: Equatable {
        case tracking(ReaderOutlineRowID?, UInt64)
        case pendingActivation(ReaderOutlineRowID, UInt64, ReaderOutlineRowID?, UInt64, Bool)
        case exact(ReaderOutlineRowID, UInt64)
    }

    static func render(_ state: State, snapshot: ReaderOutlineSnapshot) -> State {
        let stateRevision: UInt64
        switch state {
        case let .tracking(_, revision), let .exact(_, revision): stateRevision = revision
        case let .pendingActivation(_, _, _, baseline, _): stateRevision = baseline
        }
        guard snapshot.successfulUserMovementRevision >= stateRevision else { return state }
        switch state {
        case let .tracking(_, revision):
            return .tracking(snapshot.currentRowID, max(revision, snapshot.successfulUserMovementRevision))
        case let .pendingActivation(id, generation, priorID, baseline, priorWasExact):
            guard snapshot.successfulUserMovementRevision == baseline else {
                return .tracking(snapshot.currentRowID, snapshot.successfulUserMovementRevision)
            }
            return .pendingActivation(id, generation, priorID, baseline, priorWasExact)
        case let .exact(_, revision) where snapshot.successfulUserMovementRevision > revision:
            return .tracking(snapshot.currentRowID, snapshot.successfulUserMovementRevision)
        case .exact:
            return state
        }
    }
}

@MainActor
final class TOCWidgetView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Metrics {
        static let maximumWidth: CGFloat = 300
        static let rowHeight: CGFloat = 20
        static let footerHeight: CGFloat = 24
    }

    private let scrollView = NSScrollView()
    private let tableView = TOCWidgetTableView()
    private let emptyLabel = NSTextField(labelWithString: "No table of contents")
    private let footerSeparator = NSView()
    private let hintLabel = NSTextField(labelWithString: "J / K  Scroll    #  Jump    Esc / t  Close")
    private var idleHint = "J / K  Scroll    #  Jump    Esc / t  Close"
    private var idleShortcutLabels = ["J / K", "#", "Esc / t"]
    private var closeHint = "Esc / t"
    private var snapshot = ReaderOutlineSnapshot.empty
    private var reducer = TOCWidgetReducer.State.tracking(nil, 0)
    private var theme: AppKitTheme?
    private var digitBuffer = ""
    private var digitGeneration: UInt64 = 0
    private var digitCommit: DispatchWorkItem?
    private var isProgrammaticScroll = false
    private var manuallyScrolled = false
    var onActivate: ((ReaderOutlineRowID) -> NavigationTransactionOutcome)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityIdentifier("tocWidget")
        setAccessibilityRole(.group)
        setAccessibilityLabel("Table of contents")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tocRow"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Metrics.rowHeight
        tableView.intercellSpacing = .zero
        tableView.dataSource = self
        tableView.delegate = self
        tableView.focusRingType = .none
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsDidChange), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.setAccessibilityIdentifier("tocWidget.empty")
        footerSeparator.wantsLayer = true
        hintLabel.alignment = .left
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setAccessibilityIdentifier("tocWidget.hint")
        for view in [scrollView, emptyLabel, footerSeparator, hintLabel] { view.prepareForAutoLayout(); addSubview(view) }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor),
            footerSeparator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            footerSeparator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            footerSeparator.bottomAnchor.constraint(equalTo: hintLabel.topAnchor),
            footerSeparator.heightAnchor.constraint(equalToConstant: 1 / (NSScreen.main?.backingScaleFactor ?? 2)),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            hintLabel.heightAnchor.constraint(equalToConstant: Metrics.footerHeight),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }

    override var intrinsicContentSize: NSSize {
        let rowCount = snapshot.rows.isEmpty ? 3 : max(1, snapshot.rows.count)
        return NSSize(width: Metrics.maximumWidth, height: CGFloat(rowCount) * Metrics.rowHeight + Metrics.footerHeight)
    }

    var footerHeight: CGFloat { Metrics.footerHeight }
    var rowHeight: CGFloat { Metrics.rowHeight }

    func setKeyHints(scrollDown: String, scrollUp: String, toggle: String) {
        let scrollBindings = [scrollDown, scrollUp].filter { !$0.isEmpty }.joined(separator: " / ")
        closeHint = ["Esc", toggle].filter { !$0.isEmpty }.joined(separator: " / ")
        let scrollText = scrollBindings.isEmpty ? "" : "\(scrollBindings)  Scroll    "
        idleHint = "\(scrollText)#  Jump    \(closeHint)  Close"
        idleShortcutLabels = ([scrollBindings].filter { !$0.isEmpty }) + ["#", closeHint]
        updateHint()
    }


    func apply(theme: AppKitTheme) {
        self.theme = theme
        layer?.backgroundColor = theme[.activeTab].withAlphaComponent(0.9).cgColor
        layer?.borderColor = theme.separator.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.25).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 4
        layer?.shadowOffset = NSSize(width: 0, height: -1)
        emptyLabel.textColor = theme[.mutedText]
        footerSeparator.layer?.backgroundColor = theme.separator.withAlphaComponent(0.75).cgColor
        updateHint()
        tableView.reloadData()
    }

    func setPaneActive(_ active: Bool) {
        alphaValue = active ? 1 : 0.9
        guard !active else { return }
        cancelPendingInput()
        reducer = .tracking(snapshot.currentRowID, snapshot.successfulUserMovementRevision)
        tableView.reloadData()
    }

    func toggle(snapshot: ReaderOutlineSnapshot, onActivate: @escaping (ReaderOutlineRowID) -> NavigationTransactionOutcome) {
        self.onActivate = onActivate
        if isHidden {
            isHidden = false
            render(snapshot, opening: true)
        } else {
            dismiss()
        }
    }

    func render(_ snapshot: ReaderOutlineSnapshot, opening: Bool = false) {
        let priorRevision = self.snapshot.successfulUserMovementRevision
        let priorCurrentRowID = self.snapshot.currentRowID
        self.snapshot = snapshot
        reducer = TOCWidgetReducer.render(reducer, snapshot: snapshot)
        tableView.reloadData()
        emptyLabel.isHidden = !snapshot.rows.isEmpty
        scrollView.isHidden = snapshot.rows.isEmpty
        invalidateIntrinsicContentSize()
        if opening {
            manuallyScrolled = false
            if snapshot.currentRowID == nil { scroll(to: .zero) } else { centerTrackedRow() }
        } else if snapshot.successfulUserMovementRevision > priorRevision || snapshot.currentRowID != priorCurrentRowID {
            manuallyScrolled = false
            minimallyRevealTrackedRow()
        } else if !manuallyScrolled {
            minimallyRevealTrackedRow()
        }
    }

    func dismiss() {
        cancelPendingInput()
        onActivate = nil
        isHidden = true
        scroll(to: .zero)
        manuallyScrolled = false
        reducer = .tracking(nil, snapshot.successfulUserMovementRevision)
    }

    func cancelPendingInput() {
        digitGeneration &+= 1
        digitCommit?.cancel()
        digitCommit = nil
        digitBuffer = ""
        updateHint()
    }

    func scrollByRows(_ direction: Int) {
        guard !isHidden, !snapshot.rows.isEmpty else { return }
        let current = scrollView.contentView.bounds.origin.y
        let maximum = max(0, tableView.bounds.height - scrollView.contentView.bounds.height)
        scroll(to: NSPoint(x: 0, y: min(maximum, max(0, current + CGFloat(direction.signum()) * Metrics.rowHeight))))
        manuallyScrolled = true
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard !isHidden else { return false }
        let prohibited: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard event.modifierFlags.intersection(prohibited).isEmpty else { return false }
        if event.keyCode == 53 {
            dismiss()
            return true
        }
        guard !snapshot.rows.isEmpty else { return false }
        switch event.keyCode {
        case 51:
            guard !digitBuffer.isEmpty else { return false }
            digitBuffer.removeLast()
            updateHint()
            if digitBuffer.isEmpty { cancelPendingInput() } else { scheduleDigitCommit() }
            return true
        default:
            guard let digit = event.charactersIgnoringModifiers?.first, digit.isNumber else { return false }
            digitBuffer.append(digit)
            updateHint()
            scheduleDigitCommit()
            return true
        }
    }

    private func updateHint() {
        let text = digitBuffer.isEmpty ? idleHint : "\(digitBuffer)  Jump    \(closeHint)  Close"
        let shortcuts = digitBuffer.isEmpty ? idleShortcutLabels : [digitBuffer, closeHint]
        let mutedText = theme?[.mutedText] ?? .secondaryLabelColor
        let accent = theme?[.accent] ?? .controlAccentColor
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: mutedText]
        )
        let fullText = text as NSString
        for shortcut in shortcuts {
            let range = fullText.range(of: shortcut)
            guard range.location != NSNotFound else { continue }
            attributed.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: accent,
            ], range: range)
        }
        hintLabel.attributedStringValue = attributed
        hintLabel.setAccessibilityValue(text)
        setAccessibilityValue(digitBuffer.isEmpty ? nil : text)
    }

    @objc private func boundsDidChange() {
        if !isProgrammaticScroll { manuallyScrolled = true }
    }

    private func scheduleDigitCommit() {
        digitGeneration &+= 1
        let generation = digitGeneration
        digitCommit?.cancel()
        let commit = DispatchWorkItem { [weak self] in self?.commitDigits(generation: generation) }
        digitCommit = commit
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400), execute: commit)
    }

    private func commitDigits(generation: UInt64) {
        guard generation == digitGeneration else { return }
        let digits = digitBuffer
        digitBuffer = ""
        digitCommit = nil
        updateHint()
        guard let selector = Int(digits),
              let id = snapshot.rows.first(where: { $0.selector == selector && $0.isEnabled })?.id else { return }
        let prior = displayedRowID
        let priorWasExact = isExactState
        let baseline = snapshot.successfulUserMovementRevision
        reducer = .pendingActivation(id, generation, prior, baseline, priorWasExact)
        let outcome = onActivate?(id) ?? .preflightRejected
        completeActivation(id: id, generation: generation, outcome: outcome)
    }

    private var isExactState: Bool {
        if case .exact = reducer { return true }
        return false
    }

    private func completeActivation(id: ReaderOutlineRowID, generation: UInt64, outcome: NavigationTransactionOutcome) {
        guard case let .pendingActivation(pendingID, pendingGeneration, priorID, baseline, priorWasExact) = reducer,
              pendingID == id,
              pendingGeneration == generation,
              baseline == snapshot.successfulUserMovementRevision else { return }
        if outcome == .verifiedLanding || outcome == .noOp {
            reducer = .exact(id, baseline)
        } else if priorWasExact, let priorID {
            reducer = .exact(priorID, baseline)
        } else {
            reducer = .tracking(priorID, baseline)
        }
        tableView.reloadData()
        if outcome == .verifiedLanding || outcome == .noOp {
            minimallyRevealTrackedRow()
        }
    }

    private var displayedRowID: ReaderOutlineRowID? {
        switch reducer {
        case let .tracking(id, _): return id
        case let .pendingActivation(_, _, priorID, _, _): return priorID
        case let .exact(id, _): return id
        }
    }

    private func rowIndex(for id: ReaderOutlineRowID?) -> Int? {
        guard let id, let index = snapshot.rows.firstIndex(where: { $0.id == id }) else { return nil }
        return index
    }

    private func centerTrackedRow() {
        guard let row = rowIndex(for: snapshot.currentRowID) else { return }
        let rect = tableView.rect(ofRow: row)
        scroll(to: NSPoint(x: 0, y: max(0, rect.midY - scrollView.contentView.bounds.height / 2)))
    }

    private func minimallyRevealTrackedRow() {
        guard let row = rowIndex(for: displayedRowID) else { return }
        let rect = tableView.rect(ofRow: row)
        let visible = scrollView.contentView.bounds
        if rect.minY < visible.minY { scroll(to: NSPoint(x: 0, y: rect.minY)) }
        else if rect.maxY > visible.maxY { scroll(to: NSPoint(x: 0, y: max(0, rect.maxY - visible.height))) }
    }

    private func scroll(to point: NSPoint) {
        isProgrammaticScroll = true
        scrollView.contentView.scroll(to: point)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isProgrammaticScroll = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { snapshot.rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard snapshot.rows.indices.contains(row) else { return nil }
        let item = snapshot.rows[row]
        let selected = item.id == displayedRowID
        let cell = TOCWidgetRowView(item: item, selected: selected, theme: theme)
        cell.onClick = { [weak self] in self?.activate(item) }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    private func activate(_ item: ReaderOutlineRowSnapshot) {
        guard item.isEnabled else { return }
        cancelPendingInput()
        let generation = digitGeneration
        let prior = displayedRowID
        let priorWasExact = isExactState
        let baseline = snapshot.successfulUserMovementRevision
        reducer = .pendingActivation(item.id, generation, prior, baseline, priorWasExact)
        let outcome = onActivate?(item.id) ?? .preflightRejected
        completeActivation(id: item.id, generation: generation, outcome: outcome)
    }
}

@MainActor
private final class TOCWidgetRowView: NSView {
    private let marker = NSView()
    private let selector = NSTextField(labelWithString: "")
    private let separator = NSView()
    private let title = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    init(item: ReaderOutlineRowSnapshot, selected: Bool, theme: AppKitTheme?) {
        super.init(frame: .zero)
        wantsLayer = true
        let accent = theme?[.accent] ?? .controlAccentColor
        let foreground = theme?[.foreground] ?? .labelColor
        let muted = theme?[.mutedText] ?? .secondaryLabelColor
        let liftsSecondaryContrast = theme?.id == .dracula || theme?.id == .solarizedDark
        let secondaryForeground = liftsSecondaryContrast ? foreground : foreground.withAlphaComponent(0.82)
        let secondaryTitle = liftsSecondaryContrast ? foreground : foreground.withAlphaComponent(0.78)

        marker.wantsLayer = true
        marker.layer?.backgroundColor = accent.cgColor
        marker.isHidden = !selected
        selector.stringValue = item.selector.map(String.init) ?? ""
        selector.alignment = .right
        selector.font = .monospacedSystemFont(ofSize: 10, weight: selected ? .semibold : .regular)
        selector.textColor = item.isEnabled ? (selected ? accent : secondaryForeground) : muted.withAlphaComponent(0.55)
        separator.wantsLayer = true
        separator.layer?.backgroundColor = foreground.withAlphaComponent(0.38).cgColor
        title.stringValue = item.title
        title.alignment = .left
        let titleWeight: NSFont.Weight = selected || item.depth == 0 ? .semibold : .regular
        title.font = .systemFont(ofSize: 11, weight: titleWeight)
        if selected { title.textColor = foreground }
        else if !item.isEnabled { title.textColor = muted.withAlphaComponent(0.55) }
        else { title.textColor = item.depth == 0 ? foreground : secondaryTitle }
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = item.title

        setAccessibilityElement(true)
        setAccessibilityRole(item.isEnabled ? .button : .group)
        setAccessibilityLabel(item.selector.map { "Section \($0), \(item.title)" } ?? item.title)
        setAccessibilityValue(selected ? "Selected" : "")
        setAccessibilityIdentifier("tocWidget.row.\(item.id.accessibilityIdentifier)")
        setAccessibilityEnabled(item.isEnabled)
        selector.setAccessibilityIdentifier("tocWidget.row.\(item.id.accessibilityIdentifier).selector")
        separator.setAccessibilityIdentifier("tocWidget.row.\(item.id.accessibilityIdentifier).separator")
        title.setAccessibilityIdentifier("tocWidget.row.\(item.id.accessibilityIdentifier).title")

        for view in [marker, selector, separator, title] {
            view.prepareForAutoLayout()
            addSubview(view)
        }
        let indent = CGFloat(item.depth) * 6
        NSLayoutConstraint.activate([
            marker.leadingAnchor.constraint(equalTo: leadingAnchor),
            marker.topAnchor.constraint(equalTo: topAnchor),
            marker.bottomAnchor.constraint(equalTo: bottomAnchor),
            marker.widthAnchor.constraint(equalToConstant: 2),
            selector.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            selector.centerYAnchor.constraint(equalTo: centerYAnchor),
            selector.widthAnchor.constraint(equalToConstant: 22),
            separator.leadingAnchor.constraint(equalTo: selector.trailingAnchor, constant: 4),
            separator.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            separator.widthAnchor.constraint(equalToConstant: 1),
            title.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: 4 + indent),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) { guard isAccessibilityEnabled() else { return }; onClick?() }
}
