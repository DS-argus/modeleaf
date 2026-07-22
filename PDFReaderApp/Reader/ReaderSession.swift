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
    private var cachedSearchableTextPresence: Bool?
    private var notificationTokens: [NSObjectProtocol] = []
    private var presentationChangeHandler: (() -> Void)?

    private(set) var completedTeardownSteps: [ReaderTeardownStep] = []
    private(set) var isClosed = false

    init(
        id: TabID = TabID(),
        sourceURL: URL,
        document: PDFDocument,
        searchLifecycle: (any ReaderSearchLifecycle)? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.title = sourceURL.lastPathComponent.isEmpty ? "Untitled.pdf" : sourceURL.lastPathComponent
        self.document = document
        let viewController = PDFViewController(document: document)
        self.viewController = viewController
        if let searchLifecycle {
            self.searchLifecycle = searchLifecycle
            self.searchController = searchLifecycle as? any ReaderSearchControlling
        } else {
            let coordinator = ReaderSearchCoordinator(
                driver: PDFKitSearchDriver(document: document),
                presenter: viewController
            )
            self.searchLifecycle = coordinator
            self.searchController = coordinator
        }
        super.init()
        searchController?.setChangeHandler { [weak self] in
            self?.publishPresentationChange()
        }
        installNotifications()
    }

    var contentView: NSView { viewController.view }
    var focusView: NSView { viewController.focusView }
    var pageCount: Int { viewController.pageCount }
    var currentPageNumber: Int? { viewController.currentPageNumber }
    var scaleFactor: Double { Double(viewController.scaleFactor) }
    var viewMode: ReaderViewMode { viewController.viewMode }
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
        return ReaderStatusSnapshot(
            context: preferredInputContext == .searchResults ? "SEARCH" : "NORMAL",
            page: "\(page) / \(pageCount)",
            zoom: "\(zoom)%",
            detail: searchDetail
        )
    }

    func setPresentationChangeHandler(_ handler: (() -> Void)?) {
        presentationChangeHandler = handler
    }

    @discardableResult
    func goToPage(_ oneBasedPage: Int) -> Bool {
        guard !isClosed, viewController.goToPage(oneBasedPage) else { return false }
        publishPresentationChange()
        return true
    }

    @discardableResult
    func goToNextPage() -> Bool {
        guard let currentPageNumber, currentPageNumber < pageCount else { return false }
        return goToPage(currentPageNumber + 1)
    }

    @discardableResult
    func goToPreviousPage() -> Bool {
        guard let currentPageNumber, currentPageNumber > 1 else { return false }
        return goToPage(currentPageNumber - 1)
    }

    @discardableResult
    func goToFirstPage() -> Bool {
        goToPage(1)
    }

    @discardableResult
    func goToLastPage() -> Bool {
        goToPage(pageCount)
    }

    func scrollBy(xPoints: Double, yPoints: Double) {
        guard !isClosed else { return }
        viewController.scrollBy(xPoints: xPoints, yPoints: yPoints)
    }

    func scrollVerticallyByViewportFraction(_ fraction: Double) {
        guard !isClosed else { return }
        viewController.scrollVerticallyByViewportFraction(fraction)
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
    }

    func prepareForClose() {
        guard !isClosed else { return }

        searchLifecycle.requestCancellation()
        completedTeardownSteps.append(.searchCancellationRequested)

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
