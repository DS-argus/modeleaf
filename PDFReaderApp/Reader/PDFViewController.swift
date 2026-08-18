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

enum ReaderViewportMutationOrigin: Equatable, Hashable, Sendable {
    case userAction, tocActivation, nativeGesture, system
    var isUserMovement: Bool {
        switch self { case .userAction, .nativeGesture: true; case .tocActivation, .system: false }
    }
}
struct ReaderViewportMutationEpoch: Equatable, Sendable {
    let id: UInt64
    let origin: ReaderViewportMutationOrigin
    let baseline: NavigationSnapshot?
}
enum ReaderViewportMutationTerminal: Equatable, Sendable {
    case changed(ReaderViewportMutationEpoch)
    case noChange(ReaderViewportMutationEpoch)
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
    private var destinationIndicatorAccent: NSColor
    private var pendingPresentationFailureHandler: (() -> Void)?
    private var pendingPresentationSuccessHandler: (() -> Void)?
    private(set) var viewMode: ReaderViewMode = .fitWidth
    private(set) var initialPresentationState: InitialPDFPresentationState = .pending
    private var searchPalette = SearchHighlightPalette.default
    private var searchSelections: [PDFSelection] = []
    private var activeSearchIndex: Int?
    private var internalLinkHandler: ((ReaderLinkTarget) -> Void)?
    private var navigationSnapshotCaptureOverride: (() -> NavigationSnapshot?)?
    private var viewportMutationHandler: ((ReaderViewportMutationTerminal) -> Void)?
    private var activeViewportEpoch: ReaderViewportMutationEpoch?
    private var nextViewportEpochID: UInt64 = 0
    private var cachedPageWidthSummary: PageWidthSummary?
    private var appliedFitWidthViewportWidth: CGFloat?

