import AppKit
import PDFKit
import PDFReaderCore

enum ReaderVerticalScrollOutcome: Equatable {
    case moved
    case atBoundary
    case notScrollable
}

enum ReaderVerticalBoundary {
    case start
    case end
}
enum ReaderNativeViewportGesture: Equatable, Sendable {
    case began
    case ended
    case cancelled
}

@MainActor
protocol ReaderPDFViewInternalLinkHandling: AnyObject {
    func readerPDFView(_ view: ReaderPDFView, activateInternalLink target: ReaderLinkTarget)
}


@MainActor
final class ReaderPDFView: PDFView {
    var keyEventHandler: ((NSEvent) -> Bool)?
    weak var internalLinkHandler: (any ReaderPDFViewInternalLinkHandling)?

    /// Invoked with a URL link's target when the user clicks it; the shell opens
    /// it in the browser. In-document (GoTo) links navigate without this handler.
    var followLinkHandler: ((URL) -> Void)?
    var viewportGestureHandler: ((ReaderNativeViewportGesture) -> Void)?

    private lazy var readOnlyDelegate = ReaderPDFViewDelegate(owner: self)

    private(set) var blockedActionCount = 0
    private(set) var blockedHistoryCount = 0
    private(set) var blockedPrintCount = 0
    private(set) var blockedMouseSequenceCount = 0
    private(set) var followedLinkCount = 0
    private var isBlockingMouseSequence = false
    private var nativeViewportGestureActive = false
    private var pendingViewportGestureEnd: DispatchWorkItem?
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

