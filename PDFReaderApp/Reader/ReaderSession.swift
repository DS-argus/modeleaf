import AppKit
import PDFKit
import PDFReaderCore

enum ReaderTeardownStep: String, Equatable, Sendable {
    case searchCancellationRequested
    case callbacksAndDelegatesDetached
    case notificationsDetached
    case selectionAndHighlightsCleared
    case documentDetached
    case contentViewRemoved
}

enum ReaderSessionCloseReason: Equatable, Sendable {
    case userClose
    case insertionRejected

    var metricOutcome: PDFOpenMetricOutcome {
        switch self {
        case .userClose:
            .userClose
        case .insertionRejected:
            .insertionRejected
        }
    }
}


enum MeaningfulJumpProducer: Equatable, Sendable {
    case pagePrompt
    case firstPage
    case lastPage
    case searchResult
    case internalLink
    case toc
}

enum NavigationTransactionRequest: Equatable, Sendable {
    case meaningfulJump(producer: MeaningfulJumpProducer, destination: NavigationSnapshot)
    case back
    case forward
}

enum NavigationTransactionOutcome: Equatable, Sendable {
    case preflightRejected
    case verifiedLanding
    case compensatedFailure
    case uncompensatedInvariantFailure(actualLanding: NavigationSnapshot?)
    case unavailable
    case noOp
}

enum SearchNavigationActivationOutcome: Equatable, Sendable {
    case armed
    case retagged
    case preflightRejected
    case ignored
    case firstCommitted
    case coalesced
}

private enum DuplicateValidationState {
    case pending
    case succeeded
    case failed
}

@MainActor
protocol ReaderSearchLifecycle: AnyObject {
    func requestCancellation()
    func detachCallbacks()
    func clearHighlights()
}

@MainActor
final class ReaderSession: NSObject, ReaderSessionPresenting {
    let id: TabID
    let title: String
    let sourceURL: URL

    private let document: PDFDocument
    private let viewController: PDFViewController
    private let searchLifecycle: any ReaderSearchLifecycle
    private let searchController: (any ReaderSearchControlling)?
    private let openTraceID: OpenTraceID
    private let navigationCapture: () -> NavigationSnapshot?
    private var duplicateValidationState: DuplicateValidationState = .pending
    private var duplicateValidationHandler: ((Bool) -> Void)?
    private let navigationRestore: (NavigationSnapshot) -> NavigationRestoreOutcome
    private var duplicateValidationDelivered = false
    private let openMetrics: any PDFOpenMetrics
    private var cachedSearchableTextPresence: Bool?
    private var notificationTokens: [NSObjectProtocol] = []
    private var presentationChangeHandler: (() -> Void)?
    private var navigationHistory = NavigationHistory()
    private var searchEpoch: SearchEpoch = .idle
    private(set) var isNavigationHistoryHealthy = true

    private(set) var completedTeardownSteps: [ReaderTeardownStep] = []
    private(set) var isClosed = false

    init(
        id: TabID = TabID(),
        sourceURL: URL,
        document: PDFDocument,
        searchLifecycle: (any ReaderSearchLifecycle)? = nil,
        traceID: OpenTraceID = OpenTraceID(),
        metrics: any PDFOpenMetrics = NoopPDFOpenMetrics(),
        navigationCapture: (() -> NavigationSnapshot?)? = nil,
        navigationRestore: ((NavigationSnapshot) -> NavigationRestoreOutcome)? = nil
    ) {
        metrics.record(.begin(.sessionConstruct, traceID: traceID))
        self.id = id
        self.sourceURL = sourceURL
        self.title = sourceURL.lastPathComponent.isEmpty ? "Untitled.pdf" : sourceURL.lastPathComponent
        self.document = document
        self.openTraceID = traceID
        self.openMetrics = metrics
        let viewController = PDFViewController(document: document, traceID: traceID, metrics: metrics)
        self.viewController = viewController
        self.navigationCapture = navigationCapture ?? { viewController.captureNavigationSnapshot() }
        self.navigationRestore = navigationRestore ?? { viewController.restoreNavigationSnapshot($0) }
        if let searchLifecycle {
            self.searchLifecycle = searchLifecycle
            self.searchController = searchLifecycle as? any ReaderSearchControlling
        } else {
            let coordinator = ReaderSearchCoordinator(driver: PDFKitSearchDriver(document: document), presenter: viewController)
            self.searchLifecycle = coordinator
            self.searchController = coordinator
        }
        super.init()
        searchController?.setChangeHandler { [weak self] in self?.publishPresentationChange() }
        installNotifications()
        metrics.record(.end(.sessionConstruct, traceID: traceID, outcome: .success))
    }
    var navigationAvailabilityDetail: String {
        isNavigationHistoryHealthy ? "History available" : "Navigation history unavailable"
    }

