import AppKit
import PDFReaderCore

/// A transparent, full-canvas overlay that, after `f`, outlines every visible
/// link and badges it with a Vimium-style label. It becomes first responder and
/// swallows every key while active (fully modal): typing narrows the labels, an
/// exact label activates that link, Esc cancels. It never intercepts the mouse.
@MainActor
final class LinkHintOverlayView: NSView {
    /// Called with the target index of the link whose label was completed.
    var onActivate: ((Int) -> Void)?
    var onCancel: (() -> Void)?

    private var hints: [(rects: [NSRect], label: String)] = []
    private var query = ""
    private var theme: AppKitTheme?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Link hints")
        setAccessibilityIdentifier("linkHintOverlay")
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func apply(theme: AppKitTheme) {
        self.theme = theme
        needsDisplay = true
    }

    /// Presents hints for `targets` (rects already in this view's coordinates).
    /// Presents a hint per rect-group (each group is a link's per-line rects, in
    /// this view's coordinates).
    func present(rectGroups: [[NSRect]]) {
        let labels = LinkHintLabels.generate(count: rectGroups.count)
        hints = Array(zip(rectGroups, labels)).map { (rects: $0.0, label: $0.1) }
        query = ""
        isHidden = false
        needsDisplay = true
    }

    func dismiss() {
        hints = []
        query = ""
        isHidden = true
        needsDisplay = true
    }

    var isPresenting: Bool { !isHidden }

    /// Test seams.
    var currentQuery: String { query }
    var visibleLabels: [String] { hints.map(\.label) }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // esc
            onCancel?()
            return true
        case 51: // backspace
            if !query.isEmpty {
                query.removeLast()
                needsDisplay = true
            }
            return true
        default:
            break
        }

        if let characters = event.charactersIgnoringModifiers?.lowercased(),
           characters.count == 1,
           let scalar = characters.unicodeScalars.first,
           CharacterSet.lowercaseLetters.contains(scalar) {
            let candidate = query + characters
            let labels = hints.map(\.label)
            if let match = LinkHintFilter.exactMatch(labels, typed: candidate) {
                onActivate?(match)
            } else if !LinkHintFilter.candidates(labels, typed: candidate).isEmpty {
                query = candidate
                needsDisplay = true
            }
            // An out-of-set letter is swallowed without changing the query.
            return true
        }

        // Modal: every other key is swallowed so no reader shortcut fires.
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !handleKeyDown(event) { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme, !hints.isEmpty else { return }
        let labels = hints.map(\.label)
        let matching = Set(LinkHintFilter.candidates(labels, typed: query))
        let accent = theme[.accent]
        let dim = theme[.mutedText].withAlphaComponent(0.35)

        for (index, hint) in hints.enumerated() {
            let isMatch = matching.contains(index)
            for rect in hint.rects {
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), xRadius: 3, yRadius: 3)
                outline.lineWidth = isMatch ? 2 : 1
                (isMatch ? accent : dim).setStroke()
                outline.stroke()
            }
            if isMatch, let badgeRect = hint.rects.first {
                drawBadge(hint.label, at: badgeRect, accent: accent, foreground: theme[.background])
            }
        }
    }

    private func drawBadge(_ label: String, at rect: NSRect, accent: NSColor, foreground: NSColor) {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
        let text = label.uppercased() as NSString
        let textSize = text.size(withAttributes: attributes)
        let padding: CGFloat = 3
        let badge = NSRect(
            x: rect.minX,
            y: rect.maxY - (textSize.height + padding * 2),
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 2
        )
        NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill(with: accent)
        text.draw(at: NSPoint(x: badge.minX + padding, y: badge.minY + padding), withAttributes: attributes)
    }
}

private extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}
