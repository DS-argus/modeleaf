import AppKit
import PDFKit

enum ReaderVerticalScrollOutcome: Equatable {
    case moved
    case atBoundary
    case notScrollable
}

enum ReaderVerticalBoundary {
    case start
    case end
}

@MainActor
final class ReaderPDFView: PDFView {
    var keyEventHandler: ((NSEvent) -> Bool)?

    private lazy var readOnlyDelegate = ReaderPDFViewDelegate(owner: self)

    private(set) var blockedActionCount = 0
    private(set) var blockedHistoryCount = 0
    private(set) var blockedLinkCount = 0
    private(set) var blockedPrintCount = 0
    private(set) var blockedMouseSequenceCount = 0
    private var isBlockingMouseSequence = false
    private var focusIndicatorColor = NSColor.clear

    override var acceptsFirstResponder: Bool { true }

    /// The PDF canvas responds to the first click in an inactive window so a
    /// pane click both focuses the window and activates that pane (EF5/AC-4).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        acceptsDraggedFiles = false
        enableDataDetectors = false
        isInMarkupMode = false
        displayDirection = .vertical
        displayMode = .singlePageContinuous
        displaysPageBreaks = true
        pageBreakMargins = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        pageShadowsEnabled = true
        minScaleFactor = 0.1
        maxScaleFactor = 8
        autoScales = true
        backgroundColor = .clear
        setAccessibilityIdentifier("pdfDocumentView")
        setAccessibilityLabel("PDF document")
        delegate = readOnlyDelegate
        updateFocusAppearance(isFocused: false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let area = areaOfInterest(for: point)
        return PDFCapabilityPolicy.allowsMouseInteraction(in: area) ? super.hitTest(point) : self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let area = areaOfInterest(for: point)
        guard PDFCapabilityPolicy.allowsMouseInteraction(in: area) else {
            blockedMouseSequenceCount += 1
            isBlockingMouseSequence = true
            return
        }
        isBlockingMouseSequence = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isBlockingMouseSequence else { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { isBlockingMouseSequence = false }
        guard !isBlockingMouseSequence else { return }
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if performAllowedSystemKeyEquivalent(event) { return }
        if keyEventHandler?(event) == true { return }
        if performKeyViewTraversal(event) { return }
        NSSound.beep()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if performAllowedSystemKeyEquivalent(event) { return true }
        return keyEventHandler?(event) == true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        updateFocusAppearance(isFocused: accepted)
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            updateFocusAppearance(isFocused: false)
        }
        return resigned
    }

    override func perform(_ action: PDFAction) {
        blockedActionCount += 1
    }

    override func goBack(_ sender: Any?) {
        blockedHistoryCount += 1
    }

    override func goForward(_ sender: Any?) {
        blockedHistoryCount += 1
    }

    override func printView(_ sender: Any?) {
        blockedPrintCount += 1
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeSafeContextMenu()
    }

