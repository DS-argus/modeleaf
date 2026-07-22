import AppKit
import PDFKit
import PDFReaderCore

enum ReaderViewMode: String, Equatable, Sendable {
    case manual
    case actualSize
    case fitWidth
    case fitPage
}

@MainActor
final class PDFViewController: NSViewController {
    private let readerView: ReaderPDFView
    private let initialDocument: PDFDocument
    private var canvasBackground: NSColor
    private var focusIndicator: NSColor
    private(set) var viewMode: ReaderViewMode = .fitWidth
    private var searchPalette = SearchHighlightPalette.default
    private var searchSelections: [PDFSelection] = []
    private var activeSearchIndex: Int?

    init(document: PDFDocument) {
        self.initialDocument = document
        self.readerView = ReaderPDFView(frame: .zero)
        let defaultTheme = AppKitTheme(configuration: BuiltInDefaults.config.theme)
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
        readerView.document = initialDocument
        readerView.displayMode = .singlePageContinuous
        readerView.autoScales = true
        view = container
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
        readerView.go(to: page)
        return true
    }

    func scrollBy(xPoints: Double, yPoints: Double) {
        loadViewIfNeeded()
        readerView.scrollBy(xPoints: xPoints, yPoints: yPoints)
    }

    func scrollVerticallyByViewportFraction(_ fraction: Double) {
        loadViewIfNeeded()
        readerView.scrollVerticallyByViewportFraction(fraction)
    }

    func zoom(by factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        loadViewIfNeeded()
        readerView.autoScales = false
        viewMode = .manual
        readerView.scaleFactor = min(readerView.maxScaleFactor, max(readerView.minScaleFactor, readerView.scaleFactor * factor))
    }

    func resetZoom() {
        loadViewIfNeeded()
        readerView.autoScales = false
        readerView.scaleFactor = 1
        viewMode = .actualSize
    }

    func fitWidth() {
        loadViewIfNeeded()
        readerView.displayMode = .singlePageContinuous
        readerView.autoScales = true
        viewMode = .fitWidth
    }

    func fitPage() {
        loadViewIfNeeded()
        readerView.displayMode = .singlePage
        readerView.autoScales = true
        viewMode = .fitPage
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
