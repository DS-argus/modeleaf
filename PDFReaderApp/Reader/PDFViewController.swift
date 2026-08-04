import AppKit
import PDFKit
import PDFReaderCore

enum ReaderViewMode: String, Equatable, Sendable {
    case manual
    case actualSize
    case fitWidth
    case fitPage
}

enum InitialPDFPresentationState: String, Equatable, Sendable {
    case pending
    case applying
    case applied
    case supersededByUser
}


enum NavigationRestoreOutcome: Equatable, Sendable {
    case preflightRejected
    case verifiedLanding
    case compensatedFailure
    case uncompensatedInvariantFailure(actualLanding: NavigationSnapshot?)
}
@MainActor
final class PDFViewController: NSViewController {
    private let readerView: ReaderPDFView
    private let initialDocument: PDFDocument
    private let openTraceID: OpenTraceID
    private let openMetrics: any PDFOpenMetrics
    private var canvasBackground: NSColor
    private var pendingPresentationNavigation: NavigationSnapshot?
    private var focusIndicator: NSColor
    private var pendingPresentationFailureHandler: (() -> Void)?
    private var pendingPresentationSuccessHandler: (() -> Void)?
    private(set) var viewMode: ReaderViewMode = .fitPage
    private(set) var initialPresentationState: InitialPDFPresentationState = .pending
    private var searchPalette = SearchHighlightPalette.default
    private var searchSelections: [PDFSelection] = []
    private var activeSearchIndex: Int?
    private var internalLinkHandler: ((ReaderLinkTarget) -> Void)?
    private var navigationSnapshotCaptureOverride: (() -> NavigationSnapshot?)?

