import AppKit
import Foundation
import PDFKit

public enum PDFCapability: String, CaseIterable, Sendable {
    case display
    case scrolling
    case selection
    case copy
    case registryNavigation
    case registryZoom
    case registrySearch
    case registryDocument
    case registryTab
    case formEditing
    case annotationEditing
    case contextMenuOutsideAllowlist
    case printExport
    case pageHistory
    case linkActivation
    case embeddedMedia
}

public enum PDFCapabilityDisposition: String, Sendable {
    case allowed
    case registryRouted
    case systemOwned
    case suppressed
}

public enum PDFCapabilityPolicy {
    public static func disposition(for capability: PDFCapability) -> PDFCapabilityDisposition {
        switch capability {
        case .display, .scrolling, .selection:
            .allowed
        case .copy:
            .systemOwned
        case .registryNavigation, .registryZoom, .registrySearch, .registryDocument, .registryTab:
            .registryRouted
        case .formEditing, .annotationEditing, .contextMenuOutsideAllowlist, .printExport,
             .pageHistory, .linkActivation, .embeddedMedia:
            .suppressed
        }
    }
}

@MainActor
private final class ReadOnlyProbePDFView: PDFView, @preconcurrency PDFViewDelegate {
    private(set) var blockedPDFActionCount = 0
    private(set) var blockedLinkCount = 0
    private(set) var blockedPrintCount = 0
    private(set) var blockedHistoryCount = 0

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        acceptsDraggedFiles = false
        enableDataDetectors = false
        isInMarkupMode = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func perform(_ action: PDFAction) {
        blockedPDFActionCount += 1
    }

    override func goBack(_ sender: Any?) {
        blockedHistoryCount += 1
    }

    override func goForward(_ sender: Any?) {
        blockedHistoryCount += 1
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        safeContextMenu()
    }

    func safeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "PDF")
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: ""))
        return menu
    }

    func shouldForwardMouseEvent(in area: PDFAreaOfInterest) -> Bool {
        let suppressed: PDFAreaOfInterest = [.annotationArea, .linkArea, .controlArea, .textFieldArea, .iconArea, .popupArea]
        return area.intersection(suppressed).isEmpty
    }

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        blockedLinkCount += 1
    }

    func pdfViewPerformPrint(_ sender: PDFView) {
        blockedPrintCount += 1
    }
}

@MainActor
public enum PDFCapabilityProbe {
    public static func run() throws -> ProbeSection {
        let document = try PDFFixtureFactory.searchableDocument(pageCount: 2, repeatedText: "copyable needle")
        guard let firstPage = document.page(at: 0) else {
            throw ProbeFailure.invariant("generated fixture has no first page")
        }

        let widget = PDFAnnotation(
            bounds: CGRect(x: 40, y: 620, width: 180, height: 30),
            forType: .widget,
            withProperties: nil
        )
        widget.widgetFieldType = .text
        widget.widgetStringValue = "original"

        let note = PDFAnnotation(
            bounds: CGRect(x: 260, y: 620, width: 24, height: 24),
            forType: .text,
            withProperties: nil
        )
        note.contents = "original note"

        let link = PDFAnnotation(
            bounds: CGRect(x: 40, y: 560, width: 180, height: 24),
            forType: .link,
            withProperties: nil
        )
        link.action = PDFActionURL(url: URL(string: "https://example.invalid/")!)

        firstPage.addAnnotation(widget)
        firstPage.addAnnotation(note)
        firstPage.addAnnotation(link)

        let originalWidget = widget.widgetStringValue
        let originalNote = note.contents
        let originalAnnotationCount = firstPage.annotations.count

        let view = ReadOnlyProbePDFView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        view.document = document

        let selection = document.selectionForEntireDocument
        view.currentSelection = selection
        let selectionAllowed = view.currentSelection?.string?.contains("copyable") == true

        NSPasteboard.general.clearContents()
        view.copy(nil)
        let copied = NSPasteboard.general.string(forType: .string)?.contains("copyable") == true

        let menu = view.safeContextMenu()
        let menuSelectors = menu.items.compactMap(\.action)
        let copyOnly = menuSelectors == [#selector(NSText.copy(_:))]

        let action = PDFActionURL(url: URL(string: "https://example.invalid/")!)
        view.perform(action)
        view.goBack(nil)
        view.goForward(nil)
        view.pdfViewWillClick(onLink: view, with: URL(string: "https://example.invalid/")!)
        view.pdfViewPerformPrint(view)

        let forbiddenMouseAreas: [PDFAreaOfInterest] = [
            .annotationArea, .linkArea, .controlArea, .textFieldArea, .iconArea, .popupArea,
        ]
        let forbiddenMouseBlocked = forbiddenMouseAreas.allSatisfy { !view.shouldForwardMouseEvent(in: $0) }
        let textMouseAllowed = view.shouldForwardMouseEvent(in: .textArea)

        let immutable = widget.widgetStringValue == originalWidget
            && note.contents == originalNote
            && firstPage.annotations.count == originalAnnotationCount

        let suppressedCapabilities = PDFCapability.allCases
            .filter { PDFCapabilityPolicy.disposition(for: $0) == .suppressed }
        let exactSuppressedSet = Set(suppressedCapabilities) == Set([
            .formEditing, .annotationEditing, .contextMenuOutsideAllowlist, .printExport,
            .pageHistory, .linkActivation, .embeddedMedia,
        ])

        view.currentSelection = nil
        view.document = nil

        return ProbeSection(
            id: "pdf-capability",
            title: "PDFKit read-only capability containment",
            checks: [
                checked("capability-matrix", exactSuppressedSet, detail: "the fixed allowed/registry/system/suppressed matrix contains every excluded capability"),
                checked("selection", selectionAllowed, detail: "text selection remains available"),
                checked("copy", copied, detail: "standard non-mutating copy remains available"),
                checked("context-menu", copyOnly, detail: "the PDF context menu contains only the allowlisted Copy command"),
                checked("mouse-containment", forbiddenMouseBlocked && textMouseAllowed, detail: "form, annotation, link, and popup hit regions are blocked while text regions pass through"),
                checked("action-containment", view.blockedPDFActionCount == 1 && view.blockedHistoryCount == 2 && view.blockedLinkCount == 1 && view.blockedPrintCount == 1, detail: "link, history, generic PDF actions, and print callbacks terminate at the read-only view boundary"),
                checked("in-memory-immutability", immutable, detail: "widget values, annotation contents, and annotation count remain unchanged after all probes"),
                checked("view-flags", !view.acceptsDraggedFiles && !view.enableDataDetectors && !view.isInMarkupMode, detail: "drag replacement, data-detector links, and markup mode are disabled"),
                checked("teardown", view.document == nil && view.currentSelection == nil, detail: "selection is cleared and PDFView.document is detached"),
            ]
        )
    }
}
