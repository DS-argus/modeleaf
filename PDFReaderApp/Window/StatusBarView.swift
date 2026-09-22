import AppKit

/// The status bar deliberately keeps its state as data and performs the final
/// layout in one measured pass.  This avoids asking Auto Layout to choose
/// which status item to sacrifice when a window gets narrow.
enum StatusTone: Equatable {
    case normal
    case error
}

struct StatusBarPresentation: Equatable {
    var page: String
    var zoom: String
    var mode: String = ""
    var isSearchMode: Bool = false
    var isExperimentalMode: Bool = false
    var transientNotice: String = ""
    var pendingPrefix: String
    var documentPath: String = ""
    var detail: String
    var expandedDetail: String?
    var tone: StatusTone

    static let empty = StatusBarPresentation(
        page: ReaderStatusSnapshot.empty.page,
        zoom: ReaderStatusSnapshot.empty.zoom,
        pendingPrefix: "",
        detail: ReaderStatusSnapshot.empty.detail,
        expandedDetail: nil,
        tone: .normal
    )
}

@MainActor
final class StatusBarView: NSView {
    private let helpButton = NSButton(title: "? help", target: nil, action: nil)
    private let pageLabel = StatusBarView.makeLabel(identifier: "status.page", monospaced: true)
    private let zoomLabel = StatusBarView.makeLabel(identifier: "status.zoom", monospaced: true)
    private let prefixLabel = StatusBarView.makeLabel(identifier: "status.prefix", monospaced: true)
    private let detailLabel = StatusBarView.makeLabel(identifier: "status.diagnostic", monospaced: false)
    private let fitPagePill = StatusModePillView(identifier: "status.mode", accessibilityLabel: "Fit mode")
    private let pathLabel = StatusBarView.makeLabel(identifier: "status.path", monospaced: false)
    private let copiedLabel = StatusBarView.makeLabel(identifier: "status.copied", monospaced: true)
    private let searchModePill = StatusModePillView(identifier: "status.searchMode", accessibilityLabel: "Search mode")
    private let experimentalPill = StatusModePillView(identifier: "status.experimentalMode", accessibilityLabel: "Experimental citation preview enabled")
    private let noticePill = StatusModePillView(identifier: "status.notice", accessibilityLabel: "Temporary status")
    private let versionLabel = StatusBarView.makeLabel(identifier: "status.version", monospaced: true)
    private let updateButton = StatusUpdateButton(title: "", target: nil, action: nil)
    private let errorButton = NSButton(title: "Error", target: nil, action: nil)
    private let separator = NSView()
    private var theme: AppKitTheme?
    private static let noticeAccent = NSColor.systemOrange
    private(set) var presentation = StatusBarPresentation.empty

    private let contentInset: CGFloat = 12
    private let itemSpacing: CGFloat = 8
    private let minimumPathWidth: CGFloat = 48
    private var diagnosticPopover: NSPopover?
    private var diagnosticPopoverText: String?

    /// Invoked when the user clicks the keyboard help hint.
    var onHelpTap: (() -> Void)?
    /// Non-nil while an update banner is shown (the plain, unstyled text).
    private(set) var updateText: String?
    /// Invoked when the user clicks the update banner.
    var onUpdateClicked: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityIdentifier("statusBar")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Reader status and keyboard help")

        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = true
        addSubview(separator)

        configureHelpButton()
        configureUpdateButton()
        configureErrorButton()

        detailLabel.alignment = .left
        detailLabel.lineBreakMode = .byTruncatingTail
        pathLabel.alignment = .left
        pathLabel.lineBreakMode = .byTruncatingMiddle
        copiedLabel.alignment = .left
        copiedLabel.lineBreakMode = .byTruncatingTail
        copiedLabel.setAccessibilityLabel("Copied")
        copiedLabel.setAccessibilityValue("copied!")
        copiedLabel.textColor = .systemGreen

        versionLabel.stringValue = Self.displayVersion
        versionLabel.setAccessibilityLabel("Modeleaf version")
        versionLabel.lineBreakMode = .byTruncatingTail
        versionLabel.setAccessibilityValue(Self.displayVersion)