    var canGoBack: Bool { isNavigationHistoryHealthy && navigationHistory.canGoBack }
    var canGoForward: Bool { isNavigationHistoryHealthy && navigationHistory.canGoForward }

    @discardableResult
    func goBack() -> NavigationTransactionOutcome {
        performNavigation(.back)
    }

    @discardableResult
    func goForward() -> NavigationTransactionOutcome {
        performNavigation(.forward)
    }

    @discardableResult
    func performNavigation(_ request: NavigationTransactionRequest) -> NavigationTransactionOutcome {
        guard !isClosed, isNavigationHistoryHealthy else { return .unavailable }
        switch request {
        case let .meaningfulJump(producer, destination):
            guard producer != .searchResult else { return .preflightRejected }
            return performMeaningfulJump(producer: producer, destination: destination)
        case .back:
            return performTraversal(backward: true)
        case .forward:
            return performTraversal(backward: false)
        }
    }

    @discardableResult
    func activateSearchNavigation(searchGeneration: Int) -> SearchNavigationActivationOutcome {
        guard !isClosed, isNavigationHistoryHealthy else { return .preflightRejected }
        guard searchEpoch == .idle else {
            searchEpoch.replaceQuery(searchGeneration: searchGeneration)
            return .retagged
        }
        guard let origin = captureNavigation() else { return .preflightRejected }
        searchEpoch.arm(origin: origin, searchGeneration: searchGeneration)
        return .armed
    }

    /// PR-C calls this only after it has visibly landed a search result.
    @discardableResult
    func recordVerifiedSearchLanding(searchGeneration: Int) -> SearchNavigationActivationOutcome {
        guard !isClosed, isNavigationHistoryHealthy,
              let landing = captureNavigation()
        else { return .preflightRejected }
        switch searchEpoch.inspectDisplayedDistinct(searchGeneration: searchGeneration) {
        case let .first(origin):
            guard navigationHistory.commitMeaningfulJump(origin: origin, landing: landing) else { return .ignored }
            _ = searchEpoch.commitFirstDisplayedDistinct(searchGeneration: searchGeneration, historyCommitted: true)
            publishPresentationChange()
            return .firstCommitted
        case .coalesced:
            return .coalesced
        case .ignored:
            return .ignored
        }
    }

    var contentView: NSView { viewController.view }
    var focusView: NSView { viewController.focusView }
    var pageCount: Int { viewController.pageCount }
    var currentPageNumber: Int? { viewController.currentPageNumber }
    var scaleFactor: Double { Double(viewController.scaleFactor) }
    var viewMode: ReaderViewMode { viewController.viewMode }
    var initialPresentationState: InitialPDFPresentationState {
        viewController.initialPresentationState
    }
    var searchSnapshot: ReaderSearchSnapshot {
        var snapshot = searchController?.snapshot ?? .empty
        if snapshot.isActive, !snapshot.isRunning, snapshot.matchCount == 0 {
            let hasSearchableText = cachedSearchableTextPresence ?? documentContainsSearchableText()
            cachedSearchableTextPresence = hasSearchableText
            snapshot.emptyResult = hasSearchableText ? .noMatch : .noSearchableText
        }
        return snapshot
    }
    var preferredInputContext: InputContext { searchSnapshot.isActive ? .searchResults : .navigation }