    private let destinationIndicatorView = LinkDestinationIndicatorView(frame: .zero)
    init(document: PDFDocument, traceID: OpenTraceID, metrics: any PDFOpenMetrics) {
        self.initialDocument = document
        self.openTraceID = traceID
        self.openMetrics = metrics
        self.readerView = ReaderPDFView(frame: .zero)
        let defaultTheme = AppKitTheme(themeID: .tokyoNight)
        self.canvasBackground = defaultTheme.canvasBackground
        self.focusIndicator = defaultTheme.focusRing
        self.destinationIndicatorAccent = defaultTheme[.accent]
        super.init(nibName: nil, bundle: nil)
        readerView.viewportGestureHandler = { [weak self] event in self?.handleNativeViewportGesture(event) }
        readerView.applyCanvasBackground(canvasBackground)
        readerView.applyFocusIndicator(focusIndicator)
        destinationIndicatorView.configure(
            .standard,
            accentColor: defaultTheme[.accent],
            backgroundColor: defaultTheme.canvasBackground
        )
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
        destinationIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(readerView)
        container.addSubview(destinationIndicatorView)
        NSLayoutConstraint.activate([
            readerView.topAnchor.constraint(equalTo: container.topAnchor),
            readerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            readerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            readerView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            destinationIndicatorView.topAnchor.constraint(equalTo: container.topAnchor),
            destinationIndicatorView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            destinationIndicatorView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            destinationIndicatorView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        readerView.displayMode = .singlePageContinuous
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
        if destinationIndicatorView.isVisible { destinationIndicatorView.cancel() }
        applyInitialPresentationIfReady()
        refitContinuousWidthForViewportChange()
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
        let centerPage = readerView.page(for: viewportCenter, nearest: true) ?? page
        let centerPageIndex = initialDocument.index(for: centerPage)
        guard centerPageIndex >= 0 else { return nil }
        let pageBounds = centerPage.bounds(for: .mediaBox)
        let convertedPoint = readerView.convert(viewportCenter, to: centerPage)
        let boundedPoint = CGPoint(
            x: min(max(convertedPoint.x, pageBounds.minX), pageBounds.maxX),
            y: min(max(convertedPoint.y, pageBounds.minY), pageBounds.maxY)
        )
        return NavigationSnapshot(pageIndex: centerPageIndex, pageSpacePoint: boundedPoint)
    }
    func setNavigationSnapshotCaptureOverride(_ capture: (() -> NavigationSnapshot?)?) {
        navigationSnapshotCaptureOverride = capture
    }

    func navigationSnapshot(forOutlineDestination destination: PDFDestination) -> NavigationSnapshot? {
        guard let page = destination.page, page.document === initialDocument else { return nil }
        let pageIndex = initialDocument.index(for: page)
        guard pageIndex >= 0, pageIndex < initialDocument.pageCount else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.minX.isFinite, bounds.maxX.isFinite, bounds.minY.isFinite, bounds.maxY.isFinite,
              let x = normalizedOutlineCoordinate(destination.point.x, lower: bounds.minX, upper: bounds.maxX),
              let y = normalizedOutlineCoordinate(destination.point.y, lower: bounds.minY, upper: bounds.maxY) else { return nil }
        return NavigationSnapshot(pageIndex: pageIndex, pageSpacePoint: CGPoint(x: x, y: y))
    }

    func navigationSnapshot(forInternalLink target: ReaderLinkTarget) -> NavigationSnapshot? {
        guard case let .goTo(pageIndex, point) = target,
              let page = initialDocument.page(at: pageIndex)
        else { return nil }
        if viewMode == .fitPage { return pageCenterSnapshot(pageIndex: pageIndex, page: page) }

        let bounds = page.bounds(for: .mediaBox)
        guard let point else { return pageCenterSnapshot(pageIndex: pageIndex, page: page) }
        let restorableBounds = bounds.width > 2 && bounds.height > 2
            ? bounds.insetBy(dx: 1, dy: 1)
            : bounds
        let x = Self.isSpecifiedDestinationCoordinate(point.x)
            ? min(max(point.x, restorableBounds.minX), restorableBounds.maxX)
            : restorableBounds.midX
        let y = Self.isSpecifiedDestinationCoordinate(point.y)
            ? min(max(point.y, restorableBounds.minY), restorableBounds.maxY)
            : restorableBounds.midY
        return NavigationSnapshot(pageIndex: pageIndex, pageSpacePoint: CGPoint(x: x, y: y))
    }

    @discardableResult
    func restoreNavigationSnapshot(_ destination: NavigationSnapshot) -> NavigationRestoreOutcome {
        loadViewIfNeeded()
        destinationIndicatorView.cancel()
        guard let targetPage = page(for: destination) else { return .preflightRejected }
        let targetBounds = targetPage.bounds(for: .mediaBox)
        let targetPoint = destination.pageSpacePoint
        guard targetPoint.x.isFinite, targetPoint.y.isFinite,
              targetPoint.x >= targetBounds.minX, targetPoint.x <= targetBounds.maxX,
              targetPoint.y >= targetBounds.minY, targetPoint.y <= targetBounds.maxY,
              let origin = captureNavigationSnapshot()
        else { return .preflightRejected }

        let destinationMove = moveAnchorToViewportCenter(destination, on: targetPage)
        if verifiedLanding(destinationMove, requested: destination) { return .verifiedLanding }

        guard let originPage = page(for: origin) else {
            return .uncompensatedInvariantFailure(actualLanding: destinationMove.landing)
        }
        let compensation = moveAnchorToViewportCenter(origin, on: originPage)
        return verifiedLanding(compensation, requested: origin)
            ? .compensatedFailure
            : .uncompensatedInvariantFailure(actualLanding: compensation.landing)
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
        readerView.centerHorizontallyIfPageFits(page)
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
        destinationIndicatorView.cancel()
        readerView.layoutDocumentView()
        readerView.scrollToVerticalBoundary(boundary)
    }

    func zoom(by factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        loadViewIfNeeded()
        supersedePendingInitialPresentation()

        let fitPageAnchor = viewMode == .fitPage ? captureNavigationSnapshot() : nil
        let targetScale = min(
            readerView.maxScaleFactor,
            max(readerView.minScaleFactor, readerView.scaleFactor * factor)
        )
        if viewMode == .fitPage {
            readerView.displayMode = .singlePageContinuous
        }
        readerView.autoScales = false
        viewMode = .manual
        appliedFitWidthViewportWidth = nil
        readerView.scaleFactor = targetScale
        readerView.layoutDocumentView()

        if let fitPageAnchor, let page = page(for: fitPageAnchor) {
            moveAnchorToViewportCenter(fitPageAnchor, on: page)
        }
    }

    func resetZoom() {
        loadViewIfNeeded()
        supersedePendingInitialPresentation()
        readerView.autoScales = false
        readerView.scaleFactor = 1
        viewMode = .actualSize
        appliedFitWidthViewportWidth = nil
    }

    func fitWidth() {
        loadViewIfNeeded()
        supersedePendingInitialPresentation()
        readerView.displayMode = .singlePageContinuous
        applyContinuousWidthFit()
        viewMode = .fitWidth
    }

    func fitPage() {
        loadViewIfNeeded()
        supersedePendingInitialPresentation()
        appliedFitWidthViewportWidth = nil
        readerView.displayMode = .singlePage
        readerView.autoScales = true
        readerView.layoutDocumentView()
        viewMode = .fitPage
    }

    /// Fits the width the document is actually read at.
    ///
    /// PDFKit's auto-scaling fits the widest page, which is correct only while
    /// every page shares that width. One oversized page would otherwise shrink
    /// every ordinary page, so documents that mix page sizes get an explicit
    /// scale derived from the width most of their pages share.
    private func applyContinuousWidthFit() {
        guard let summary = pageWidthSummary,
              !summary.isUniform,
              let scale = readerView.scaleFactorFittingWidth(summary.representative)
        else {
            appliedFitWidthViewportWidth = nil
            readerView.autoScales = true
            readerView.layoutDocumentView()
            centerCurrentPageHorizontally()
            return
        }
        readerView.autoScales = false
        readerView.scaleFactor = scale
        readerView.layoutDocumentView()
        appliedFitWidthViewportWidth = readerView.bounds.width
        centerCurrentPageHorizontally()
    }

    /// An explicit fit-width scale does not track the viewport the way PDFKit's
    /// auto-scaling does, so it is recomputed whenever the viewport width changes.
    private func refitContinuousWidthForViewportChange() {
        guard viewMode == .fitWidth, let applied = appliedFitWidthViewportWidth else { return }
        let width = readerView.bounds.width
        guard width > 1, abs(width - applied) > 0.5 else { return }
        let anchor = captureNavigationSnapshot()
        applyContinuousWidthFit()
        guard let anchor, let page = page(for: anchor) else { return }
        moveAnchorToViewportCenter(anchor, on: page)
    }

    private func centerCurrentPageHorizontally() {
        guard let page = readerView.currentPage else { return }
        readerView.centerHorizontallyIfPageFits(page)
    }

    private var pageWidthSummary: PageWidthSummary? {
        if let cachedPageWidthSummary { return cachedPageWidthSummary }
        var widths: [CGFloat] = []
        widths.reserveCapacity(initialDocument.pageCount)
        for index in 0..<initialDocument.pageCount {
            guard let page = initialDocument.page(at: index) else { continue }
            let bounds = page.bounds(for: .cropBox)
            let isQuarterTurned = abs(page.rotation) % 180 == 90
            widths.append(isQuarterTurned ? bounds.height : bounds.width)
        }
        cachedPageWidthSummary = PageWidthMetrics.summary(of: widths)
        return cachedPageWidthSummary
    }

    func rotateLeft() {
        rotate(byDegrees: -90)
    }

    func rotateRight() {
        rotate(byDegrees: 90)
    }

    @discardableResult
    func printDocument() -> Bool {
        loadViewIfNeeded()
        guard readerView.document === initialDocument,
              let operation = initialDocument.printOperation(
                  for: NSPrintInfo.shared,
                  scalingMode: .pageScaleToFit,
                  autoRotate: true
              )
        else { return false }
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return operation.run()
    }

    /// Seed a duplicate's verified position. Layout applies fit-page before restoring it,
    /// so source zoom and presentation are never copied.
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
        if isViewLoaded { view.layer?.backgroundColor = color.cgColor }
        destinationIndicatorView.applyAppearance(accentColor: destinationIndicatorAccent, backgroundColor: color)
    }

    func applyFocusIndicator(_ color: NSColor) {
        focusIndicator = color
        readerView.applyFocusIndicator(color)
    }

    func applyDestinationIndicatorSettings(_ configuration: LinkDestinationIndicatorSettings) {
        destinationIndicatorView.configure(configuration)
    }

    func applyDestinationIndicatorAppearance(accentColor: NSColor, backgroundColor: NSColor) {
        destinationIndicatorAccent = accentColor
        destinationIndicatorView.applyAppearance(accentColor: accentColor, backgroundColor: backgroundColor)
    }


    func destinationIndicatorSnapshot(for target: ReaderLinkTarget) -> NavigationSnapshot? {
        guard case let .goTo(pageIndex, point?) = target,
              initialDocument.page(at: pageIndex) != nil
        else { return nil }
        guard Self.isSpecifiedDestinationCoordinate(point.x),
              Self.isSpecifiedDestinationCoordinate(point.y)
        else { return nil }
        return NavigationSnapshot(pageIndex: pageIndex, pageSpacePoint: point)
    }

    func presentDestinationIndicator(at destination: NavigationSnapshot) {
        loadViewIfNeeded()
        readerView.layoutDocumentView()
        guard let page = initialDocument.page(at: destination.pageIndex) else { return }
        let readerPoint = readerView.convert(destination.pageSpacePoint, from: page)
        let indicatorPoint = readerView.convert(readerPoint, to: destinationIndicatorView)
        guard indicatorPoint.x.isFinite, indicatorPoint.y.isFinite,
              destinationIndicatorView.bounds.contains(indicatorPoint)
        else { return }
        destinationIndicatorView.present(at: indicatorPoint)
    }

    func cancelDestinationIndicator() {
        destinationIndicatorView.cancel()
    }

    var destinationIndicatorVisibleForTesting: Bool { destinationIndicatorView.isVisible }
    var destinationIndicatorCenterForTesting: CGPoint? { destinationIndicatorView.indicatorCenter }
    var destinationIndicatorGenerationForTesting: Int { destinationIndicatorView.generation }

    func detachDelegates() {
        loadViewIfNeeded()
        readerView.internalLinkHandler = nil
        internalLinkHandler = nil
        readerView.viewportGestureHandler = nil
        activeViewportEpoch = nil
        readerView.delegate = nil
        readerView.keyEventHandler = nil
    }

    func detachDocument() {
        loadViewIfNeeded()
        destinationIndicatorView.cancel()
        readerView.prepareForClose()
    }

    func removeContentView() {
        loadViewIfNeeded()
        readerView.removeFromSuperview()
        view.removeFromSuperview()
    }

    func setViewportMutationHandler(_ handler: ((ReaderViewportMutationTerminal) -> Void)?) { viewportMutationHandler = handler }

    @discardableResult
    func beginViewportMutation(_ origin: ReaderViewportMutationOrigin) -> ReaderViewportMutationEpoch {
        finishActiveViewportEpoch()
        let epoch = ReaderViewportMutationEpoch(id: nextViewportEpochID, origin: origin, baseline: captureNavigationSnapshot())
        nextViewportEpochID &+= 1
        activeViewportEpoch = epoch
        return epoch
    }

    func finishViewportMutation(_ epoch: ReaderViewportMutationEpoch) {
        guard activeViewportEpoch == epoch else { return }
        finishActiveViewportEpoch()
    }

    func performViewportMutation(origin: ReaderViewportMutationOrigin, _ operation: () -> Void) {
        let epoch = beginViewportMutation(origin)
        defer { finishViewportMutation(epoch) }
        operation()
    }

    func performUserViewportMutation(_ operation: () -> Void) {
        performViewportMutation(origin: .userAction, operation)
    }

    private func handleNativeViewportGesture(_ event: ReaderNativeViewportGesture) {
        switch event {
        case .began:
            _ = beginViewportMutation(.nativeGesture)
        case .ended, .cancelled:
            finishActiveViewportEpoch()
        }
    }

    private func finishActiveViewportEpoch() {
        guard let epoch = activeViewportEpoch else { return }
        activeViewportEpoch = nil
        readerView.layoutDocumentView()
        let landing = captureNavigationSnapshot()
        let terminal: ReaderViewportMutationTerminal
        if let baseline = epoch.baseline, let landing, !landing.isSameLocation(as: baseline) { terminal = .changed(epoch) }
        else { terminal = .noChange(epoch) }
        viewportMutationHandler?(terminal)
    }

    private func rotate(byDegrees degrees: Int) {
        loadViewIfNeeded()
        supersedePendingInitialPresentation()
        for index in 0..<initialDocument.pageCount {
            guard let page = initialDocument.page(at: index) else { continue }
            page.rotation = (page.rotation + degrees) % 360
            if page.rotation < 0 { page.rotation += 360 }
        }
        cachedPageWidthSummary = nil
        switch viewMode {
        case .fitWidth: fitWidth()
        case .fitPage: fitPage()
        case .manual, .actualSize: readerView.layoutDocumentView()
        }
    }

    private func applyInitialPresentationIfReady() {
        guard initialPresentationState == .pending,
              hasVisibleViewport,
              let firstPage = initialDocument.page(at: 0)
        else { return }
        initialPresentationState = .applying
        let navigation = pendingPresentationNavigation
        let success = pendingPresentationSuccessHandler
        let failure = pendingPresentationFailureHandler
        pendingPresentationNavigation = nil
        pendingPresentationSuccessHandler = nil
        pendingPresentationFailureHandler = nil

        if let navigation, let page = page(for: navigation) {
            readerView.displayMode = .singlePage
            readerView.autoScales = true
            readerView.layoutDocumentView()
            viewMode = .fitPage
            moveAnchorToViewportCenter(navigation, on: page)
            guard duplicateLandingMatches(navigation, page: page) else {
                initialPresentationState = .supersededByUser
                failure?()
                return
            }
        } else {
            readerView.displayMode = .singlePageContinuous
            applyContinuousWidthFit()
            viewMode = .fitWidth
            readerView.go(to: firstPage)
            readerView.layoutDocumentView()
            readerView.centerHorizontallyIfPageFits(firstPage)
        }
        initialPresentationState = .applied
        success?()
    }

    private func supersedePendingInitialPresentation() {
        destinationIndicatorView.cancel()
        guard initialPresentationState == .pending else { return }
        let failure = pendingPresentationFailureHandler
        pendingPresentationNavigation = nil
        pendingPresentationSuccessHandler = nil
        pendingPresentationFailureHandler = nil
        initialPresentationState = .supersededByUser
        failure?()
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

    private struct AnchorMoveResult {
        let landing: NavigationSnapshot?
        let wasConstrained: Bool
        /// Whether the horizontal position was decided by the layout rule rather
        /// than by the requested anchor.
        let horizontalWasNormalized: Bool
    }
    @discardableResult
    private func moveAnchorToViewportCenter(_ snapshot: NavigationSnapshot, on page: PDFPage) -> AnchorMoveResult {
        readerView.go(to: page)
        readerView.layoutDocumentView()
        guard hasVisibleViewport else {
            return AnchorMoveResult(
                landing: captureNavigationSnapshot(),
                wasConstrained: false,
                horizontalWasNormalized: false
            )
        }
        let wasConstrained = readerView.centerPagePoint(snapshot.pageSpacePoint, on: page) ?? false
        let horizontalWasNormalized = readerView.centerHorizontallyIfPageFits(page)
        return AnchorMoveResult(
            landing: captureNavigationSnapshot(),
            wasConstrained: wasConstrained,
            horizontalWasNormalized: horizontalWasNormalized
        )
    }

    private func verifiedLanding(_ movement: AnchorMoveResult, requested: NavigationSnapshot) -> Bool {
        guard let landing = movement.landing, landing.pageIndex == requested.pageIndex else { return false }
        if landing.isSameLocation(as: requested) || movement.wasConstrained { return true }
        // A page that fits the viewport is centred horizontally by layout, so only
        // the vertical anchor is the caller's to request.
        guard movement.horizontalWasNormalized else { return false }
        return abs(landing.pageSpacePoint.y - requested.pageSpacePoint.y)
            <= NavigationSnapshot.locationTolerance + 1e-9
    }


    private static func isSpecifiedDestinationCoordinate(_ value: CGFloat) -> Bool {
        let sentinelThreshold = CGFloat(Float.greatestFiniteMagnitude) / 2
        return value.isFinite && abs(value) < sentinelThreshold
    }
    private func normalizedOutlineCoordinate(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat? {
        guard value.isFinite else { return nil }
        guard Self.isSpecifiedDestinationCoordinate(value) else { return (lower + upper) / 2 }
        let tolerance: CGFloat = 8
        guard value >= lower - tolerance, value <= upper + tolerance else { return nil }
        return min(max(value, lower), upper)
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
            if scrollActiveSelection {
                readerView.scrollSelectionToVisible(nil)
                centerHorizontallyForSelection(active)
            }
        } else {
            readerView.highlightedSelections = searchSelections.isEmpty ? nil : searchSelections
            readerView.currentSelection = nil
        }
    }

    /// Leaves a found page where every other jump leaves it. PDFKit scrolls only
    /// far enough to expose the selection, which leaves a page narrower than the
    /// continuous layout off centre.
    private func centerHorizontallyForSelection(_ selection: PDFSelection) {
        guard let page = selection.pages.first else { return }
        readerView.centerHorizontallyIfPageFits(page)
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
        loadViewIfNeeded()
        guard let page = initialDocument.page(at: link.sourcePageIndex) else { return [] }
        return link.rects.compactMap { pageRect in
            let overlayRect = readerView.convert(readerView.convert(pageRect, from: page), to: coordinateSpace)
            let clipped = overlayRect.intersection(coordinateSpace.bounds)
            return clipped.isNull || clipped.width <= 0 || clipped.height <= 0 ? nil : clipped
        }
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
        if let activeIndex {
            performUserViewportMutation {
                searchSelections = selections
                self.activeSearchIndex = activeIndex
                renderSearchResults()
            }
        } else {
            searchSelections = selections
            self.activeSearchIndex = nil
            renderSearchResults(scrollActiveSelection: false)
        }
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
        performUserViewportMutation {
            if let activeSearchIndex, searchSelections.indices.contains(activeSearchIndex) { searchSelections[activeSearchIndex].color = searchPalette.allResults }
            let active = searchSelections[index]
            active.color = searchPalette.activeResult
            activeSearchIndex = index
            readerView.setCurrentSelection(active, animate: false)
            readerView.scrollSelectionToVisible(nil)
            centerHorizontallyForSelection(active)
        }
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
