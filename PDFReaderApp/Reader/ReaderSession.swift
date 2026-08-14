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
    case presentationAcceptedWithoutHistory
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

typealias ReaderSearchControllerFactory = (
    @escaping (Int) -> SearchNavigationActivationOutcome,
    @escaping (Int, ReaderSearchResultDisplayOutcome) -> SearchNavigationActivationOutcome
) -> any ReaderSearchControlling

@MainActor
final class ReaderSession: NSObject, ReaderSessionPresenting, ReaderDuplicateValidating {
    let id: TabID
    let title: String
    let sourceURL: URL

    private let document: PDFDocument
    private let viewController: PDFViewController
    private let usesControllerNavigation: Bool
    private let searchControllerFactory: ReaderSearchControllerFactory
    private lazy var searchController: any ReaderSearchControlling = searchControllerFactory(
        { [weak self] generation in self?.activateSearchNavigation(searchGeneration: generation) ?? .preflightRejected },
        { [weak self] generation, outcome in
            self?.reportSearchPresentationOutcome(searchGeneration: generation, outcome: outcome) ?? .preflightRejected
        }
    )
    private let openTraceID: OpenTraceID
    private let navigationCapture: () -> NavigationSnapshot?
    private var duplicateValidationState: DuplicateValidationState = .pending
    private var duplicateValidationHandler: ((Bool) -> Void)?
    private let navigationRestore: (NavigationSnapshot) -> NavigationRestoreOutcome
    private var duplicateValidationDelivered = false
    private let openMetrics: any PDFOpenMetrics
    private var cachedSearchableTextPresence: Bool?
    private let printHandler: () -> Bool
    private var notificationTokens: [NSObjectProtocol] = []
    private var presentationChangeHandler: (() -> Void)?
    private var navigationOutcomeHandler: ((NavigationTransactionOutcome) -> Void)?
    private var navigationHistory = NavigationHistory()
    private var searchEpoch: SearchEpoch = .idle
    private var searchOrigins: [Int: NavigationSnapshot] = [:]
    private(set) var isNavigationHistoryHealthy = true
    private var successfulUserMovementRevision: UInt64 = 0
    private var suppressCommandPresentationPublication = false

    private lazy var outline = ReaderOutline(document: document) { [weak viewController] destination in
        viewController?.navigationSnapshot(forOutlineDestination: destination)
    }

    private(set) var completedTeardownSteps: [ReaderTeardownStep] = []
    private(set) var isClosed = false

    init(
        id: TabID = TabID(),
        sourceURL: URL,
        document: PDFDocument,
        searchControllerFactory: ReaderSearchControllerFactory? = nil,
        traceID: OpenTraceID = OpenTraceID(),
        metrics: any PDFOpenMetrics = NoopPDFOpenMetrics(),
        navigationCapture: (() -> NavigationSnapshot?)? = nil,
        navigationRestore: ((NavigationSnapshot) -> NavigationRestoreOutcome)? = nil,
        printHandler: (() -> Bool)? = nil
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
        if let navigationCapture { viewController.setNavigationSnapshotCaptureOverride(navigationCapture) }
        self.navigationCapture = navigationCapture ?? { viewController.captureNavigationSnapshot() }
        self.navigationRestore = navigationRestore ?? { viewController.restoreNavigationSnapshot($0) }
        self.usesControllerNavigation = navigationCapture == nil && navigationRestore == nil
        self.printHandler = printHandler ?? { viewController.printDocument() }
        self.searchControllerFactory = searchControllerFactory ?? { activate, reportOutcome in
            ReaderSearchCoordinator(
                driver: PDFKitSearchDriver(document: document),
                presenter: viewController,
                activateNavigation: activate,
                reportNavigationOutcome: reportOutcome
            )
        }
        super.init()
        viewController.setViewportMutationHandler { [weak self] terminal in
            guard let self else { return }
            if case let .changed(epoch) = terminal, epoch.origin.isUserMovement {
                self.successfulUserMovementRevision &+= 1
            }
            self.presentationChangeHandler?()
        }
        searchController.setChangeHandler { [weak self] in self?.publishPresentationChange() }
        installNotifications()
        viewController.setInternalLinkHandler { [weak self] target in
            self?.activateInternalLinkWithDestinationFeedback(target)
        }
        metrics.record(.end(.sessionConstruct, traceID: traceID, outcome: .success))
    }
    var navigationAvailabilityDetail: String {
        isNavigationHistoryHealthy ? "History available" : "Navigation history unavailable"
    }