    var statusSnapshot: ReaderStatusSnapshot {
        let page = currentPageNumber.map(String.init) ?? "—"
        let zoom = Int((scaleFactor * 100).rounded())
        return ReaderStatusSnapshot(context: preferredInputContext == .searchResults ? "SEARCH" : "NORMAL", page: "\(page) / \(pageCount)", zoom: "\(zoom)%", detail: searchDetail)
    }
    func configureDuplicateValidation(_ handler: @escaping (Bool) -> Void) {
        guard !duplicateValidationDelivered else { return }
        switch duplicateValidationState {
        case .pending:
            duplicateValidationHandler = handler
        case .succeeded:
            duplicateValidationDelivered = true
            handler(true)
        case .failed:
            duplicateValidationDelivered = true
            handler(false)
        }
    }

    private func resolveDuplicateValidation(_ success: Bool) {
        guard case .pending = duplicateValidationState else { return }
        duplicateValidationState = success ? .succeeded : .failed
        guard let handler = duplicateValidationHandler else { return }
        duplicateValidationHandler = nil
        duplicateValidationDelivered = true
        handler(success)
    }

    func setPresentationChangeHandler(_ handler: (() -> Void)?) {
        presentationChangeHandler = handler
    }

    @discardableResult
    func goToPage(_ oneBasedPage: Int) -> Bool {
        guard let destination = viewController.navigationSnapshot(forPageNumber: oneBasedPage) else { return false }
        let outcome = performNavigation(.meaningfulJump(producer: .pagePrompt, destination: destination))
        return outcome == .verifiedLanding || outcome == .noOp
    }

    @discardableResult
    func goToNextPage() -> Bool {
        guard !isClosed, let currentPageNumber, currentPageNumber < pageCount else { return false }
        return performUnrecordedPageMove(currentPageNumber + 1)
    }

    @discardableResult
    func goToPreviousPage() -> Bool {
        guard !isClosed, let currentPageNumber, currentPageNumber > 1 else { return false }
        return performUnrecordedPageMove(currentPageNumber - 1)
    }

    @discardableResult
    func goToFirstPage() -> Bool {
        guard let destination = viewController.navigationSnapshot(forPageNumber: 1) else { return false }
        let outcome = performNavigation(.meaningfulJump(producer: .firstPage, destination: destination))
        return outcome == .verifiedLanding || outcome == .noOp
    }

    @discardableResult
    func goToLastPage() -> Bool {
        guard let destination = viewController.navigationSnapshot(forPageNumber: pageCount) else { return false }
        let outcome = performNavigation(.meaningfulJump(producer: .lastPage, destination: destination))
        return outcome == .verifiedLanding || outcome == .noOp
    }

    func scrollBy(xPoints: Double, yPoints: Double) {
        guard !isClosed else { return }
        viewController.scrollBy(xPoints: xPoints, yPoints: yPoints)
    }

    func scrollVerticallyByViewportFraction(_ fraction: Double) {
        guard !isClosed else { return }
        viewController.scrollVerticallyByViewportFraction(fraction)
    }

    func moveHorizontally(byPoints points: Double) {
        guard !isClosed else { return }
        viewController.scrollBy(xPoints: points, yPoints: 0)
    }

    func moveVertically(byPoints points: Double) {
        guard !isClosed, points != 0 else { return }
        if viewMode == .fitPage {
            _ = points > 0 ? goToNextPage() : goToPreviousPage()
            return
        }

        let outcome = viewController.scrollVertically(byPoints: points)
        if viewController.usesSinglePageLayout, outcome == .atBoundary {
            navigateAcrossVerticalBoundary(forward: points > 0)
        }
    }

    func moveVertically(byViewportFraction fraction: Double) {
        guard !isClosed, fraction != 0 else { return }
        if viewMode == .fitPage {
            _ = fraction > 0 ? goToNextPage() : goToPreviousPage()
            return
        }

        let outcome = viewController.scrollVerticallyByViewportFraction(fraction)
        if viewController.usesSinglePageLayout, outcome == .atBoundary {
            navigateAcrossVerticalBoundary(forward: fraction > 0)
        }
    }

    func zoom(by factor: Double) {
        guard !isClosed else { return }
        viewController.zoom(by: factor)
        publishPresentationChange()
    }

