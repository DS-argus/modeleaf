import AppKit
import PDFReaderCore

@MainActor
final class LinkHintOverlayView: NSView {
    var onCommit: ((Int) -> Void)?
    var onDismiss: (() -> Void)?

    private var hints: [(rects: [NSRect], label: String)] = []
    private var typedPrefix = ""
    private var urlHintIndices: Set<Int> = []
    private var urlHintURLs: [Int: String] = [:]
    private var selectedURLIndex: Int?
    private var isShowingURLConfirmation = false
    private var skipsURLConfirmation = false

    var didRejectInputForTesting: (() -> Void)?
    private var theme: AppKitTheme?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityIdentifier("linkHintOverlay")
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        needsDisplay = true
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
    var isURLConfirmationVisibleForTesting: Bool { isShowingURLConfirmation }
    var confirmationURLForTesting: String? {
        selectedURLIndex.flatMap { urlHintURLs[$0] }
    }

    var matchingLabelsForTesting: [String] {
        LinkHintFilter.candidates(hints.map(\.label), typed: typedPrefix).map { hints[$0].label }
    }
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
            // A held key must never turn a confirmation into an activation. The
            // second explicit, non-repeat Enter is the only commit path.
            guard !event.isARepeat else { return true }
            if !isShowingURLConfirmation {
                isShowingURLConfirmation = true
                let url = urlHintURLs[index] ?? "External link"
                setAccessibilityLabel("External link URL")
                setAccessibilityValue("\(url). Press Enter to open, or Escape to cancel.")
                needsDisplay = true
            } else {
                clearURLSelection()
                onCommit?(index)
            }
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
                isShowingURLConfirmation = false
                setAccessibilityLabel("External link selected")
                setAccessibilityValue("Press Enter to show the URL, or Escape to cancel.")
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

        guard let index = selectedURLIndex,
              let rect = hints.indices.contains(index) ? hints[index].rects.first : nil
        else { return }
        drawURLPrompt(
            url: isShowingURLConfirmation ? urlHintURLs[index] : nil,
            near: rect,
            theme: theme
        )
    }

    private func drawURLPrompt(url: String?, near rect: NSRect, theme: AppKitTheme) {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: theme[.foreground],
        ]
        let keyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: theme[.mutedText],
        ]
        let maxContentWidth = max(120, min(bounds.width - 24, 360))
        let title = url.map {
            fittingURL(
                $0.replacingOccurrences(of: "\n", with: " "),
                attributes: titleAttributes,
                maxWidth: maxContentWidth
            )
        } ?? "Open link?"
        let keyText = url == nil ? "Enter details    Esc cancel" : "Enter open    Esc cancel"
        let titleSize = (title as NSString).size(withAttributes: titleAttributes)
        let keySize = (keyText as NSString).size(withAttributes: keyAttributes)
        let contentWidth = max(titleSize.width, keySize.width)
        let popup = NSRect(
            x: max(bounds.minX + 8, min(bounds.maxX - contentWidth - 24, rect.maxX + 8)),
            y: max(
                bounds.minY + 8,
                min(
                    bounds.maxY - titleSize.height - keySize.height - 22,
                    rect.maxY - titleSize.height - keySize.height - 22
                )
            ),
            width: contentWidth + 16,
            height: titleSize.height + keySize.height + 14
        )

        theme[.activeTab].withAlphaComponent(0.97).setFill()
        NSBezierPath(roundedRect: popup, xRadius: 4, yRadius: 4).fill()
        let outline = NSBezierPath(roundedRect: popup, xRadius: 4, yRadius: 4)
        outline.lineWidth = 1
        theme[.accent].withAlphaComponent(0.8).setStroke()
        outline.stroke()
        title.draw(
            at: NSPoint(x: popup.minX + 8, y: popup.minY + keySize.height + 7),
            withAttributes: titleAttributes
        )
        keyText.draw(
            at: NSPoint(x: popup.minX + 8, y: popup.minY + 4),
            withAttributes: keyAttributes
        )
    }

    private func fittingURL(
        _ value: String,
        attributes: [NSAttributedString.Key: Any],
        maxWidth: CGFloat
    ) -> String {
        guard (value as NSString).size(withAttributes: attributes).width > maxWidth else { return value }
        let suffix = "..."
        var count = value.count
        while count > 0 {
            let candidate = String(value.prefix(count)) + suffix
            if (candidate as NSString).size(withAttributes: attributes).width <= maxWidth {
                return candidate
            }
            count -= 1
        }
        return suffix
    }

    private func clearURLSelection() {
        selectedURLIndex = nil
        isShowingURLConfirmation = false
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