    var canGoBack: Bool { isNavigationHistoryHealthy && navigationHistory.canGoBack }
    var canGoForward: Bool { isNavigationHistoryHealthy && navigationHistory.canGoForward }


    var outlineSnapshot: ReaderOutlineSnapshot {
        guard !isClosed else { return .empty }
        return outline.snapshot(
            viewportAnchor: captureNavigation(),
            successfulUserMovementRevision: successfulUserMovementRevision
        )
    }

    @discardableResult
    func activateOutlineRow(id: ReaderOutlineRowID) -> NavigationTransactionOutcome {
        guard let destination = outline.destination(for: id) else { return .preflightRejected }
        var outcome: NavigationTransactionOutcome = .preflightRejected
        viewController.performViewportMutation(origin: .tocActivation) {
            outcome = performNavigation(.meaningfulJump(producer: .toc, destination: destination))
        }
        return outcome
    }
    @discardableResult
    func goBack() -> NavigationTransactionOutcome {
        var outcome: NavigationTransactionOutcome = .unavailable
        if usesControllerNavigation { performUserViewportMutation { outcome = performNavigation(.back) } }
        else { outcome = performNavigation(.back) }
        return outcome
    }

    @discardableResult
    func goForward() -> NavigationTransactionOutcome {
        var outcome: NavigationTransactionOutcome = .unavailable
        if usesControllerNavigation { performUserViewportMutation { outcome = performNavigation(.forward) } }
        else { outcome = performNavigation(.forward) }
        return outcome
    }

    @discardableResult
    func performNavigation(_ request: NavigationTransactionRequest) -> NavigationTransactionOutcome {
        let outcome: NavigationTransactionOutcome
        guard !isClosed, isNavigationHistoryHealthy else {
            return publishNavigationOutcome(.unavailable)
        }
        switch request {
        case let .meaningfulJump(producer, destination):
            outcome = producer == .searchResult
                ? .preflightRejected
                : performMeaningfulJump(producer: producer, destination: destination)
        case .back:
            outcome = performTraversal(backward: true)
        case .forward:
            outcome = performTraversal(backward: false)
        }
        return publishNavigationOutcome(outcome)
    }

    @discardableResult
    func activateSearchNavigation(searchGeneration: Int) -> SearchNavigationActivationOutcome {
        guard !isClosed,
              isNavigationHistoryHealthy,
              let attemptOrigin = captureNavigation()
        else { return .preflightRejected }

        searchOrigins.removeAll(keepingCapacity: true)
        searchOrigins[searchGeneration] = attemptOrigin
        guard searchEpoch == .idle else {
            searchEpoch.replaceQuery(searchGeneration: searchGeneration)
            return .retagged
        }
        searchEpoch.arm(origin: attemptOrigin, searchGeneration: searchGeneration)
        return .armed
    }

    /// Commits the presenter-supplied actual landing after a verified distinct display.
    @discardableResult
    func recordVerifiedSearchLanding(
        searchGeneration: Int,
        landing: NavigationSnapshot
    ) -> SearchNavigationActivationOutcome {
        guard !isClosed, isNavigationHistoryHealthy else { return .preflightRejected }
        switch searchEpoch.inspectDisplayedDistinct(searchGeneration: searchGeneration) {
        case let .first(origin):
            guard navigationHistory.commitMeaningfulJump(origin: origin, landing: landing) else { return .ignored }
            _ = searchEpoch.commitFirstDisplayedDistinct(searchGeneration: searchGeneration, historyCommitted: true)
            return .firstCommitted
        case .coalesced:
            return .coalesced
        case .ignored:
            return .ignored
        }
    }