    func resetZoom() {
        guard !isClosed else { return }
        viewController.resetZoom()
        publishPresentationChange()
    }

    func fitWidth() {
        guard !isClosed else { return }
        viewController.fitWidth()
        publishPresentationChange()
    }

    func fitPage() {
        guard !isClosed else { return }
        viewController.fitPage()
        publishPresentationChange()
    }

    func rotateLeft() {
        guard !isClosed else { return }
        viewController.rotateLeft()
        publishPresentationChange()
    }

    func rotateRight() {
        guard !isClosed else { return }
        viewController.rotateRight()
        publishPresentationChange()
    }

    private func navigateAcrossVerticalBoundary(forward: Bool) {
        if forward {
            guard goToNextPage() else { return }
            viewController.scrollToVerticalBoundary(.start)
        } else {
            guard goToPreviousPage() else { return }
            viewController.scrollToVerticalBoundary(.end)
        }
    }

    private func performUnrecordedPageMove(_ oneBasedPage: Int) -> Bool {
        guard viewController.goToPage(oneBasedPage) else { return false }
        searchEpoch.excludedMovementOrTabSwitch()
        publishPresentationChange()
        return true
    }

    private func performMeaningfulJump(producer: MeaningfulJumpProducer, destination: NavigationSnapshot) -> NavigationTransactionOutcome {
        guard producer != .searchResult, let origin = captureNavigation() else { return .preflightRejected }
        guard !origin.isSameLocation(as: destination) else {
            searchEpoch.failedOrSameNonSearchAttempt()
            return .noOp
        }
        let restoration = restoreNavigation(destination)
        guard restoration == .verifiedLanding else { return handleRestorationFailure(restoration) }
        guard let actualLanding = captureNavigation() else {
            return disableHistory(actualLanding: nil)
        }
        guard navigationHistory.commitMeaningfulJump(origin: origin, landing: actualLanding) else { return .noOp }
        searchEpoch.successfulNonSearchJump()
        publishPresentationChange()
        return .verifiedLanding
    }

    private func performTraversal(backward: Bool) -> NavigationTransactionOutcome {
        let destination = backward ? navigationHistory.backDestination : navigationHistory.forwardDestination
        guard let destination else { searchEpoch.failedOrEmptyTraversal(); return .unavailable }
        guard let current = captureNavigation() else { return .preflightRejected }
        let restoration = restoreNavigation(destination)
        guard restoration == .verifiedLanding else { return handleRestorationFailure(restoration) }
        let committed = backward
            ? navigationHistory.commitBack(current: current)
            : navigationHistory.commitForward(current: current)
        guard committed else { return disableHistory(actualLanding: captureNavigation()) }
        searchEpoch.successfulTraversal()
        publishPresentationChange()
        return .verifiedLanding
    }

    private func handleRestorationFailure(_ restoration: NavigationRestoreOutcome) -> NavigationTransactionOutcome {
        switch restoration {
        case .preflightRejected: return .preflightRejected
        case .compensatedFailure: return .compensatedFailure
        case let .uncompensatedInvariantFailure(actualLanding): return disableHistory(actualLanding: actualLanding)
        case .verifiedLanding: preconditionFailure("Verified navigation restoration cannot fail")
        }
    }

    private func captureNavigation() -> NavigationSnapshot? {
        navigationCapture()
    }

    private func restoreNavigation(_ destination: NavigationSnapshot) -> NavigationRestoreOutcome {
        navigationRestore(destination)
    }

    private func disableHistory(actualLanding: NavigationSnapshot?) -> NavigationTransactionOutcome {
        isNavigationHistoryHealthy = false
        publishPresentationChange()
        return .uncompensatedInvariantFailure(actualLanding: actualLanding)
    }

    func applySearchPalette(_ palette: SearchHighlightPalette) {
        viewController.applySearchPalette(palette)
    }

    func applyTheme(_ theme: AppKitTheme) {
        viewController.applyCanvasBackground(theme.canvasBackground)
        viewController.applyFocusIndicator(theme.focusRing)
        viewController.applySearchPalette(theme.searchHighlightPalette)
    }

    func beginSearch(_ query: String) {
        guard !isClosed else { return }
        searchController?.request(query)
    }