        for view in [
            helpButton, pageLabel, zoomLabel, prefixLabel, detailLabel,
            fitPagePill, pathLabel, copiedLabel, searchModePill, experimentalPill, noticePill,
            versionLabel, updateButton, errorButton,
        ] {
            // This view owns the horizontal policy.  None of these subviews
            // should be compressed by an equal-priority constraint system.
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        render(.empty)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func configureHelpButton() {
        helpButton.isBordered = false
        helpButton.bezelStyle = .inline
        helpButton.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        helpButton.target = self
        helpButton.action = #selector(helpTapped)
        helpButton.setButtonType(.momentaryChange)
        helpButton.setAccessibilityIdentifier("status.help")
        helpButton.setAccessibilityLabel("Keyboard help")
        helpButton.setAccessibilityValue("? help")
    }

    private func configureUpdateButton() {
        updateButton.isBordered = false
        updateButton.bezelStyle = .inline
        updateButton.font = .systemFont(ofSize: 11, weight: .semibold)
        updateButton.target = self
        updateButton.action = #selector(updateClicked)
        updateButton.isHidden = true
        updateButton.setButtonType(.momentaryChange)
        updateButton.setAccessibilityIdentifier("status.update")
        updateButton.setAccessibilityLabel("View release details")
        updateButton.toolTip = "View release details"
        updateButton.onHoverChange = { [weak updateButton] hovering in
            updateButton?.layer?.backgroundColor = hovering
                ? (updateButton?.contentTintColor ?? .controlAccentColor).withAlphaComponent(0.12).cgColor
                : NSColor.clear.cgColor
        }
    }

    private func configureErrorButton() {
        errorButton.isBordered = false
        errorButton.bezelStyle = .inline
        errorButton.font = .systemFont(ofSize: 11, weight: .semibold)
        errorButton.target = self
        errorButton.action = #selector(diagnosticTapped)
        errorButton.isHidden = true
        errorButton.setButtonType(.momentaryChange)
        errorButton.setAccessibilityIdentifier("status.error")
        errorButton.setAccessibilityLabel("Error details")
        errorButton.toolTip = "Show full error details"
    }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        layer?.backgroundColor = theme[.statusline].cgColor
        separator.layer?.backgroundColor = theme.separator.cgColor
        helpButton.contentTintColor = theme[.accent]
        pageLabel.textColor = theme[.mutedText]
        zoomLabel.textColor = theme[.mutedText]
        prefixLabel.textColor = theme[.accent]
        detailLabel.textColor = presentation.tone == .error ? theme[.error] : theme[.mutedText]
        pathLabel.textColor = theme[.mutedText]
        copiedLabel.textColor = .systemGreen
        restyleUpdateButton()
        updateButton.contentTintColor = theme[.accent]
        errorButton.contentTintColor = theme[.error]
        fitPagePill.render(presentation.mode, accent: theme[.accent])
        searchModePill.render(presentation.isSearchMode ? "SEARCH" : "", accent: theme[.accent])
        experimentalPill.render(presentation.isExperimentalMode ? "CITATION PREVIEW" : "", accent: .systemRed, filled: false)
        noticePill.render(Self.noticeText(from: presentation.transientNotice), accent: Self.noticeAccent)
        versionLabel.textColor = theme[.mutedText]
        needsLayout = true
    }

    /// Shows the update banner (accent, clickable) or clears it when `text` is nil.
    func presentUpdate(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        updateText = (trimmed?.isEmpty == false) ? trimmed : nil
        updateButton.isHidden = updateText == nil
        updateButton.toolTip = updateText.map { _ in "View release details" }
        restyleUpdateButton()
        needsLayout = true
    }