    @discardableResult
    private func reportSearchPresentationOutcome(
        searchGeneration: Int,
        outcome: ReaderSearchResultDisplayOutcome
    ) -> SearchNavigationActivationOutcome {
        guard !isClosed else { return .preflightRejected }
        let origin = searchOrigins.removeValue(forKey: searchGeneration)
        guard isNavigationHistoryHealthy else {
            return outcome.presentationWasApplied ? .presentationAcceptedWithoutHistory : .ignored
        }
        guard let origin else {
            switch outcome {
            case let .displayedDistinct(landing):
                _ = publishNavigationOutcome(disableHistory(actualLanding: landing, publishes: false))
                return .presentationAcceptedWithoutHistory
            case .displayedAfterUnverifiedMovement:
                _ = publishNavigationOutcome(disableHistory(actualLanding: captureNavigation(), publishes: false))
                return .presentationAcceptedWithoutHistory
            case .displayedSame:
                _ = publishNavigationOutcome(.preflightRejected)
                return .coalesced
            case .failedWithoutMovement:
                _ = publishNavigationOutcome(.preflightRejected)
                return .ignored
            }
        }

        switch outcome {
        case let .displayedDistinct(landing):
            let activation = recordVerifiedSearchLanding(searchGeneration: searchGeneration, landing: landing)
            let transaction: NavigationTransactionOutcome = (activation == .firstCommitted || activation == .coalesced) ? .verifiedLanding : .noOp
            _ = publishNavigationOutcome(transaction)
            return activation
        case .displayedSame:
            _ = publishNavigationOutcome(.noOp)
            return .coalesced
        case .failedWithoutMovement:
            _ = publishNavigationOutcome(.preflightRejected)
            return .ignored
        case .displayedAfterUnverifiedMovement:
            let compensation = publishNavigationOutcome(compensateUnverifiedAttempt(from: origin, publishesFailure: false))
            if case .uncompensatedInvariantFailure = compensation { return .preflightRejected }
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
        var snapshot = searchController.snapshot
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
        return ReaderStatusSnapshot(context: preferredInputContext == .searchResults ? "SEARCH" : "NORMAL", page: "\(page) / \(pageCount)", zoom: "\(zoom)%", detail: searchDetail, mode: viewMode == .fitPage ? "FIT PAGE" : "")
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

    func setNavigationOutcomeHandler(_ handler: ((NavigationTransactionOutcome) -> Void)?) {
        navigationOutcomeHandler = handler
    }

    @discardableResult
    func goToPage(_ oneBasedPage: Int) -> Bool {
        var outcome: NavigationTransactionOutcome = .preflightRejected
        performUserViewportMutation { outcome = publishNavigationOutcome(performPageJump(producer: .pagePrompt, to: oneBasedPage)) }
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
        var outcome: NavigationTransactionOutcome = .preflightRejected
        performUserViewportMutation { outcome = publishNavigationOutcome(performPageJump(producer: .firstPage, to: 1)) }
        return outcome == .verifiedLanding || outcome == .noOp
    }

    @discardableResult
    func goToLastPage() -> Bool {
        var outcome: NavigationTransactionOutcome = .preflightRejected
        performUserViewportMutation { outcome = publishNavigationOutcome(performPageJump(producer: .lastPage, to: pageCount)) }
        return outcome == .verifiedLanding || outcome == .noOp
    }

    func scrollBy(xPoints: Double, yPoints: Double) {
        guard !isClosed else { return }
        performUserViewportMutation { viewController.scrollBy(xPoints: xPoints, yPoints: yPoints) }
    }

    func scrollVerticallyByViewportFraction(_ fraction: Double) {
        guard !isClosed else { return }
        performUserViewportMutation { viewController.scrollVerticallyByViewportFraction(fraction) }
    }

    func moveHorizontally(byPoints points: Double) {
        guard !isClosed else { return }
        performUserViewportMutation { viewController.scrollBy(xPoints: points, yPoints: 0) }
    }

    func moveVertically(byPoints points: Double) {
        guard !isClosed, points != 0 else { return }
        if viewMode == .fitPage {
            _ = points > 0 ? goToNextPage() : goToPreviousPage()
            return
        }
        performUserViewportMutation {
            let outcome = viewController.scrollVertically(byPoints: points)
            if viewController.usesSinglePageLayout, outcome == .atBoundary {
                navigateAcrossVerticalBoundary(forward: points > 0)
            }
        }
    }

    func moveVertically(byViewportFraction fraction: Double) {
        guard !isClosed, fraction != 0 else { return }
        if viewMode == .fitPage {
            _ = fraction > 0 ? goToNextPage() : goToPreviousPage()
            return
        }
        performUserViewportMutation {
            let outcome = viewController.scrollVerticallyByViewportFraction(fraction)
            if viewController.usesSinglePageLayout, outcome == .atBoundary {
                navigateAcrossVerticalBoundary(forward: fraction > 0)
            }
        }
    }

    func zoom(by factor: Double) {
        guard !isClosed else { return }
        performUserViewportMutation { viewController.zoom(by: factor) }
    }

    func resetZoom() {
        guard !isClosed else { return }
        performUserViewportMutation { viewController.resetZoom() }
    }

    func fitWidth() {
        guard !isClosed else { return }
        performUserViewportMutation { viewController.fitWidth() }
    }

    func fitPage() {
        guard !isClosed else { return }
        performUserViewportMutation { viewController.fitPage() }
    }

    func rotateLeft() {
        guard !isClosed else { return }
        performUserViewportMutation { viewController.rotateLeft() }
    }

    func rotateRight() {
        guard !isClosed else { return }
        performUserViewportMutation { viewController.rotateRight() }
    }

    @discardableResult
    func printDocument() -> Bool {
        guard !isClosed else { return false }
        return printHandler()
    }

    private func navigateAcrossVerticalBoundary(forward: Bool) {
        guard let currentPageNumber else { return }
        let targetPage = currentPageNumber + (forward ? 1 : -1)
        guard targetPage >= 1, targetPage <= pageCount,
              performRawUnrecordedPageMove(targetPage) else { return }
        viewController.scrollToVerticalBoundary(forward ? .start : .end)
    }

    private func performUnrecordedPageMove(_ oneBasedPage: Int) -> Bool {
        var moved = false
        performUserViewportMutation { moved = performRawUnrecordedPageMove(oneBasedPage) }
        return moved
    }

    private func performRawUnrecordedPageMove(_ oneBasedPage: Int) -> Bool {
        guard viewController.goToPage(oneBasedPage) else { return false }
        searchEpoch.excludedMovementOrTabSwitch()
        return true
    }

    private func performPageJump(
        producer: MeaningfulJumpProducer,
        to oneBasedPage: Int
    ) -> NavigationTransactionOutcome {
        guard !isClosed,
              isNavigationHistoryHealthy,
              producer != .searchResult,
              oneBasedPage >= 1,
              oneBasedPage <= pageCount,
              let origin = captureNavigation()
        else { return .preflightRejected }

        guard viewController.goToPage(oneBasedPage) else {
            searchEpoch.failedOrSameNonSearchAttempt()
            return .preflightRejected
        }
        guard let landing = captureNavigation() else {
            return compensateUnverifiedAttempt(from: origin)
        }
        guard navigationHistory.commitMeaningfulJump(origin: origin, landing: landing) else {
            searchEpoch.failedOrSameNonSearchAttempt()
            return .noOp
        }
        searchEpoch.successfulNonSearchJump()
        publishPresentationChange()
        return .verifiedLanding
    }

    private func compensateUnverifiedAttempt(
        from origin: NavigationSnapshot,
        publishesFailure: Bool = true
    ) -> NavigationTransactionOutcome {
        switch restoreNavigation(origin) {
        case .verifiedLanding:
            return .compensatedFailure
        case .compensatedFailure, .preflightRejected:
            return disableHistory(actualLanding: captureNavigation(), publishes: publishesFailure)
        case let .uncompensatedInvariantFailure(actualLanding):
            return disableHistory(actualLanding: actualLanding, publishes: publishesFailure)
        }
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
            return compensateUnverifiedAttempt(from: origin)
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

    private func disableHistory(
        actualLanding: NavigationSnapshot?,
        publishes: Bool = true
    ) -> NavigationTransactionOutcome {
        isNavigationHistoryHealthy = false
        if publishes { publishPresentationChange() }
        return .uncompensatedInvariantFailure(actualLanding: actualLanding)
    }

    @discardableResult
    private func publishNavigationOutcome(_ outcome: NavigationTransactionOutcome) -> NavigationTransactionOutcome {
        navigationOutcomeHandler?(outcome)
        return outcome
    }

    func applySearchPalette(_ palette: SearchHighlightPalette) {
        viewController.applySearchPalette(palette)
    }

    func applyTheme(_ theme: AppKitTheme) {
        viewController.applyCanvasBackground(theme.canvasBackground)
        viewController.applyFocusIndicator(theme.focusRing)
        viewController.applyDestinationIndicatorAppearance(
            accentColor: theme[.accent],
            backgroundColor: theme.canvasBackground
        )
        viewController.applySearchPalette(theme.searchHighlightPalette)
    }

    func applyLinkDestinationIndicatorSettings(_ settings: LinkDestinationIndicatorSettings) {
        viewController.applyDestinationIndicatorSettings(settings)
    }

    func cancelDestinationIndicator() {
        guard !isClosed else { return }
        viewController.cancelDestinationIndicator()
    }

    func beginSearch(_ query: String) {
        guard !isClosed else { return }
        searchController.request(query)
    }

    @discardableResult
    func selectNextSearchResult() -> Bool {
        guard !isClosed else { return false }
        return searchController.selectNext()
    }

    @discardableResult
    func selectPreviousSearchResult() -> Bool {
        guard !isClosed else { return false }
        return searchController.selectPrevious()
    }

    func clearSearch() {
        guard !isClosed else { return }
        searchController.clear()
        searchEpoch.clearOrCancel()
        searchOrigins.removeAll(keepingCapacity: false)
    }

    func prepareForClose() {
        prepareForClose(reason: .userClose)
    }

    func prepareForClose(reason: ReaderSessionCloseReason) {
        guard !isClosed else { return }
        viewController.cancelDestinationIndicator()

        searchController.requestCancellation()
        searchEpoch.clearOrCancel()
        searchOrigins.removeAll(keepingCapacity: false)
        completedTeardownSteps.append(.searchCancellationRequested)

        navigationHistory = NavigationHistory()
        searchEpoch.teardown()
        searchOrigins.removeAll(keepingCapacity: false)
        isNavigationHistoryHealthy = false

        searchController.detachCallbacks()
        document.delegate = nil
        viewController.detachDelegates()
        completedTeardownSteps.append(.callbacksAndDelegatesDetached)

        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        completedTeardownSteps.append(.notificationsDetached)

        viewController.clearSelection()
        searchController.clearHighlights()
        completedTeardownSteps.append(.selectionAndHighlightsCleared)

        viewController.detachDocument()
        completedTeardownSteps.append(.documentDetached)

        viewController.removeContentView()
        completedTeardownSteps.append(.contentViewRemoved)

        presentationChangeHandler = nil
        navigationOutcomeHandler = nil
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
                    self?.viewController.cancelDestinationIndicator()
                    self?.publishPresentationChange()
                }
            }
            notificationTokens.append(token)
        }
    }