    @discardableResult
    func selectNextSearchResult() -> Bool {
        guard !isClosed else { return false }
        return searchController?.selectNext() ?? false
    }

    @discardableResult
    func selectPreviousSearchResult() -> Bool {
        guard !isClosed else { return false }
        return searchController?.selectPrevious() ?? false
    }

    func clearSearch() {
        guard !isClosed else { return }
        searchController?.clear()
        searchEpoch.clearOrCancel()
    }

    func prepareForClose() {
        prepareForClose(reason: .userClose)
    }

    func prepareForClose(reason: ReaderSessionCloseReason) {
        guard !isClosed else { return }

        searchLifecycle.requestCancellation()
        searchEpoch.clearOrCancel()
        completedTeardownSteps.append(.searchCancellationRequested)

        navigationHistory = NavigationHistory()
        searchEpoch.teardown()
        isNavigationHistoryHealthy = false

        searchLifecycle.detachCallbacks()
        document.delegate = nil
        viewController.detachDelegates()
        completedTeardownSteps.append(.callbacksAndDelegatesDetached)

        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        completedTeardownSteps.append(.notificationsDetached)

        viewController.clearSelection()
        searchLifecycle.clearHighlights()
        completedTeardownSteps.append(.selectionAndHighlightsCleared)

        viewController.detachDocument()
        completedTeardownSteps.append(.documentDetached)

        viewController.removeContentView()
        completedTeardownSteps.append(.contentViewRemoved)

        presentationChangeHandler = nil
        isClosed = true
        openMetrics.record(
            .point(.sessionClosed, traceID: openTraceID, outcome: reason.metricOutcome)
        )
    }

    private func installNotifications() {
        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewPageChanged, Notification.Name.PDFViewScaleChanged] {
            let token = center.addObserver(forName: name, object: focusView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.publishPresentationChange()
                }
            }
            notificationTokens.append(token)
        }
    }

    private func publishPresentationChange() {
        presentationChangeHandler?()
    }

    private func documentContainsSearchableText() -> Bool {
        for index in 0..<document.pageCount {
            guard let text = document.page(at: index)?.string else { continue }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    private var searchDetail: String {
        let search = searchSnapshot
        guard search.isActive else { return title }
        if search.isRunning {
            let suffix = search.matchCount == 0 ? "" : " · \(search.matchCount) found"
            return "Searching “\(search.query)”…\(suffix)"
        }
        guard let active = search.activeMatchNumber else {
            switch search.emptyResult {
            case .noSearchableText:
                return "No searchable text · “\(search.query)”"
            case .noMatch, nil:
                return "No matches · “\(search.query)”"
            }
        }
        return "\(active) / \(search.matchCount) · “\(search.query)”"
    }
}

extension ReaderSession: ReaderLinkProviding {
    func linkTargets() -> [RawLink] {
        guard !isClosed else { return [] }
        return viewController.linkTargets()
    }

    func activateLink(_ target: ReaderLinkTarget) {
        guard !isClosed else { return }
        viewController.activateLink(target)
    }

    func linkHintRects(for link: ReaderLink, in coordinateSpace: NSView) -> [NSRect] {
        guard !isClosed else { return [] }
        return viewController.linkHintRects(for: link, in: coordinateSpace)
    }
}

extension ReaderSession: ReaderDuplicationSnapshotProviding {
    var duplicationSnapshot: ReaderDuplicationSnapshot? {
        guard !isClosed, let navigation = captureNavigation() else { return nil }
        return ReaderDuplicationSnapshot(sourceURL: sourceURL, navigation: navigation)
    }

    func seedPendingPresentation(_ snapshot: ReaderDuplicationSnapshot) {
        guard !isClosed else { return }
        duplicateValidationState = .pending
        duplicateValidationDelivered = false
        duplicateValidationHandler = nil
        viewController.seedPresentation(snapshot.navigation, onSuccess: { [weak self] in
            self?.resolveDuplicateValidation(true)
        }, onFailure: { [weak self] in
            self?.resolveDuplicateValidation(false)
            self?.prepareForClose(reason: .insertionRejected)
        })
    }
}