    init(document: PDFDocument, traceID: OpenTraceID, metrics: any PDFOpenMetrics) {
        self.initialDocument = document
        self.openTraceID = traceID
        self.openMetrics = metrics
        self.readerView = ReaderPDFView(frame: .zero)
        let defaultTheme = AppKitTheme(themeID: .tokyoNight)
        self.canvasBackground = defaultTheme.canvasBackground
        self.focusIndicator = defaultTheme.focusRing
        super.init(nibName: nil, bundle: nil)
        readerView.applyCanvasBackground(canvasBackground)
        readerView.applyFocusIndicator(focusIndicator)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = canvasBackground.cgColor
        container.setAccessibilityIdentifier("pdfCanvas")
        container.setAccessibilityRole(.group)
        container.setAccessibilityLabel("PDF canvas")

        readerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(readerView)
        NSLayoutConstraint.activate([
            readerView.topAnchor.constraint(equalTo: container.topAnchor),
            readerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            readerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            readerView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        readerView.displayMode = .singlePage
        readerView.autoScales = true
        openMetrics.record(.begin(.pdfViewDocumentAttach, traceID: openTraceID))
        readerView.document = initialDocument
        readerView.enforceReadOnlyDocumentConfiguration()
        readerView.internalLinkHandler = self
        readerView.followLinkHandler = { NSWorkspace.shared.open($0) }
        openMetrics.record(.end(.pdfViewDocumentAttach, traceID: openTraceID, outcome: .success))
        view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyInitialPresentationIfReady()
    }

    var focusView: NSView {
        loadViewIfNeeded()
        return readerView
    }

    var pageCount: Int { initialDocument.pageCount }

    var currentPageNumber: Int? {
        loadViewIfNeeded()
        guard let page = readerView.currentPage else { return nil }
        return initialDocument.index(for: page) + 1
    }

    var scaleFactor: CGFloat {
        loadViewIfNeeded()
        return readerView.scaleFactor
    }

    var usesSinglePageLayout: Bool {
        loadViewIfNeeded()
        return readerView.displayMode == .singlePage
    }

    /// Captures the viewport centre in PDF page coordinates. Before mounting,
    /// the deterministic current-page centre represents the not-yet-visible viewport.
    func captureNavigationSnapshot() -> NavigationSnapshot? {
        loadViewIfNeeded()
        if let navigationSnapshotCaptureOverride { return navigationSnapshotCaptureOverride() }
        guard let page = readerView.currentPage ?? initialDocument.page(at: 0) else { return nil }
        let pageIndex = initialDocument.index(for: page)
        guard pageIndex >= 0 else { return nil }

        if !hasVisibleViewport {
            return pageCenterSnapshot(pageIndex: pageIndex, page: page)
        }

        readerView.layoutDocumentView()
        let viewportCenter = NSPoint(x: readerView.bounds.midX, y: readerView.bounds.midY)
        let centerPage = readerView.page(for: viewportCenter, nearest: false) ?? page
        let centerPageIndex = initialDocument.index(for: centerPage)
        guard centerPageIndex >= 0 else { return nil }
        return NavigationSnapshot(
            pageIndex: centerPageIndex,
            pageSpacePoint: readerView.convert(viewportCenter, to: centerPage)
        )
    }
    func setNavigationSnapshotCaptureOverride(_ capture: (() -> NavigationSnapshot?)?) {
        navigationSnapshotCaptureOverride = capture
    }


    func navigationSnapshot(forInternalLink target: ReaderLinkTarget) -> NavigationSnapshot? {
        guard case let .goTo(pageIndex, point) = target,
              let page = initialDocument.page(at: pageIndex)
        else { return nil }
        if viewMode == .fitPage {
            return pageCenterSnapshot(pageIndex: pageIndex, page: page)
        }
        guard let point else { return pageCenterSnapshot(pageIndex: pageIndex, page: page) }
        guard page.bounds(for: .mediaBox).contains(point) else { return nil }
        return NavigationSnapshot(pageIndex: pageIndex, pageSpacePoint: point)
    }

    @discardableResult
    func restoreNavigationSnapshot(_ destination: NavigationSnapshot) -> NavigationRestoreOutcome {
        loadViewIfNeeded()
        guard let targetPage = page(for: destination), let origin = captureNavigationSnapshot() else {
            return .preflightRejected
        }
        moveAnchorToViewportCenter(destination, on: targetPage)
        if captureNavigationSnapshot()?.isSameLocation(as: destination) == true {
            return .verifiedLanding
        }
        guard let originPage = page(for: origin) else {
            return .uncompensatedInvariantFailure(actualLanding: captureNavigationSnapshot())
        }
        moveAnchorToViewportCenter(origin, on: originPage)
        return captureNavigationSnapshot()?.isSameLocation(as: origin) == true
            ? .compensatedFailure
            : .uncompensatedInvariantFailure(actualLanding: captureNavigationSnapshot())
    }

    var isDocumentAttached: Bool {
        loadViewIfNeeded()
        return readerView.document === initialDocument
    }

    @discardableResult
    func goToPage(_ oneBasedPage: Int) -> Bool {
        guard oneBasedPage >= 1,
              oneBasedPage <= initialDocument.pageCount,
              let page = initialDocument.page(at: oneBasedPage - 1)
        else {
            return false
        }
        loadViewIfNeeded()
        supersedePendingInitialPresentation()
        readerView.go(to: page)
        readerView.layoutDocumentView()
        return true
    }

    func scrollBy(xPoints: Double, yPoints: Double) {
        loadViewIfNeeded()
        supersedePendingInitialPresentation()
        readerView.scrollBy(xPoints: xPoints, yPoints: yPoints)
    }

    @discardableResult
    func scrollVertically(byPoints points: Double) -> ReaderVerticalScrollOutcome {
        loadViewIfNeeded()
        supersedePendingInitialPresentation()
        return readerView.scrollVertically(byPoints: points)
    }

    @discardableResult
    func scrollVerticallyByViewportFraction(_ fraction: Double) -> ReaderVerticalScrollOutcome {
        loadViewIfNeeded()
        supersedePendingInitialPresentation()
        return readerView.scrollVerticallyByViewportFraction(fraction)
    }

    func scrollToVerticalBoundary(_ boundary: ReaderVerticalBoundary) {
        loadViewIfNeeded()
        readerView.layoutDocumentView()
        readerView.scrollToVerticalBoundary(boundary)
    }

    func zoom(by factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        loadViewIfNeeded()
        supersedePendingInitialPresentation()
        readerView.autoScales = false
        viewMode = .manual
        readerView.scaleFactor = min(readerView.maxScaleFactor, max(readerView.minScaleFactor, readerView.scaleFactor * factor))
        readerView.layoutDocumentView()
    }

    func resetZoom() {
        loadViewIfNeeded()
        supersedePendingInitialPresentation()
        readerView.autoScales = false
        readerView.scaleFactor = 1
        viewMode = .actualSize
    }

    func fitWidth() {
        loadViewIfNeeded()
        supersedePendingInitialPresentation()
        readerView.displayMode = .singlePageContinuous
        readerView.autoScales = true
        viewMode = .fitWidth
    }

    func fitPage() {
        loadViewIfNeeded()
        supersedePendingInitialPresentation()
        readerView.displayMode = .singlePage
        readerView.autoScales = true
        readerView.layoutDocumentView()
        viewMode = .fitPage
    }

    func rotateLeft() {
        rotate(byDegrees: -90)
    }

    func rotateRight() {
        rotate(byDegrees: 90)
    }

    /// Seed a duplicate's verified position. Layout applies fit-page before
    /// restoring it, so source zoom and presentation are never copied.
    func seedPresentation(
        _ navigation: NavigationSnapshot,
        onSuccess: @escaping () -> Void,
        onFailure: @escaping () -> Void
    ) {
        guard let page = page(for: navigation),
              page.bounds(for: .mediaBox).contains(navigation.pageSpacePoint)
        else {
            onFailure()
            return
        }
        pendingPresentationNavigation = navigation
        pendingPresentationSuccessHandler = onSuccess
        pendingPresentationFailureHandler = onFailure
        initialPresentationState = .pending
    }

    func clearSelection() {
        loadViewIfNeeded()
        readerView.currentSelection = nil
    }

    func applySearchPalette(_ palette: SearchHighlightPalette) {
        searchPalette = palette
        renderSearchResults()
    }

    func applyCanvasBackground(_ color: NSColor) {
        canvasBackground = color
        readerView.applyCanvasBackground(color)
        if isViewLoaded {
            view.layer?.backgroundColor = color.cgColor
        }
    }

    func applyFocusIndicator(_ color: NSColor) {
        focusIndicator = color
        readerView.applyFocusIndicator(color)
    }

    func detachDelegates() {
        loadViewIfNeeded()
        readerView.internalLinkHandler = nil
        internalLinkHandler = nil
        readerView.delegate = nil
        readerView.keyEventHandler = nil
    }

    func detachDocument() {
        loadViewIfNeeded()
        readerView.prepareForClose()
    }

    func removeContentView() {
        loadViewIfNeeded()
        readerView.removeFromSuperview()
        view.removeFromSuperview()
    }

    private func rotate(byDegrees degrees: Int) {
        loadViewIfNeeded()
        supersedePendingInitialPresentation()
        for index in 0..<initialDocument.pageCount {
            guard let page = initialDocument.page(at: index) else { continue }
            page.rotation = (page.rotation + degrees) % 360
            if page.rotation < 0 {
                page.rotation += 360
            }
        }

        switch viewMode {
        case .fitWidth:
            fitWidth()
        case .fitPage:
            fitPage()
        case .manual, .actualSize:
            readerView.layoutDocumentView()
        }
    }

    private func applyInitialPresentationIfReady() {
        guard initialPresentationState == .pending,
              hasVisibleViewport,
              let firstPage = initialDocument.page(at: 0)
        else { return }

        initialPresentationState = .applying
        readerView.displayMode = .singlePage
        readerView.autoScales = true
        readerView.layoutDocumentView()
        viewMode = .fitPage

        if let navigation = pendingPresentationNavigation,
           let page = page(for: navigation) {
            moveAnchorToViewportCenter(navigation, on: page)
            guard duplicateLandingMatches(navigation, page: page) else {
                pendingPresentationNavigation = nil
                initialPresentationState = .supersededByUser
                let failureHandler = pendingPresentationFailureHandler
                pendingPresentationFailureHandler = nil
                pendingPresentationSuccessHandler = nil
                failureHandler?()
                return
            }
        } else {
            readerView.go(to: firstPage)
            readerView.layoutDocumentView()
        }
        pendingPresentationNavigation = nil
        pendingPresentationFailureHandler = nil
        initialPresentationState = .applied
        let successHandler = pendingPresentationSuccessHandler
        pendingPresentationSuccessHandler = nil
        successHandler?()
    }
    private func supersedePendingInitialPresentation() {
        if initialPresentationState == .pending {
            initialPresentationState = .supersededByUser
        }
    }

    private var hasVisibleViewport: Bool {
        readerView.window != nil && readerView.bounds.width > 1 && readerView.bounds.height > 1
    }

    private func page(for snapshot: NavigationSnapshot) -> PDFPage? {
        guard snapshot.pageIndex < initialDocument.pageCount else { return nil }
        return initialDocument.page(at: snapshot.pageIndex)
    }

    private func pageCenterSnapshot(pageIndex: Int, page: PDFPage) -> NavigationSnapshot? {
        let bounds = page.bounds(for: .mediaBox)
        return NavigationSnapshot(pageIndex: pageIndex, pageSpacePoint: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    private func duplicateLandingMatches(_ snapshot: NavigationSnapshot, page: PDFPage) -> Bool {
        guard let currentPage = readerView.currentPage,
              initialDocument.index(for: currentPage) == snapshot.pageIndex
        else { return false }
        if captureNavigationSnapshot()?.isSameLocation(as: snapshot) == true {
            return true
        }

        let visibleBounds = readerView.bounds
        let pageRect = readerView.convert(page.bounds(for: .mediaBox), from: page)
        let anchor = readerView.convert(snapshot.pageSpacePoint, from: page)
        return visibleBounds.contains(pageRect) && visibleBounds.contains(anchor)
    }

    private func moveAnchorToViewportCenter(_ snapshot: NavigationSnapshot, on page: PDFPage) {
        guard hasVisibleViewport else {
            readerView.go(to: page)
            readerView.layoutDocumentView()
            return
        }
        readerView.go(to: page)
        readerView.layoutDocumentView()
        let viewportCenter = NSPoint(x: readerView.bounds.midX, y: readerView.bounds.midY)
        for _ in 0..<3 {
            let anchorInView = readerView.convert(snapshot.pageSpacePoint, from: page)
            let delta = NSPoint(x: anchorInView.x - viewportCenter.x, y: anchorInView.y - viewportCenter.y)
            if abs(delta.x) <= NavigationSnapshot.locationTolerance / 2,
               abs(delta.y) <= NavigationSnapshot.locationTolerance / 2 {
                break
            }
            readerView.scrollBy(xPoints: Double(delta.x), yPoints: Double(-delta.y))
            readerView.layoutDocumentView()
        }
    }

    private func renderSearchResults(scrollActiveSelection: Bool = true) {
        loadViewIfNeeded()
        for selection in searchSelections {
            selection.color = searchPalette.allResults
        }
        if let activeSearchIndex, searchSelections.indices.contains(activeSearchIndex) {
            let active = searchSelections[activeSearchIndex]
            active.color = searchPalette.activeResult
            readerView.highlightedSelections = searchSelections
            readerView.setCurrentSelection(active, animate: false)
            if scrollActiveSelection { readerView.scrollSelectionToVisible(nil) }
        } else {
            readerView.highlightedSelections = searchSelections.isEmpty ? nil : searchSelections
            readerView.currentSelection = nil
        }
    }
}

extension PDFViewController: ReaderLinkProviding, ReaderPDFViewInternalLinkHandling {
    func readerPDFView(_ view: ReaderPDFView, activateInternalLink target: ReaderLinkTarget) { internalLinkHandler?(target) }
    func linkTargets() -> [RawLink] {
        loadViewIfNeeded(); readerView.layoutDocumentView()
        return readerView.visiblePages.flatMap { page in
            let index = initialDocument.index(for: page)
            return page.annotations.compactMap { (annotation: PDFAnnotation) -> RawLink? in
                guard Self.isLink(annotation), let target = Self.linkTarget(annotation) else { return nil }
                return RawLink(sourcePageIndex: index, pageSpaceBounds: annotation.bounds, target: target)
            }
        }
    }
    func activateLink(_ target: ReaderLinkTarget) { loadViewIfNeeded(); readerView.activate(target) }
    func setInternalLinkHandler(_ handler: ((ReaderLinkTarget) -> Void)?) { internalLinkHandler = handler }
    func linkHintRects(for link: ReaderLink, in coordinateSpace: NSView) -> [NSRect] {
        loadViewIfNeeded(); guard let page = initialDocument.page(at: link.sourcePageIndex) else { return [] }
        return link.rects.map { readerView.convert(readerView.convert($0, from: page), to: coordinateSpace) }
    }
    private static func isLink(_ annotation: PDFAnnotation) -> Bool { annotation.type == "Link" || annotation.action != nil || annotation.url != nil }
    private static func linkTarget(_ annotation: PDFAnnotation) -> ReaderLinkTarget? {
        if let goTo = annotation.action as? PDFActionGoTo { let destination = goTo.destination; guard let page = destination.page, let document = page.document else { return nil }; return .goTo(pageIndex: document.index(for: page), point: destination.point) }
        if let action = annotation.action as? PDFActionURL, let url = action.url { return .url(url.absoluteString) }
        if let url = annotation.url { return .url(url.absoluteString) }
        return nil
    }
}
extension PDFViewController: ReaderSearchResultPresenting {
    @discardableResult
    func presentSearchResults(
        _ selections: [PDFSelection],
        activeIndex: Int?
    ) -> ReaderSearchResultDisplayOutcome {
        if let activeIndex, !selections.indices.contains(activeIndex) { return .failedWithoutMovement }
        let origin = activeIndex == nil ? nil : captureNavigationSnapshot()
        searchSelections = selections
        self.activeSearchIndex = activeIndex
        renderSearchResults()
        guard let origin else {
            return activeIndex == nil ? .displayedSame : .displayedAfterUnverifiedMovement
        }
        guard let landing = captureNavigationSnapshot() else { return .displayedAfterUnverifiedMovement }
        return landing.isSameLocation(as: origin) ? .displayedSame : .displayedDistinct(landing: landing)
    }

    @discardableResult
    func activateSearchResult(at index: Int) -> ReaderSearchResultDisplayOutcome {
        guard searchSelections.indices.contains(index) else { return .failedWithoutMovement }
        let origin = captureNavigationSnapshot()
        if let activeSearchIndex, searchSelections.indices.contains(activeSearchIndex) {
            searchSelections[activeSearchIndex].color = searchPalette.allResults
        }
        let active = searchSelections[index]
        active.color = searchPalette.activeResult
        activeSearchIndex = index
        readerView.setCurrentSelection(active, animate: false)
        readerView.scrollSelectionToVisible(nil)
        guard let origin, let landing = captureNavigationSnapshot() else { return .displayedAfterUnverifiedMovement }
        return landing.isSameLocation(as: origin) ? .displayedSame : .displayedDistinct(landing: landing)
    }
    func restoreSearchResultSelection(at index: Int?) {
        activeSearchIndex = index
        renderSearchResults(scrollActiveSelection: false)
    }

    func clearSearchResults() {
        searchSelections.removeAll(keepingCapacity: false)
        activeSearchIndex = nil
        loadViewIfNeeded()
        readerView.highlightedSelections = nil
        readerView.currentSelection = nil
    }
}
