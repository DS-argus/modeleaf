import AppKit
import PDFKit
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("PDFKit inherited-capability containment")
@MainActor
struct PDFCapabilityPolicyTests {
    @Test("I-PDF-07 capability matrix is exact and viewer-first")
    func exactCapabilityMatrix() {
        let grouped = Dictionary(grouping: PDFCapability.allCases, by: PDFCapabilityPolicy.disposition(for:))

        #expect(Set(grouped[.allowed] ?? []) == Set([.display, .scrolling, .selection, .pointerCoexistence, .linkActivation]))
        #expect(Set(grouped[.systemOwned] ?? []) == [.copy])
        #expect(Set(grouped[.registryRouted] ?? []) == Set([
            .registryNavigation, .registryZoom, .registrySearch, .registryDocument, .registryTab,
        ]))
        #expect(Set(grouped[.suppressed] ?? []) == Set([
            .formEditing, .annotationEditing, .contextMenuOutsideAllowlist, .printExport,
            .pageHistory, .embeddedMedia,
        ]))
    }

    @Test("I-PDF-06 form and annotation state remains immutable across allowed and blocked paths")
    func interactiveStateCannotMutate() throws {
        try withTemporaryDirectory { directory in
            let fixture = try PDFFixtureFactory.makeInteractivePDF(in: directory)
            let document = try #require(PDFDocument(url: fixture.url))
            let page = try #require(document.page(at: 0))
            let widget = try #require(page.annotations.first(where: { $0.widgetFieldType == .text }))
            let note = try #require(page.annotations.first(where: { $0.contents == fixture.noteContents }))
            let view = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view.document = document
            view.enforceReadOnlyDocumentConfiguration()
            view.followLinkHandler = { _ in }

            let originalWidget = widget.widgetStringValue
            let originalNote = note.contents
            let originalCount = page.annotations.count

            view.currentSelection = document.selectionForEntireDocument
            let menu = view.makeSafeContextMenu()
            let copy = try #require(menu.items.only)
            _ = copy.target?.perform(copy.action, with: copy)

            view.perform(PDFActionURL(url: URL(string: "https://example.invalid/blocked")!))
            view.goBack(nil)
            view.goForward(nil)
            view.printView(nil)
            view.pdfViewWillClick(onLink: view, with: URL(string: "https://example.invalid/blocked")!)
            view.pdfViewPerformPrint(view)

            #expect(view.shouldForwardMouseEvent(in: .textArea))
            #expect(view.shouldForwardMouseEvent(in: .linkArea)) // links are followable now
            for area: PDFAreaOfInterest in [.annotationArea, .controlArea, .textFieldArea, .iconArea, .popupArea] {
                #expect(!view.shouldForwardMouseEvent(in: area))
            }

            #expect(widget.widgetStringValue == originalWidget)
            #expect(note.contents == originalNote)
            #expect(page.annotations.count == originalCount)
            #expect(fixture.widgetValue == originalWidget)
            #expect(fixture.noteContents == originalNote)
            #expect(fixture.annotationCount == originalCount)
            #expect(view.blockedActionCount == 0) // URL action is now followed, not blocked
            #expect(view.blockedHistoryCount == 2)
            #expect(view.followedLinkCount == 2) // perform(URLAction) + pdfViewWillClick
            #expect(view.blockedPrintCount == 2)
            #expect(menu.items.compactMap(\.action) == [#selector(NSText.copy(_:))])
            #expect(!view.acceptsDraggedFiles)
            #expect(!view.enableDataDetectors)
            #expect(!view.isInMarkupMode)

            view.prepareForClose()
        }
    }

    @Test("registry-owned keys never fall through to PDFKit while Command-C remains system-owned")
    func keyAndCopyRouting() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 1)
            let document = try #require(PDFDocument(url: url))
            let view = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
            view.document = document
            view.enforceReadOnlyDocumentConfiguration()
            view.currentSelection = document.selectionForEntireDocument
            var routedCharacters: [String] = []
            view.keyEventHandler = { event in
                routedCharacters.append(event.charactersIgnoringModifiers ?? "")
                return true
            }

            let navigationEvent = try #require(keyEvent(character: "j", modifiers: []))
            view.keyDown(with: navigationEvent)
            #expect(routedCharacters == ["j"])

            NSPasteboard.general.clearContents()
            let copyEvent = try #require(keyEvent(character: "c", modifiers: [.command]))
            #expect(view.performKeyEquivalent(with: copyEvent))
            #expect(NSPasteboard.general.string(forType: .string)?.contains("copyable needle") == true)
            #expect(routedCharacters == ["j"])

            view.prepareForClose()
        }
    }

    private func keyEvent(character: String, modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0
        )
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-reader-capability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