    private func restyleUpdateButton() {
        guard let updateText else {
            updateButton.attributedTitle = NSAttributedString(string: "")
            updateButton.setAccessibilityValue(nil)
            return
        }
        let title = displayUpdateText(for: updateText)
        let accent = theme?[.accent] ?? .controlAccentColor
        let attributed = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: accent,
            ]
        )
        let commandRange = (title as NSString).range(of: "modeleaf update")
        if commandRange.location != NSNotFound {
            attributed.addAttribute(
                .font,
                value: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                range: commandRange
            )
        }
        updateButton.attributedTitle = attributed
        updateButton.setAccessibilityValue(updateText)
    }

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: 0, y: max(0, bounds.height - 1), width: bounds.width, height: 1)
        if updateText != nil { restyleUpdateButton() }
        layoutResponsiveStatusBar()
    }

    private func displayUpdateText(for text: String) -> String {
        guard bounds.width > 0, bounds.width < 620,
              let availableRange = text.range(of: " available") else { return text }
        let version = String(text[..<availableRange.lowerBound])
        guard let open = text.lastIndex(of: "["), let close = text.lastIndex(of: "]"), open < close else {
            return version
        }
        let shortcut = String(text[text.index(after: open)..<close])
        if text.contains("modeleaf update") {
            return "\(version) → modeleaf update [\(shortcut)]"
        }
        return "\(version) [\(shortcut)]"
    }

    @objc private func helpTapped() {
        onHelpTap?()
    }

    @objc private func updateClicked() {
        onUpdateClicked?()
    }

    @objc private func diagnosticTapped() {
        let text = fullDiagnosticText
        diagnosticPopoverText = text
        guard errorButton.window != nil, !text.isEmpty else { return }

        let width = min(520, max(280, bounds.width - 24))
        let font = NSFont.systemFont(ofSize: 12)
        let textBounds = (text as NSString).boundingRect(
            with: NSSize(width: width - 34, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let height = min(360, max(64, ceil(textBounds.height) + 24))
        let host = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        host.hasVerticalScroller = true
        host.autohidesScrollers = true
        host.drawsBackground = false
        let document = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        document.font = font
        document.string = text
        document.isEditable = false
        document.isSelectable = true
        document.drawsBackground = false
        document.textColor = theme?[.foreground] ?? .labelColor
        document.textContainerInset = NSSize(width: 12, height: 12)
        document.isVerticallyResizable = true
        document.isHorizontallyResizable = false
        document.autoresizingMask = [.width]
        document.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        document.textContainer?.widthTracksTextView = true
        document.textContainer?.containerSize = NSSize(width: width - 24, height: CGFloat.greatestFiniteMagnitude)
        document.setAccessibilityIdentifier("status.errorDetails")
        document.setAccessibilityLabel("Full error details")
        host.documentView = document
        if let container = document.textContainer, let manager = document.layoutManager {
            manager.ensureLayout(for: container)
            document.setFrameSize(NSSize(width: host.contentSize.width, height: max(height, ceil(manager.usedRect(for: container).height) + 24)))
        }

        let controller = NSViewController()
        controller.view = host
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.contentSize = host.bounds.size
        diagnosticPopover?.close()
        diagnosticPopover = popover
        popover.show(relativeTo: errorButton.bounds, of: errorButton, preferredEdge: .maxY)
    }

    func performHelpTapForTesting() { helpButton.performClick(nil) }
    func performUpdateClickForTesting() { updateButton.performClick(nil) }
    func performDiagnosticClickForTesting() { errorButton.performClick(nil) }
    var updateToolTipForTesting: String? { updateButton.toolTip }
    var updateIsTruncatedForTesting: Bool {
        !updateButton.isHidden && updateButton.frame.width + 0.5 < updateButton.fittingSize.width
    }
    var updateFrameForTesting: NSRect { updateButton.frame }
    var copiedFrameForTesting: NSRect { copiedLabel.frame }
    var errorButtonForTesting: NSButton { errorButton }
    var errorPopoverTextForTesting: String? { diagnosticPopoverText }
    var diagnosticContentForTesting: NSScrollView? { diagnosticPopover?.contentViewController?.view as? NSScrollView }
    var visibleStatusIdentifiersForTesting: Set<String> {
        [
            helpButton, pageLabel, zoomLabel, prefixLabel, detailLabel,
            fitPagePill, pathLabel, copiedLabel, searchModePill, experimentalPill, noticePill,
            versionLabel, updateButton, errorButton,
        ].reduce(into: Set<String>()) { result, view in
            guard !view.isHidden else { return }
            let identifier = view.accessibilityIdentifier()
            if !identifier.isEmpty { result.insert(identifier) }
            if let pill = view as? StatusModePillView, !pill.isHidden {
                let nested = pill.contentAccessibilityIdentifier
                if !nested.isEmpty { result.insert(nested) }
            }
        }
    }

    func render(_ presentation: StatusBarPresentation) {
        self.presentation = presentation
        pageLabel.stringValue = presentation.page
        zoomLabel.stringValue = presentation.zoom
        let accent = theme?[.accent]
        fitPagePill.render(presentation.mode, accent: accent)
        searchModePill.render(presentation.isSearchMode ? "SEARCH" : "", accent: accent)
        experimentalPill.render(presentation.isExperimentalMode ? "CITATION PREVIEW" : "", accent: .systemRed, filled: false)
        noticePill.render(Self.noticeText(from: presentation.transientNotice), accent: Self.noticeAccent)
        prefixLabel.stringValue = presentation.pendingPrefix == "y" || presentation.pendingPrefix.isEmpty
            ? ""
            : "prefix  \(presentation.pendingPrefix)"
        prefixLabel.isHidden = prefixLabel.stringValue.isEmpty
        detailLabel.stringValue = presentation.detail
        pathLabel.stringValue = presentation.documentPath
        copiedLabel.stringValue = presentation.transientNotice == "Copied!" ? "copied!" : ""
        pathLabel.isHidden = presentation.documentPath.isEmpty
        copiedLabel.isHidden = copiedLabel.stringValue.isEmpty
        pathLabel.setAccessibilityValue(presentation.documentPath.isEmpty ? nil : presentation.documentPath)
        pathLabel.toolTip = presentation.documentPath.isEmpty ? nil : presentation.documentPath
        detailLabel.setAccessibilityValue(presentation.detail)
        detailLabel.setAccessibilityHelp(presentation.expandedDetail)
        detailLabel.toolTip = presentation.expandedDetail
        errorButton.setAccessibilityValue(fullDiagnosticText.isEmpty ? nil : fullDiagnosticText)
        versionLabel.setAccessibilityValue(Self.displayVersion)
        if let theme {
            detailLabel.textColor = presentation.tone == .error ? theme[.error] : theme[.mutedText]
        }
        let visibleModes = [presentation.mode, presentation.isSearchMode ? "SEARCH" : "", presentation.isExperimentalMode ? "CITATION PREVIEW" : ""].filter { !$0.isEmpty }
        let modeDescription = visibleModes.isEmpty ? "" : ", modes \(visibleModes.joined(separator: ", "))"
        let noticeDescription = presentation.transientNotice.isEmpty ? "" : ", status \(presentation.transientNotice)"
        let pathDescription = presentation.documentPath.isEmpty ? "" : ", path \(presentation.documentPath)"
        setAccessibilityValue(
            [
                "Keyboard help available. Page \(presentation.page), zoom \(presentation.zoom)\(modeDescription)\(noticeDescription)\(pathDescription), \(presentation.detail). Version \(Self.displayVersion)",
                presentation.expandedDetail,
            ].compactMap { $0 }.joined(separator: ". ")
        )
        diagnosticPopover?.close()
        diagnosticPopover = nil
        diagnosticPopoverText = nil
        needsLayout = true
    }

    private func layoutResponsiveStatusBar() {
        let allViews: [NSView] = [
            helpButton, pageLabel, zoomLabel, prefixLabel, detailLabel,
            fitPagePill, pathLabel, copiedLabel, searchModePill, experimentalPill, noticePill,
            versionLabel, updateButton, errorButton,
        ]
        allViews.forEach { view in
            view.isHidden = true
            view.frame = .zero
        }
        guard bounds.width > 0 else { return }

        let availableWidth = max(0, bounds.width - contentInset * 2)
        let noticeText = Self.noticeText(from: presentation.transientNotice)
        let hasNotice = !noticeText.isEmpty
        let hasPath = !presentation.documentPath.isEmpty
        let hasCopied = presentation.transientNotice == "Copied!"
        let hasTransient = hasPath || hasCopied || !prefixLabel.stringValue.isEmpty
        let hasError = presentation.tone == .error && !fullDiagnosticText.isEmpty
        // An error owns the diagnostic slot even while SEARCH is active.  The
        // search badge is still a mode indicator, but its detail must not hide
        // an error message or make the compact Error action disappear.
        let hasSearchDetail = presentation.isSearchMode && !hasError

        // Basic items are protected before optional diagnostics/notices/update
        // are considered.  Version is kept at the trailing edge below.
        var basicIDs = ["help", "page", "zoom"]
        if !presentation.mode.isEmpty { basicIDs.append("fit") }
        var includeVersion = true
        var searchBadgeVisible = presentation.isSearchMode
        var suppressSearchDetail = false
        var searchStage = 0 // full badge/detail, detail without badge, count/state
        var includeError = false
        var useErrorButton = false
        var includeDiagnostic = false
        var includeNotice = false
        var includeUpdate = false

        func setDetailText() {
            if hasSearchDetail, !suppressSearchDetail {
                let text: String
                switch searchStage {
                case 0: text = presentation.detail
                case 1: text = compactSearchDetail(presentation.detail)
                default: text = minimumSearchDetail(presentation.detail)
                }
                detailLabel.stringValue = text.isEmpty ? "Searching…" : text
            } else {
                detailLabel.stringValue = presentation.detail
            }
        }

        func items(
            withError error: Bool,
            withDiagnostic diagnostic: Bool,
            withNotice notice: Bool,
            withUpdate update: Bool
        ) -> [LayoutItem] {
            setDetailText()
            var result: [LayoutItem] = []
            for id in basicIDs {
                switch id {
                case "help": result.append(LayoutItem(id: "status.help", view: helpButton, width: measuredButtonWidth(helpButton)))
                case "page": result.append(LayoutItem(id: "status.page", view: pageLabel, width: measuredLabelWidth(pageLabel)))
                case "zoom": result.append(LayoutItem(id: "status.zoom", view: zoomLabel, width: measuredLabelWidth(zoomLabel)))
                case "fit": result.append(LayoutItem(id: "status.mode", view: fitPagePill, width: fitPagePill.requiredWidth))
                default: break
                }
            }
            if searchBadgeVisible {
                result.append(LayoutItem(id: "status.searchMode", view: searchModePill, width: searchModePill.requiredWidth))
            }
            if presentation.isExperimentalMode {
                result.append(LayoutItem(id: "status.experimentalMode", view: experimentalPill, width: experimentalPill.requiredWidth))
            }
            // Notices are badges, so the path always follows the final
            // visible badge and remains left anchored.
            if notice {
                result.append(LayoutItem(id: "status.notice", view: noticePill, width: noticePill.requiredWidth))
            }
            if !prefixLabel.stringValue.isEmpty {
                result.append(LayoutItem(id: "status.prefix", view: prefixLabel, width: measuredLabelWidth(prefixLabel)))
            }
            if hasPath {
                result.append(LayoutItem(id: "status.path", view: pathLabel, width: max(minimumPathWidth, measuredLabelWidth(pathLabel))))
            }
            if hasCopied {
                result.append(LayoutItem(id: "status.copied", view: copiedLabel, width: measuredLabelWidth(copiedLabel)))
            }
            if error, hasError {
                if useErrorButton {
                    result.append(LayoutItem(id: "status.error", view: errorButton, width: measuredButtonWidth(errorButton)))
                } else {
                    result.append(LayoutItem(
                        id: "status.diagnostic",
                        view: detailLabel,
                        width: max(measuredLabelWidth(detailLabel), measuredTextWidth(fullDiagnosticText, font: detailLabel.font ?? .systemFont(ofSize: 11)))
                    ))
                }
            } else if hasSearchDetail, !suppressSearchDetail, !detailLabel.stringValue.isEmpty {
                result.append(LayoutItem(id: "status.diagnostic", view: detailLabel, width: measuredLabelWidth(detailLabel)))
            } else if diagnostic, !hasError, !hasSearchDetail, !detailLabel.stringValue.isEmpty {
                result.append(LayoutItem(id: "status.diagnostic", view: detailLabel, width: measuredLabelWidth(detailLabel)))
            }
            if update {
                result.append(LayoutItem(id: "status.update", view: updateButton, width: measuredButtonWidth(updateButton)))
            }
            if includeVersion {
                result.append(LayoutItem(id: "status.version", view: versionLabel, width: measuredLabelWidth(versionLabel)))
            }
            return result
        }

        func protectedItems() -> [LayoutItem] {
            items(withError: false, withDiagnostic: false, withNotice: false, withUpdate: false)
        }

        func fits(_ candidate: [LayoutItem]) -> Bool {
            guard !candidate.isEmpty else { return true }
            let widths = candidate.map(\.width)
            return widths.reduce(0, +) + itemSpacing * CGFloat(max(0, widths.count - 1)) <= availableWidth + 0.5
        }

        // Search is reduced as a unit.  The badge is not kept merely by
        // dropping unrelated basics: full SEARCH+detail is preferred, then
        // full detail without the badge, then the query-free state/count.
        if hasSearchDetail, !fits(protectedItems()) {
            searchBadgeVisible = false
            if !fits(protectedItems()) {
                searchStage = 1
                if !fits(protectedItems()) { searchStage = 2 }
            }
        }

        // Shed basics in the explicit order.  A transient path/prefix has
        // priority over search detail and therefore suppresses both the
        // SEARCH badge and detail before any basic row is retained.
        var attempts = 0
        while !fits(protectedItems()) && attempts < 24 {
            attempts += 1
            if hasTransient {
                if hasSearchDetail && !suppressSearchDetail {
                    suppressSearchDetail = true
                    searchBadgeVisible = false
                    continue
                }
                if !basicIDs.isEmpty || includeVersion {
                    basicIDs.removeAll()
                    includeVersion = false
                    continue
                }
            } else if includeVersion {
                includeVersion = false
                continue
            } else if let removable = ["help", "zoom", "fit", "page"].first(where: { basicIDs.contains($0) }) {
                basicIDs.removeAll { $0 == removable }
                continue
            }
            if hasSearchDetail, searchStage < 2, !suppressSearchDetail {
                searchStage += 1
                continue
            }
            break
        }

        // Errors are optional at full length but cannot disappear.  First try
        // the complete diagnostic beside the protected row; only if it does
        // not fit do we reserve the compact Error button and shed basics for
        // that button if absolutely necessary.
        if hasError {
            if fits(items(withError: true, withDiagnostic: false, withNotice: false, withUpdate: false)) {
                includeError = true
            } else {
                useErrorButton = true
                includeError = true
                var errorAttempts = 0
                while !fits(items(withError: true, withDiagnostic: false, withNotice: false, withUpdate: false)) && errorAttempts < 12 {
                    errorAttempts += 1
                    if hasTransient {
                        if !basicIDs.isEmpty || includeVersion {
                            basicIDs.removeAll()
                            includeVersion = false
                            continue
                        }
                    } else if includeVersion {
                        includeVersion = false
                        continue
                    } else if let removable = ["help", "zoom", "fit", "page"].first(where: { basicIDs.contains($0) }) {
                        basicIDs.removeAll { $0 == removable }
                        continue
                    }
                    break
                }
            }
        }

        // Optional content never displaces the protected row.  Admit it only
        // from remaining measured space and in diagnostic, notice, update order.
        if !hasError, !hasSearchDetail, !presentation.detail.isEmpty,
           fits(items(withError: includeError, withDiagnostic: true, withNotice: false, withUpdate: false)) {
            includeDiagnostic = true
        }
        if hasNotice,
           fits(items(withError: includeError, withDiagnostic: includeDiagnostic, withNotice: true, withUpdate: false)) {
            includeNotice = true
        }
        if updateText != nil,
           fits(items(withError: includeError, withDiagnostic: includeDiagnostic, withNotice: includeNotice, withUpdate: true)) {
            includeUpdate = true
        }

        place(
            items(withError: includeError, withDiagnostic: includeDiagnostic, withNotice: includeNotice, withUpdate: includeUpdate),
            in: availableWidth
        )
    }

    private func place(_ items: [LayoutItem], in availableWidth: CGFloat) {
        guard !items.isEmpty else { return }
        var widths = items.map(\.width)
        if let pathIndex = items.firstIndex(where: { $0.view === pathLabel }) {
            let nonPathWidth = widths.enumerated()
                .filter { $0.offset != pathIndex }
                .map { $0.element }
                .reduce(0, +)
            let gaps = itemSpacing * CGFloat(max(0, widths.count - 1))
            let remaining = availableWidth - nonPathWidth - gaps
            widths[pathIndex] = min(widths[pathIndex], max(1, remaining))
        }

        let versionIndex = items.firstIndex(where: { $0.view === versionLabel })
        var x = contentInset
        let controlHeight = max(1, min(22, bounds.height - 4))
        for (index, item) in items.enumerated() {
            // NSTextField cells draw at the top of oversized frames, unlike
            // NSButton cells. Center the natural line box, not a stretched field.
            let height = item.view is NSTextField
                ? ceil(item.view.intrinsicContentSize.height)
                : controlHeight
            let y = (bounds.height - height) / 2
            let width = max(1, widths[index])
            if let versionIndex, index == versionIndex {
                item.view.frame = NSRect(x: bounds.width - contentInset - width, y: y, width: width, height: height)
            } else {
                item.view.frame = NSRect(x: x, y: y, width: width, height: height)
                x += width
                if index < items.count - 1 { x += itemSpacing }
            }
            item.view.isHidden = false
        }
    }

    private struct LayoutItem {
        let id: String
        let view: NSView
        let width: CGFloat
    }


    private var fullDiagnosticText: String {
        let detail = presentation.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = presentation.expandedDetail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if detail.isEmpty { return expanded }
        if expanded.isEmpty || expanded == detail { return detail }
        return "\(detail)\n\n\(expanded)"
    }

    private static func noticeText(from value: String) -> String {
        value == "Copied!" ? "" : value
    }

    private func compactSearchDetail(_ detail: String) -> String {
        guard !detail.isEmpty else { return "" }
        if let open = detail.firstIndex(of: "“"), let close = detail[open...].firstIndex(of: "”") {
            let before = String(detail[..<open])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "·"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let after = String(detail[detail.index(after: close)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if after.isEmpty { return before }
            if after.hasPrefix("…") { return "\(before)\(after)" }
            return "\(before) \(after)"
        }
        return detail
    }

    private func minimumSearchDetail(_ detail: String) -> String {
        let compact = compactSearchDetail(detail)
        if let marker = compact.range(of: " · ") {
            let suffix = String(compact[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !suffix.isEmpty { return suffix }
        }
        if compact.localizedCaseInsensitiveContains("searching") { return "Searching…" }
        if compact.localizedCaseInsensitiveContains("no searchable") { return "No text" }
        if compact.localizedCaseInsensitiveContains("no match") { return "No matches" }
        return compact
    }


    private func measuredButtonWidth(_ button: NSButton) -> CGFloat {
        let fitting = button.fittingSize.width
        let titleWidth = measuredTextWidth(button.title, font: button.font ?? .systemFont(ofSize: 11)) + 16
        return max(ceil(fitting), ceil(titleWidth), 1)
    }

    private func measuredLabelWidth(_ label: NSTextField) -> CGFloat {
        max(ceil(label.intrinsicContentSize.width), measuredTextWidth(label.stringValue, font: label.font ?? .systemFont(ofSize: 11)) + 4)
    }

    private func measuredTextWidth(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static var displayVersion: String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "v\(raw.flatMap { $0.isEmpty ? nil : $0 } ?? "dev")"
    }

    private static func makeLabel(identifier: String, monospaced: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = monospaced
            ? .monospacedSystemFont(ofSize: 11, weight: .medium)
            : .systemFont(ofSize: 11, weight: .regular)
        label.setAccessibilityIdentifier(identifier)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = true
        return label
    }
}

@MainActor
private final class StatusUpdateButton: NSButton {
    var onHoverChange: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

@MainActor
private final class StatusModePillView: NSView {
    private let label: NSTextField

    init(identifier: String, accessibilityLabel: String) {
        label = NSTextField(labelWithString: "")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        translatesAutoresizingMaskIntoConstraints = true
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(accessibilityLabel)
        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.setAccessibilityIdentifier(identifier)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            // Keep the cell at its intrinsic line height, just like plain labels.
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    var contentAccessibilityIdentifier: String { label.accessibilityIdentifier() }

    required init?(coder: NSCoder) { nil }

    var requiredWidth: CGFloat {
        guard !label.stringValue.isEmpty else { return 0 }
        return ceil(label.intrinsicContentSize.width) + 14
    }

    func render(_ text: String, accent: NSColor?, filled: Bool = true) {
        label.stringValue = text
        isHidden = text.isEmpty
        setAccessibilityValue(text)
        label.isHidden = text.isEmpty
        guard let accent else { return }
        label.textColor = accent
        layer?.backgroundColor = (filled ? accent.withAlphaComponent(0.16) : NSColor.clear).cgColor
        layer?.borderColor = accent.withAlphaComponent(0.55).cgColor
        layer?.borderWidth = 1
    }
}
