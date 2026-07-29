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

@MainActor
final class PDFViewController: NSViewController {
    private let readerView: ReaderPDFView
    private let initialDocument: PDFDocument
    private let openTraceID: OpenTraceID
    private let openMetrics: any PDFOpenMetrics
    private var canvasBackground: NSColor
    private var focusIndicator: NSColor
    private(set) var viewMode: ReaderViewMode = .fitPage
    private(set) var initialPresentationState: InitialPDFPresentationState = .pending
    private var searchPalette = SearchHighlightPalette.default
    private var searchSelections: [PDFSelection] = []
    private var pendingPresentationPage: Int?
    private var activeSearchIndex: Int?

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


    /// Seed a duplicated pane's initial page. It always mounts fit-to-page in
    /// its own bounds (see ReaderDuplicationSnapshot); only the page carries.
    func seedPresentation(page: Int) {
        guard page >= 1, page <= initialDocument.pageCount else { return }
        pendingPresentationPage = page
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

    private func applyInitialPresentationIfReady() {
        guard initialPresentationState == .pending,
              readerView.window != nil,
              readerView.bounds.width > 1,
              readerView.bounds.height > 1,
              let firstPage = initialDocument.page(at: 0)
        else {
            return
        }

        initialPresentationState = .applying
        // A seeded duplicate opens the same page fit-to-page; a fresh pane
        // opens page one fit-to-page. Both land in the identical mount path.
        let targetPage = pendingPresentationPage.flatMap { initialDocument.page(at: $0 - 1) } ?? firstPage
        readerView.displayMode = .singlePage
        readerView.autoScales = true
        readerView.go(to: targetPage)
        readerView.layoutDocumentView()
        viewMode = .fitPage
        pendingPresentationPage = nil
        initialPresentationState = .applied
    }

    private func supersedePendingInitialPresentation() {
        if initialPresentationState == .pending {
            initialPresentationState = .supersededByUser
        }
    }

    private func renderSearchResults() {
        loadViewIfNeeded()
        for selection in searchSelections {
            selection.color = searchPalette.allResults
        }
        if let activeSearchIndex, searchSelections.indices.contains(activeSearchIndex) {
            let active = searchSelections[activeSearchIndex]
            active.color = searchPalette.activeResult
            readerView.highlightedSelections = searchSelections
            readerView.setCurrentSelection(active, animate: false)
            readerView.scrollSelectionToVisible(nil)
        } else {
            readerView.highlightedSelections = searchSelections.isEmpty ? nil : searchSelections
            readerView.currentSelection = nil
        }
    }
}

extension PDFViewController: ReaderLinkProviding {
    func linkTargets() -> [RawLink] {
        loadViewIfNeeded()
        readerView.layoutDocumentView()
        return readerView.visiblePages.flatMap { page in
            let index = initialDocument.index(for: page)
            return page.annotations.compactMap { annotation -> RawLink? in
                guard Self.isLink(annotation), let target = Self.linkTarget(annotation) else { return nil }
                return RawLink(sourcePageIndex: index, pageSpaceBounds: annotation.bounds, target: target)
            }
        }
    }

    func activateLink(_ target: ReaderLinkTarget) {
        loadViewIfNeeded()
        readerView.activate(target)
    }


    func linkHintRects(for link: ReaderLink, in coordinateSpace: NSView) -> [NSRect] {
        loadViewIfNeeded()
        guard let page = initialDocument.page(at: link.sourcePageIndex) else { return [] }
        return link.rects.map { rect in
            let readerRect = readerView.convert(rect, from: page)
            return readerView.convert(readerRect, to: coordinateSpace)
        }
    }
    private static func isLink(_ annotation: PDFAnnotation) -> Bool {
        annotation.type == "Link" || annotation.action != nil || annotation.url != nil
    }

    private static func linkTarget(_ annotation: PDFAnnotation) -> ReaderLinkTarget? {
        if let goTo = annotation.action as? PDFActionGoTo {
            let destination = goTo.destination
            guard let page = destination.page, let document = page.document else { return nil }
            return .goTo(pageIndex: document.index(for: page), point: destination.point)
        }
        if let action = annotation.action as? PDFActionURL, let url = action.url { return .url(url.absoluteString) }
        if let url = annotation.url { return .url(url.absoluteString) }
        return nil
    }
}
extension PDFViewController: ReaderSearchResultPresenting {
    func presentSearchResults(_ selections: [PDFSelection], activeIndex: Int?) {
        searchSelections = selections
        activeSearchIndex = activeIndex
        renderSearchResults()
    }

    func activateSearchResult(at index: Int) {
        guard searchSelections.indices.contains(index) else { return }
        if let activeSearchIndex, searchSelections.indices.contains(activeSearchIndex) {
            searchSelections[activeSearchIndex].color = searchPalette.allResults
        }
        let active = searchSelections[index]
        active.color = searchPalette.activeResult
        activeSearchIndex = index
        readerView.setCurrentSelection(active, animate: false)
        readerView.scrollSelectionToVisible(nil)
    }

    func clearSearchResults() {
        searchSelections.removeAll(keepingCapacity: false)
        activeSearchIndex = nil
        loadViewIfNeeded()
        readerView.highlightedSelections = nil
        readerView.currentSelection = nil
    }
}
