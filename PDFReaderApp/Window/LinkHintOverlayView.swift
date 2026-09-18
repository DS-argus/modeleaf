import AppKit
import PDFReaderCore

@MainActor
private final class LinkHintURLScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { false }
}

@MainActor
private final class LinkHintURLTextView: NSTextView {
    override var acceptsFirstResponder: Bool { false }
}

@MainActor
final class LinkHintOverlayView: NSView {
    private static let urlPromptActions = "↩ Open    Esc Close"
    var onCommit: ((Int) -> Void)?
    var onDismiss: (() -> Void)?

    private var hints: [(rects: [NSRect], label: String)] = []
    private var typedPrefix = ""
    private var urlHintIndices: Set<Int> = []
    private var urlHintURLs: [Int: String] = [:]
    private var selectedURLIndex: Int?
    private var skipsURLConfirmation = false
    private let urlPromptScrollView = LinkHintURLScrollView()
    private let urlPromptTextView = LinkHintURLTextView()
    private var urlPromptFrame = NSRect.zero

    var didRejectInputForTesting: (() -> Void)?
    private var theme: AppKitTheme?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        urlPromptScrollView.borderType = .noBorder
        urlPromptScrollView.drawsBackground = false
        urlPromptScrollView.hasVerticalScroller = false
        urlPromptScrollView.autohidesScrollers = false
        urlPromptScrollView.horizontalScrollElasticity = .none
        urlPromptTextView.isEditable = false
        urlPromptTextView.isSelectable = false
        urlPromptTextView.drawsBackground = false
        urlPromptTextView.isHorizontallyResizable = true
        urlPromptTextView.isVerticallyResizable = false
        urlPromptTextView.textContainerInset = .zero
        urlPromptTextView.textContainer?.lineFragmentPadding = 0
        urlPromptTextView.textContainer?.widthTracksTextView = false
        urlPromptTextView.textContainer?.heightTracksTextView = true
        urlPromptScrollView.documentView = urlPromptTextView
        urlPromptScrollView.isHidden = true
        addSubview(urlPromptScrollView)
        setAccessibilityIdentifier("linkHintOverlay")
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        needsDisplay = true
        needsLayout = true
    }

    func present(
        hints: [(rects: [NSRect], label: String)],
        urlHintIndices: Set<Int> = [],
        urlHintURLs: [Int: String] = [:],
        skipsURLConfirmation: Bool = false
    ) {
        self.hints = hints
        self.urlHintURLs = urlHintURLs
        self.urlHintIndices = urlHintIndices.union(urlHintURLs.keys)
        self.skipsURLConfirmation = skipsURLConfirmation
        clearURLSelection()
        typedPrefix = ""
        setAccessibilityLabel("Link hints")
        setAccessibilityValue(nil)
        isHidden = false
        needsDisplay = true
        needsLayout = true
    }

    func dismiss() {
        hints = []
        typedPrefix = ""
        clearURLSelection()
        urlHintIndices = []
        urlHintURLs = [:]
        skipsURLConfirmation = false
        setAccessibilityLabel(nil)
        setAccessibilityValue(nil)
        isHidden = true
        needsDisplay = true
        urlPromptScrollView.isHidden = true
        needsLayout = true
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, !isHidden {
            onDismiss?()
        }
        return resigned
    }

    var isPresenting: Bool { !isHidden }
    var currentPrefix: String { typedPrefix }
    var visibleLabels: [String] { hints.map(\.label) }
    var selectedURLIndexForTesting: Int? { selectedURLIndex }
    var confirmationURLForTesting: String? {
        selectedURLIndex.flatMap { urlHintURLs[$0] }
    }

    var urlPromptActionsForTesting: String? {
        confirmationURLForTesting == nil ? nil : Self.urlPromptActions
    }

    var matchingLabelsForTesting: [String] {
        LinkHintFilter.candidates(hints.map(\.label), typed: typedPrefix).map { hints[$0].label }
    }
    var urlPromptIsScrollableForTesting: Bool {
        !urlPromptScrollView.isHidden && urlPromptScrollView.hasHorizontalScroller
    }
    var urlPromptTextSurfaceForTesting: NSView { urlPromptTextView }
    var urlPromptContentWidthForTesting: CGFloat { urlPromptTextView.frame.width }
    var urlPromptViewportWidthForTesting: CGFloat { urlPromptScrollView.contentView.bounds.width }
    var hintRectCountsForTesting: [Int] { hints.map { $0.rects.count } }
    var hintRectsForTesting: [[NSRect]] { hints.map(\.rects) }
    var hasCallbacksForTesting: Bool { onCommit != nil || onDismiss != nil }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        let rejectedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        if !event.modifierFlags.intersection(rejectedModifiers).isEmpty {
            didRejectInputForTesting?()
            NSSound.beep()
            return true
        }

        if [36, 76].contains(event.keyCode) {
            guard let index = selectedURLIndex else {
                didRejectInputForTesting?()
                NSSound.beep()
                return true
            }
            // A held key must never turn a selected URL into an activation.
            guard !event.isARepeat else { return true }
            clearURLSelection()
            onCommit?(index)
            return true
        }

        switch event.keyCode {
        case 53, 48:
            cancelAndDismiss()
            return true
        case 51:
            if !typedPrefix.isEmpty {
                typedPrefix.removeLast()
                clearURLSelection()
                setAccessibilityLabel("Link hints")
                setAccessibilityValue(nil)
                needsDisplay = true
            }
            return true
        default:
            break
        }

        guard let text = event.charactersIgnoringModifiers?.lowercased(),
              text.count == 1,
              let scalar = text.unicodeScalars.first,
              CharacterSet.lowercaseLetters.contains(scalar)
        else {
            didRejectInputForTesting?()
            NSSound.beep()
            return true
        }

        let candidate = typedPrefix + text
        switch LinkHintFilter.filter(hints.map(\.label), typed: candidate) {
        case let .unique(index):
            if urlHintIndices.contains(index), !skipsURLConfirmation {
                typedPrefix = candidate
                selectedURLIndex = index
                needsLayout = true
                let url = urlHintURLs[index] ?? "External link"
                setAccessibilityLabel("External link selected")
                setAccessibilityValue("\(url). Press Enter to open, or Escape to close.")
                needsDisplay = true
            } else {
                onCommit?(index)
            }
        case .ambiguous:
            typedPrefix = candidate
            clearURLSelection()
            setAccessibilityLabel("Link hints")
            setAccessibilityValue(nil)
            needsDisplay = true
        case .none:
            didRejectInputForTesting?()
            NSSound.beep()
        }
        return true
    }

    override func keyDown(with event: NSEvent) { _ = handleKeyDown(event) }


    override func layout() {
        super.layout()
        updateURLPromptLayout()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme else { return }

        let labels = hints.map(\.label)
        let matches = Set(LinkHintFilter.candidates(labels, typed: typedPrefix))
        let accent = theme[.accent].withAlphaComponent(0.9)
        let dim = theme[.mutedText].withAlphaComponent(0.35)
        for (index, hint) in hints.enumerated() {
            let matching = matches.contains(index)
            for rect in hint.rects {
                let outline = NSBezierPath(
                    roundedRect: rect.insetBy(dx: -1.5, dy: -1.5),
                    xRadius: 3,
                    yRadius: 3
                )
                outline.lineWidth = matching ? 2 : 1
                (matching ? accent : dim).setStroke()
                outline.stroke()
            }
            if matching, let primary = hint.rects.first {
                drawBadge(hint.label, at: primary, accent: accent, foreground: theme[.background])
            }
        }

        guard selectedURLIndex != nil else { return }
        drawURLPrompt(theme: theme)
    }

    private func updateURLPromptLayout() {
        guard let theme,
              let index = selectedURLIndex,
              hints.indices.contains(index),
              let rect = hints[index].rects.first,
              let url = urlHintURLs[index]
        else {
            urlPromptFrame = .zero
            urlPromptScrollView.isHidden = true
            return
        }

        let titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: theme[.foreground],
        ]
        let keyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: theme[.mutedText],
        ]
        let maxContentWidth = max(120, min(bounds.width - 24, 360))
        let urlSize = (url as NSString).size(withAttributes: titleAttributes)
        let keySize = (Self.urlPromptActions as NSString).size(withAttributes: keyAttributes)
        let contentWidth = max(keySize.width, min(maxContentWidth, max(120, urlSize.width)))
        let titleHeight = ceil(
            urlPromptTextView.layoutManager?.defaultLineHeight(for: titleFont)
                ?? (titleFont.ascender - titleFont.descender + 2)
        )
        let needsHorizontalScroll = urlSize.width > contentWidth
        let scrollerHeight: CGFloat = needsHorizontalScroll ? 15 : 0
        let urlViewportHeight = titleHeight + scrollerHeight
        let popup = NSRect(
            x: max(bounds.minX + 8, min(bounds.maxX - contentWidth - 24, rect.maxX + 8)),
            y: max(
                bounds.minY + 8,
                min(
                    bounds.maxY - urlViewportHeight - keySize.height - 22,
                    rect.maxY - urlViewportHeight - keySize.height - 22
                )
            ),
            width: contentWidth + 16,
            height: urlViewportHeight + keySize.height + 14
        )
        urlPromptFrame = popup

        urlPromptTextView.textStorage?.setAttributedString(
            NSAttributedString(string: url, attributes: titleAttributes)
        )
        urlPromptTextView.frame = NSRect(
            x: 0,
            y: 0,
            width: max(contentWidth, urlSize.width),
            height: titleHeight
        )
        if let textContainer = urlPromptTextView.textContainer {
            textContainer.containerSize = urlPromptTextView.frame.size
            urlPromptTextView.layoutManager?.ensureLayout(for: textContainer)
        }
        urlPromptScrollView.hasHorizontalScroller = needsHorizontalScroll
        urlPromptScrollView.frame = NSRect(
            x: popup.minX + 8,
            y: popup.minY + keySize.height + 7,
            width: contentWidth,
            height: urlViewportHeight
        )
        urlPromptScrollView.isHidden = false
        urlPromptScrollView.reflectScrolledClipView(urlPromptScrollView.contentView)
    }

    private func drawURLPrompt(theme: AppKitTheme) {
        guard !urlPromptFrame.isEmpty else { return }
        let keyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: theme[.mutedText],
        ]
        theme[.activeTab].withAlphaComponent(0.97).setFill()
        NSBezierPath(roundedRect: urlPromptFrame, xRadius: 4, yRadius: 4).fill()
        let outline = NSBezierPath(roundedRect: urlPromptFrame, xRadius: 4, yRadius: 4)
        outline.lineWidth = 1
        theme[.accent].withAlphaComponent(0.8).setStroke()
        outline.stroke()
        Self.urlPromptActions.draw(
            at: NSPoint(x: urlPromptFrame.minX + 8, y: urlPromptFrame.minY + 4),
            withAttributes: keyAttributes
        )
    }
    private func clearURLSelection() {
        urlPromptFrame = .zero
        urlPromptScrollView.isHidden = true
        urlPromptScrollView.contentView.scroll(to: .zero)
        urlPromptScrollView.reflectScrolledClipView(urlPromptScrollView.contentView)
        needsLayout = true
        selectedURLIndex = nil
    }

    private func cancelAndDismiss() {
        typedPrefix = ""
        clearURLSelection()
        setAccessibilityLabel("Link hints")
        setAccessibilityValue(nil)
        needsDisplay = true
        onDismiss?()
    }

    private func drawBadge(_ label: String, at rect: NSRect, accent: NSColor, foreground: NSColor) {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        let full = label.uppercased() as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
        let size = full.size(withAttributes: attributes)
        let badge = NSRect(
            x: rect.minX,
            y: rect.maxY - size.height - 6,
            width: size.width + 6,
            height: size.height + 6
        )
        accent.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
        let prefixCount = min(typedPrefix.count, label.count)
        let dimmed = NSMutableAttributedString(string: label.uppercased(), attributes: attributes)
        if prefixCount > 0 {
            dimmed.addAttribute(
                .foregroundColor,
                value: foreground.withAlphaComponent(0.55),
                range: NSRange(location: 0, length: prefixCount)
            )
        }
        dimmed.draw(at: NSPoint(x: badge.minX + 3, y: badge.minY + 3))
    }
}
