import AppKit
import PDFReaderCore

@MainActor
final class LinkHintOverlayView: NSView {
    var onCommit: ((Int) -> Void)?
    var onDismiss: (() -> Void)?

    private var hints: [(rects: [NSRect], label: String)] = []
    private var typedPrefix = ""

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

    func apply(theme: AppKitTheme) { self.theme = theme; needsDisplay = true }

    func present(hints: [(rects: [NSRect], label: String)]) {
        self.hints = hints
        typedPrefix = ""
        isHidden = false
        needsDisplay = true
    }

    func dismiss() {
        hints = []
        typedPrefix = ""
        isHidden = true
        needsDisplay = true
    }

    var isPresenting: Bool { !isHidden }
    var currentPrefix: String { typedPrefix }
    var visibleLabels: [String] { hints.map(\.label) }

    var matchingLabelsForTesting: [String] {
        LinkHintFilter.candidates(hints.map(\.label), typed: typedPrefix).map { hints[$0].label }
    }
    var hintRectCountsForTesting: [Int] { hints.map { $0.rects.count } }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !modifiers.isEmpty { didRejectInputForTesting?(); NSSound.beep(); return true }
        switch event.keyCode {
        case 53: onDismiss?(); return true
        case 51:
            if !typedPrefix.isEmpty { typedPrefix.removeLast(); needsDisplay = true }
            return true
        default: break
        }
        guard let text = event.charactersIgnoringModifiers?.lowercased(), text.count == 1,
              let scalar = text.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(scalar)
        else { didRejectInputForTesting?(); NSSound.beep(); return true }
        let candidate = typedPrefix + text
        switch LinkHintFilter.filter(hints.map(\.label), typed: candidate) {
        case let .unique(index): onCommit?(index)
        case .ambiguous: typedPrefix = candidate; needsDisplay = true
        case .none: didRejectInputForTesting?(); NSSound.beep()
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
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), xRadius: 3, yRadius: 3)
                outline.lineWidth = matching ? 2 : 1
                (matching ? accent : dim).setStroke()
                outline.stroke()
            }
            if matching, let primary = hint.rects.first { drawBadge(hint.label, at: primary, accent: accent, foreground: theme[.background]) }
        }
    }

    private func drawBadge(_ label: String, at rect: NSRect, accent: NSColor, foreground: NSColor) {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        let full = label.uppercased() as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
        let size = full.size(withAttributes: attributes)
        let badge = NSRect(x: rect.minX, y: rect.maxY - size.height - 6, width: size.width + 6, height: size.height + 6)
        accent.setFill(); NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
        let prefixCount = min(typedPrefix.count, label.count)
        let dimmed = NSMutableAttributedString(string: label.uppercased(), attributes: attributes)
        if prefixCount > 0 { dimmed.addAttribute(.foregroundColor, value: foreground.withAlphaComponent(0.55), range: NSRange(location: 0, length: prefixCount)) }
        dimmed.draw(at: NSPoint(x: badge.minX + 3, y: badge.minY + 3))
    }
}