    private func performUserViewportMutation(_ operation: () -> Void) {
        suppressCommandPresentationPublication = true
        defer { suppressCommandPresentationPublication = false }
        viewController.performUserViewportMutation(operation)
    }
    private func publishPresentationChange() {
        guard !suppressCommandPresentationPublication else { return }
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
        switch target {
        case .url:
            viewController.activateLink(target)
        case .goTo:
            activateInternalLinkWithDestinationFeedback(target)
        }
    }

    private func activateInternalLinkWithDestinationFeedback(_ target: ReaderLinkTarget) {
        viewController.cancelDestinationIndicator()
        let indicatorDestination = viewController.destinationIndicatorSnapshot(for: target)
        let outcome = executeInternalLink(target)
        if outcome == .verifiedLanding, let indicatorDestination {
            viewController.presentDestinationIndicator(at: indicatorDestination)
        }
    }

    var destinationIndicatorVisibleForTesting: Bool { viewController.destinationIndicatorVisibleForTesting }
    var destinationIndicatorCenterForTesting: CGPoint? { viewController.destinationIndicatorCenterForTesting }
    var destinationIndicatorGenerationForTesting: Int { viewController.destinationIndicatorGenerationForTesting }

    @discardableResult
    private func executeInternalLink(_ target: ReaderLinkTarget) -> NavigationTransactionOutcome {
        guard let destination = viewController.navigationSnapshot(forInternalLink: target) else { return .preflightRejected }
        var outcome: NavigationTransactionOutcome = .preflightRejected
        performUserViewportMutation { outcome = performMeaningfulJump(producer: .internalLink, destination: destination) }
        return outcome
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
