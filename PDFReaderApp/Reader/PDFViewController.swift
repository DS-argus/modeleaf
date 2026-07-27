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

    func linkTargets(in coordinateSpace: NSView) -> [ReaderLinkTarget] {
        loadViewIfNeeded()
        readerView.layoutDocumentView()
        var byKey: [String: (kind: ReaderLinkKind, rects: [NSRect])] = [:]
        var order: [String] = []
        func convert(_ pageRect: NSRect, on page: PDFPage) -> NSRect {
            readerView.convert(readerView.convert(pageRect, from: page), to: coordinateSpace)
        }
        for page in readerView.visiblePages {
            // Annotation links, grouped by resolved target so a link that wraps
            // (several annotations) becomes one hint with several outlines.
            for annotation in page.annotations where Self.isLink(annotation) {
                guard let kind = Self.linkKind(annotation) else { continue }
                let key = self.key(for: kind)
                if byKey[key] == nil { byKey[key] = (kind, []); order.append(key) }
                byKey[key]?.rects.append(convert(annotation.bounds, on: page))
            }
            // Data-detector text URLs (many PDFs print URLs as plain text with no
            // annotation). Skip any already carried by an annotation.
            for (url, pageRects) in Self.textURLRects(on: page) {
                let key = "url:\(url.absoluteString)"
                guard byKey[key] == nil else { continue }
                byKey[key] = (.url(url), pageRects.map { convert($0, on: page) })
                order.append(key)
            }
        }
        return order.compactMap { byKey[$0] }.map { ReaderLinkTarget(rects: $0.rects, kind: $0.kind) }
    }

    private func key(for kind: ReaderLinkKind) -> String {
        switch kind {
        case let .url(url):
            return "url:\(url.absoluteString)"
        case let .destination(destination):
            let pageIndex = destination.page.flatMap { initialDocument.index(for: $0) } ?? -1
            return "dest:\(pageIndex):\(Int(destination.point.x)):\(Int(destination.point.y))"
        }
    }

    @discardableResult
    func activateLink(_ target: ReaderLinkTarget) -> ReaderLinkActivation {
        switch target.kind {
        case let .destination(destination):
            loadViewIfNeeded()
            supersedePendingInitialPresentation()
            readerView.go(to: destination)
            return .navigatedInDocument
        case let .url(url):
            return .openExternal(url)
        }
    }

    static func isLink(_ annotation: PDFAnnotation) -> Bool {
        annotation.type == "Link" || annotation.action != nil || annotation.url != nil
    }

    static func linkKind(_ annotation: PDFAnnotation) -> ReaderLinkKind? {
        if let goTo = annotation.action as? PDFActionGoTo {
            return .destination(goTo.destination)
        }
        if let urlAction = annotation.action as? PDFActionURL, let url = urlAction.url {
            return .url(url)
        }
        if let url = annotation.url {
            return .url(url)
        }
        return nil
    }
    /// URLs printed as plain text (no annotation), with one rect per wrapped line.
    /// A URL broken across lines after a `-`/`_` is rejoined; other line breaks end it.
    static func textURLRects(on page: PDFPage) -> [(url: URL, rects: [NSRect])] {
        guard let text = page.string, !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }
        let ns = text as NSString
        var results: [(URL, [NSRect])] = []
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.url != nil {
            let range = extendURLRange(match.range, in: ns)
            let raw = ns.substring(with: range)
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
            guard let url = URL(string: raw), let selection = page.selection(for: range) else { continue }
            let rects = selection.selectionsByLine().map { $0.bounds(for: page) }.filter { $0.width > 1 && $0.height > 1 }
            guard !rects.isEmpty else { continue }
            results.append((url, rects))
        }
        return results
    }

    /// Extends a detected URL range across single line breaks when the fragment
    /// ends in a hyphen/underscore (a wrapped URL), consuming the next line's run
    /// of non-space characters.
    static func extendURLRange(_ range: NSRange, in ns: NSString) -> NSRange {
        var end = range.location + range.length
        while end < ns.length {
            let previous = ns.character(at: end - 1)
            guard previous == 45 || previous == 95 else { break } // '-' or '_'
            guard ns.character(at: end) == 10 || ns.character(at: end) == 13 else { break }
            var cursor = end
            while cursor < ns.length, ns.character(at: cursor) == 10 || ns.character(at: cursor) == 13 { cursor += 1 }
            var run = cursor
            while run < ns.length {
                let scalar = ns.character(at: run)
                if scalar == 32 || scalar == 9 || scalar == 10 || scalar == 13 { break }
                run += 1
            }
            guard run > cursor else { break }
            end = run
        }
        return NSRange(location: range.location, length: end - range.location)
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