    /// Links are clickable (in-document jump / open URL in browser), so show the
    /// pointing hand over them. Text keeps its I-beam (those cursor rects are
    /// left untouched).
    override func resetCursorRects() {
        super.resetCursorRects()
        for page in visiblePages {
            for annotation in page.annotations where annotation.type == "Link" || annotation.action != nil || annotation.url != nil {
                addCursorRect(convert(annotation.bounds, from: page), cursor: .pointingHand)
            }
        }
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
    override func scrollWheel(with event: NSEvent) {
        let phase = event.phase
        let momentum = event.momentumPhase
        let phaseLess = phase == [] && momentum == []
        let begins = phaseLess || phase == .began || momentum == .began
        if begins {
            pendingViewportGestureEnd?.cancel()
            pendingViewportGestureEnd = nil
            if !nativeViewportGestureActive {
                nativeViewportGestureActive = true
                viewportGestureHandler?(.began)
            }
        }
        super.scrollWheel(with: event)

        let cancels = phase == .cancelled || momentum == .cancelled
        if cancels {
            finishNativeViewportGesture(.cancelled)
        } else if phaseLess || momentum == .ended {
            finishNativeViewportGesture(.ended)
        } else if phase == .ended {
            let pending = DispatchWorkItem { [weak self] in self?.finishNativeViewportGesture(.ended) }
            pendingViewportGestureEnd = pending
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40), execute: pending)
        }
    }

    private func finishNativeViewportGesture(_ terminal: ReaderNativeViewportGesture) {
        pendingViewportGestureEnd?.cancel()
        pendingViewportGestureEnd = nil
        guard nativeViewportGestureActive else { return }
        nativeViewportGestureActive = false
        viewportGestureHandler?(terminal)
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
        if resigned { updateFocusAppearance(isFocused: false) }
        return resigned
    }
    override func perform(_ action: PDFAction) {
        if let urlAction = action as? PDFActionURL, let url = urlAction.url {
            activateURL(url)
            return
        }
        guard let goTo = action as? PDFActionGoTo,
              let target = internalTarget(for: goTo.destination)
        else {
            blockedActionCount += 1
            return
        }
        internalLinkHandler?.readerPDFView(self, activateInternalLink: target)
    }

    /// Hint and mouse GoTo links share the session-owned transaction executor.
    func activate(_ target: ReaderLinkTarget) {
        switch target {
        case .goTo:
            internalLinkHandler?.readerPDFView(self, activateInternalLink: target)
        case let .url(value):
            guard let url = URL(string: value) else { return }
            activateURL(url)
        }
    }

    private func internalTarget(for destination: PDFDestination) -> ReaderLinkTarget? {
        guard let document,
              let page = destination.page,
              page.document === document
        else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0, pageIndex < document.pageCount else { return nil }
        return .goTo(pageIndex: pageIndex, point: destination.point)
    }

    private func activateURL(_ url: URL) {
        followedLinkCount += 1
        followLinkHandler?(url)
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
        activateURL(url)
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
            x: clipView.bounds.origin.x + horizontalScroll(constraining: CGFloat(xPoints)),
            y: clipView.bounds.origin.y + (isFlipped ? yPoints : -yPoints)
        )
        let constrained = clipView.constrainBoundsRect(
            NSRect(origin: proposedOrigin, size: clipView.bounds.size)
        )
        clipView.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    /// The on-screen rectangle of `page`, including scale and rotation.
    func displayedRect(of page: PDFPage) -> NSRect {
        convert(page.bounds(for: .cropBox), from: page)
    }

    /// Whether `page` is currently narrow enough to be shown in full.
    func pageFitsViewportWidth(_ page: PDFPage) -> Bool {
        let width = displayedRect(of: page).width
        return width.isFinite && width <= bounds.width + Self.horizontalFitTolerance
    }

    /// The scale that fits `pageWidth` plus its page-break margins into the viewport.
    func scaleFactorFittingWidth(_ pageWidth: CGFloat) -> CGFloat? {
        let available = bounds.width
        let margins = pageBreakMargins.left + pageBreakMargins.right
        guard pageWidth > 0, pageWidth.isFinite, available > 1 else { return nil }
        return min(maxScaleFactor, max(minScaleFactor, available / (pageWidth + margins)))
    }

    /// Centres `page` horizontally when it fits the viewport, and reports whether
    /// it did. A continuous layout is as wide as the widest page in the document,
    /// so without this a narrower page keeps whatever horizontal offset the
    /// previous page left behind. Pages too wide to fit are left alone so the
    /// reader stays on the part they were reading.
    @discardableResult
    func centerHorizontallyIfPageFits(_ page: PDFPage) -> Bool {
        guard let scrollView = documentScrollView,
              let documentView = scrollView.documentView
        else { return false }
        layoutDocumentView()
        guard pageFitsViewportWidth(page) else { return false }

        let pageRect = displayedRect(of: page)
        let offset = documentDistance(pageRect.midX - bounds.midX, in: documentView)
        guard offset.isFinite else { return false }
        guard abs(offset) > 0.01 else { return true }

        let clipView = scrollView.contentView
        let proposedOrigin = NSPoint(x: clipView.bounds.origin.x + offset, y: clipView.bounds.origin.y)
        let constrained = clipView.constrainBoundsRect(
            NSRect(origin: proposedOrigin, size: clipView.bounds.size)
        )
        clipView.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clipView)
        return true
    }

    /// Keeps horizontal movement inside the current page. A page that already
    /// fits cannot be pushed off centre into the empty canvas a wider page in
    /// the same document reserves, and a wider page stops at its own edges.
    private func horizontalScroll(constraining requested: CGFloat) -> CGFloat {
        guard requested != 0,
              let page = currentPage,
              let documentView = documentScrollView?.documentView
        else { return requested }
        let pageRect = displayedRect(of: page)
        guard pageRect.width.isFinite, pageRect.width > 0 else { return requested }
        guard pageRect.width > bounds.width + Self.horizontalFitTolerance else { return 0 }

        let scrollableLeft = documentDistance(pageRect.minX, in: documentView)
        let scrollableRight = documentDistance(pageRect.maxX - bounds.width, in: documentView)
        return min(max(requested, scrollableLeft), scrollableRight)
    }

    /// Converts a signed horizontal distance from this view's space into the
    /// scrolled document's space, which is where clip-view offsets live.
    /// `NSSize` conversion drops the sign, so the distance is converted as the
    /// gap between two converted points.
    private func documentDistance(_ viewDistance: CGFloat, in documentView: NSView) -> CGFloat {
        let origin = convert(NSPoint(x: 0, y: 0), to: documentView)
        let shifted = convert(NSPoint(x: viewDistance, y: 0), to: documentView)
        return shifted.x - origin.x
    }

    private static let horizontalFitTolerance: CGFloat = 0.5

    /// Moves a PDF page-space point onto the visible viewport centre using the
    /// scroll view's document coordinate space. Returns whether PDFKit clamped
    /// the requested centre at a document boundary.
    @discardableResult
    func centerPagePoint(_ pagePoint: CGPoint, on page: PDFPage) -> Bool? {
        guard let scrollView = documentScrollView,
              let documentView = scrollView.documentView
        else { return nil }

        let clipView = scrollView.contentView
        var wasConstrained = false
        for _ in 0..<3 {
            layoutDocumentView()
            let anchorInDocument = convert(convert(pagePoint, from: page), to: documentView)
            let viewportCenterInDocument = convert(
                NSPoint(x: bounds.midX, y: bounds.midY),
                to: documentView
            )
            let proposedOrigin = NSPoint(
                x: clipView.bounds.origin.x + anchorInDocument.x - viewportCenterInDocument.x,
                y: clipView.bounds.origin.y + anchorInDocument.y - viewportCenterInDocument.y
            )
            let constrained = clipView.constrainBoundsRect(
                NSRect(origin: proposedOrigin, size: clipView.bounds.size)
            ).origin
            wasConstrained = wasConstrained
                || abs(constrained.x - proposedOrigin.x) > 0.5
                || abs(constrained.y - proposedOrigin.y) > 0.5
            guard abs(constrained.x - clipView.bounds.origin.x) > 0.01
                    || abs(constrained.y - clipView.bounds.origin.y) > 0.01
            else { break }
            clipView.scroll(to: constrained)
            scrollView.reflectScrolledClipView(clipView)
        }
        layoutDocumentView()
        return wasConstrained
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