    func makeSafeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "PDF")
        menu.autoenablesItems = false
        let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = currentSelection?.string?.isEmpty == false
        menu.addItem(copyItem)
        return menu
    }

    func shouldForwardMouseEvent(in area: PDFAreaOfInterest) -> Bool {
        PDFCapabilityPolicy.allowsMouseInteraction(in: area)
    }

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        blockedLinkCount += 1
    }

    func pdfViewPerformPrint(_ sender: PDFView) {
        blockedPrintCount += 1
    }

    func pdfViewPerformFind(_ sender: PDFView) {
        blockedActionCount += 1
    }

    func pdfViewPerformGo(toPage sender: PDFView) {
        blockedActionCount += 1
    }

    func prepareForClose() {
        keyEventHandler = nil
        delegate = nil
        currentSelection = nil
        document = nil
    }

    func enforceReadOnlyDocumentConfiguration() {
        enableDataDetectors = false
        isInMarkupMode = false
    }

    func applyCanvasBackground(_ color: NSColor) {
        backgroundColor = color
    }

    func applyFocusIndicator(_ color: NSColor) {
        focusIndicatorColor = color
        refreshFocusAppearance()
    }

    func scrollBy(xPoints: Double, yPoints: Double) {
        guard xPoints.isFinite, yPoints.isFinite,
              let scrollView = documentScrollView
        else {
            return
        }
        let clipView = scrollView.contentView
        let isFlipped = scrollView.documentView?.isFlipped ?? true
        let proposedOrigin = NSPoint(
            x: clipView.bounds.origin.x + xPoints,
            y: clipView.bounds.origin.y + (isFlipped ? yPoints : -yPoints)
        )
        let constrained = clipView.constrainBoundsRect(
            NSRect(origin: proposedOrigin, size: clipView.bounds.size)
        )
        clipView.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    @discardableResult
    func scrollVertically(byPoints points: Double) -> ReaderVerticalScrollOutcome {
        guard points.isFinite, points != 0,
              let scrollView = documentScrollView,
              let documentView = scrollView.documentView
        else {
            return .notScrollable
        }

        let clipView = scrollView.contentView
        let tolerance: CGFloat = 0.5
        guard documentView.bounds.height > clipView.bounds.height + tolerance else {
            return .notScrollable
        }

        let initialOrigin = clipView.bounds.origin
        let isFlipped = documentView.isFlipped
        let proposedOrigin = NSPoint(
            x: initialOrigin.x,
            y: initialOrigin.y + (isFlipped ? points : -points)
        )
        let constrained = clipView.constrainBoundsRect(
            NSRect(origin: proposedOrigin, size: clipView.bounds.size)
        )
        guard abs(constrained.origin.y - initialOrigin.y) > tolerance else {
            return .atBoundary
        }

        clipView.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clipView)
        return .moved
    }

    @discardableResult
    func scrollVerticallyByViewportFraction(_ fraction: Double) -> ReaderVerticalScrollOutcome {
        guard fraction.isFinite, let scrollView = documentScrollView else {
            return .notScrollable
        }
        return scrollVertically(byPoints: scrollView.contentView.bounds.height * fraction)
    }

    func scrollToVerticalBoundary(_ boundary: ReaderVerticalBoundary) {
        guard let scrollView = documentScrollView,
              let documentView = scrollView.documentView
        else {
            return
        }
        let fullTraversal = Double(documentView.bounds.height + scrollView.contentView.bounds.height)
        _ = scrollVertically(byPoints: boundary == .start ? -fullTraversal : fullTraversal)
    }

    private func performAllowedSystemKeyEquivalent(_ event: NSEvent) -> Bool {
        let relevantFlags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard relevantFlags == .command,
              event.charactersIgnoringModifiers?.lowercased() == "c",
              currentSelection?.string?.isEmpty == false
        else {
            return false
        }
        copy(nil)
        return true
    }

    private func performKeyViewTraversal(_ event: NSEvent) -> Bool {
        let characters = event.charactersIgnoringModifiers
        guard characters == "\t" || characters == "\u{19}",
              let window
        else {
            return false
        }

        let relevantFlags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard relevantFlags.subtracting(.shift).isEmpty else { return false }

        let movesBackward = characters == "\u{19}" || relevantFlags.contains(.shift)
        guard let explicitTarget = movesBackward ? previousKeyView : nextKeyView else { return false }
        return window.makeFirstResponder(explicitTarget)
    }

    /// Recomputes the focus ring from the window's actual first responder.
    ///
    /// PDFView routinely moves first-responder status to an internal document
    /// view, so responder-override callbacks alone can leave a stale ring on a
    /// pane that lost focus indirectly (e.g. right after a split). The shell
    /// calls this on every settled snapshot render.
    func refreshFocusAppearance() {
        let responder = window?.firstResponder as? NSView
        let focused = responder.map { $0 === self || $0.isDescendant(of: self) } ?? false
        updateFocusAppearance(isFocused: focused)
    }

    private func updateFocusAppearance(isFocused: Bool) {
        layer?.borderColor = focusIndicatorColor.cgColor
        layer?.borderWidth = isFocused ? WindowVisualMetrics.canvasFocusRingWidth : 0
    }

    private var documentScrollView: NSScrollView? {
        firstScrollView(in: self)
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) { return scrollView }
        }
        return nil
    }
}

@MainActor
private final class ReaderPDFViewDelegate: NSObject, @preconcurrency PDFViewDelegate {
    private weak var owner: ReaderPDFView?

    init(owner: ReaderPDFView) {
        self.owner = owner
    }

    func pdfViewWillChangeScaleFactor(_ sender: PDFView, toScale scaler: CGFloat) -> CGFloat {
        scaler
    }

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        owner?.pdfViewWillClick(onLink: sender, with: url)
    }

    func pdfViewPerformPrint(_ sender: PDFView) {
        owner?.pdfViewPerformPrint(sender)
    }

    func pdfViewPerformFind(_ sender: PDFView) {
        owner?.pdfViewPerformFind(sender)
    }

    func pdfViewPerformGo(toPage sender: PDFView) {
        owner?.pdfViewPerformGo(toPage: sender)
    }
}
