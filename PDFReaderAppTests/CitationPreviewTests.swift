import AppKit
import PDFKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("Citation preview contracts")
@MainActor
struct CitationPreviewTests {
    @Test("classifier accepts only exact numeric markers inside bracketed numeric groups")
    func classifierContract() {
        #expect(CitationPreviewClassifier.marker(in: " 13 ") == 13)
        #expect(CitationPreviewClassifier.marker(in: "3, 4") == nil)
        #expect(CitationPreviewClassifier.marker(in: "Smith 2024") == nil)
        #expect(CitationPreviewClassifier.bracketedMarkers(in: "Prior work [3, 4; 5] agrees", containing: 4) == [3, 4, 5])
        #expect(CitationPreviewClassifier.bracketedMarkers(in: "Figure (4) and section 5", containing: 4) == nil)
        #expect(CitationPreviewClassifier.bracketedMarkers(in: "[3-5]", containing: 3) == nil)
    }

    @Test("Google Scholar URL preserves the complete reference as one encoded query")
    func googleScholarSearchURLContract() throws {
        let reference = "[7] Edward J. Hu et al. LoRA: Low-rank adaptation & fine-tuning."
        let url = try #require(googleScholarSearchURL(for: reference))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "scholar.google.com")
        #expect(components.queryItems == [URLQueryItem(name: "q", value: reference)])
        #expect(components.path == "/scholar")
    }

    @Test("extractor stops at the next marker, large gap, and bounded size")
    func extractorContract() {
        let lines = [
            CitationTextLine(text: "[3] Ada Author. A title", bounds: CGRect(x: 40, y: 700, width: 220, height: 12)),
            CitationTextLine(text: "continued venue text", bounds: CGRect(x: 40, y: 684, width: 220, height: 12)),
            CitationTextLine(text: "[4] Ben Author. Next title", bounds: CGRect(x: 40, y: 668, width: 220, height: 12)),
        ]
        #expect(CitationReferenceExtractor.extract(marker: 3, from: lines) == "[3] Ada Author. A title continued venue text")
        #expect(CitationReferenceExtractor.extract(marker: 9, from: lines) == nil)

        let gapped = [
            lines[0],
            CitationTextLine(text: "must not be joined", bounds: CGRect(x: 40, y: 650, width: 220, height: 12)),
        ]
        #expect(CitationReferenceExtractor.extract(marker: 3, from: gapped) == "[3] Ada Author. A title")
    }

    @Test("synthetic PDF resolves independent markers into a verified group without changing bytes")
    func syntheticResolverContract() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeCitationPreviewPDF(in: directory)
            let before = try PDFFixtureFactory.sha256(of: url)
            let document = try #require(PDFDocument(url: url))
            let links = links(on: try #require(document.page(at: 0)), in: document)
            let selected = try #require(links.first { link in
                link.rects.contains { rect in
                    (document.page(at: 0)?.selection(for: rect)?.string ?? "").contains("4")
                }
            })

            let resolution = CitationPreviewResolver(document: document).resolve(selected)
            guard case let .preview(group) = resolution else {
                Issue.record("Expected a citation preview group, got \(resolution)")
                return
            }
            #expect(group.items.map(\.marker) == [3, 4, 5])
            #expect(group.items[group.selectedIndex].marker == 4)
            #expect(group.items.allSatisfy { $0.referenceText.hasPrefix("[\($0.marker)]") })
            #expect(try PDFFixtureFactory.sha256(of: url) == before)
        }
    }

    @Test("overlay supports h/l, arrows, pointer tabs, Enter, Shift+Enter, Esc, and themed hints")
    func overlayContract() throws {
        let overlay = CitationPreviewOverlayView(frame: CGRect(x: 0, y: 0, width: 640, height: 420))
        let theme = AppKitTheme(themeID: .tokyoNight)
        overlay.apply(theme: theme)
        let group = CitationPreviewGroup(items: [
            CitationPreviewItem(marker: 3, destinationPageIndex: 1, destinationPoint: CGPoint(x: 40, y: 700), referenceText: "[3] First"),
            CitationPreviewItem(marker: 4, destinationPageIndex: 1, destinationPoint: CGPoint(x: 40, y: 660), referenceText: "[4] Second"),
        ], selectedIndex: 0)
        var committed: CitationPreviewItem?
        var searched: CitationPreviewItem?
        var dismissed = 0
        overlay.onCommit = { committed = $0 }
        overlay.onSearch = { searched = $0 }
        overlay.onDismiss = { dismissed += 1 }
        overlay.present(group: group, anchorRect: CGRect(x: 600, y: 390, width: 12, height: 10))

        let tabWidths = overlay.tabWidthsForTesting
        #expect(tabWidths.count == 2)
        #expect(abs(tabWidths[0] - tabWidths[1]) <= 1)
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "l"))))
        #expect(overlay.selectedMarkerForTesting == 4)
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "h"))))
        #expect(overlay.selectedMarkerForTesting == 3)
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "", keyCode: 124))))
        #expect(overlay.selectedMarkerForTesting == 4)
        overlay.pointerEnterTabForTesting(at: 0)
        #expect(overlay.selectedMarkerForTesting == 3)
        overlay.pointerActivateTabForTesting(at: 1)
        #expect(overlay.referenceTextForTesting == "[4] Second")
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "\r", modifiers: [.shift], keyCode: 36))))
        #expect(searched?.marker == 4)
        #expect(committed == nil)
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "\r", keyCode: 36))))
        #expect(committed?.marker == 4)
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "", keyCode: 53))))
        #expect(dismissed == 1)
        #expect(overlay.bounds.contains(overlay.cardFrameForTesting))

        let hint = overlay.keyHintForTesting
        for shortcut in ["h / l", "↩", "⇧↩", "Esc"] {
            let range = (hint.string as NSString).range(of: shortcut)
            #expect(range.location != NSNotFound)
            let color = hint.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
            #expect(color?.isEqual(theme[.accent]) == true)
        }
        #expect(hint.string.contains("↩  Move"))
        #expect(hint.string.contains("⇧↩  Scholar"))
    }

    @Test("reference text wraps to content height and scrolls only when the window requires it")
    func referenceTextLayoutContract() {
        let overlay = CitationPreviewOverlayView(frame: CGRect(x: 0, y: 0, width: 700, height: 700))
        overlay.apply(theme: AppKitTheme(themeID: .tokyoNight))
        let short = CitationPreviewGroup(items: [
            CitationPreviewItem(marker: 7, destinationPageIndex: 1, destinationPoint: .zero, referenceText: "[7] One-line reference"),
        ], selectedIndex: 0)
        overlay.present(group: short, anchorRect: CGRect(x: 300, y: 300, width: 10, height: 10))
        let shortHeight = overlay.cardFrameForTesting.height
        #expect(overlay.referenceFollowsTabsForTesting)
        #expect(!overlay.referenceRequiresScrollingForTesting)

        let longText = "[7] " + String(repeating: "Complete wrapped reference text remains available. ", count: 18)
        let long = CitationPreviewGroup(items: [
            CitationPreviewItem(marker: 7, destinationPageIndex: 1, destinationPoint: .zero, referenceText: longText),
        ], selectedIndex: 0)
        overlay.present(group: long, anchorRect: CGRect(x: 300, y: 300, width: 10, height: 10))
        #expect(overlay.referenceTextForTesting == longText)
        #expect(overlay.cardFrameForTesting.height > shortHeight)
        #expect(overlay.referenceFollowsTabsForTesting)

        overlay.frame.size.height = 300
        overlay.needsLayout = true
        overlay.layoutSubtreeIfNeeded()
        #expect(overlay.referenceRequiresScrollingForTesting)
        #expect(overlay.bounds.contains(overlay.cardFrameForTesting))
    }

    @Test("hint selection previews without history; Esc is inert and Enter records one jump")
    func endToEndHistoryContract() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeCitationPreviewPDF(in: directory)
            let session = try PDFOpenService().open(url: url)
            let coordinator = PaneCoordinator()
            var searchedReferences: [String] = []
            let controller = MainWindowController(
                coordinator: coordinator,
                theme: AppKitTheme(themeID: .tokyoNight),
                actionHandler: { _ in },
                citationSearchHandler: { searchedReferences.append($0) }
            )
            defer { controller.close(); session.prepareForClose() }
            #expect(coordinator.insert(session, into: .createIfEmpty))
            controller.rootView.layoutSubtreeIfNeeded()
            controller.window?.contentView?.layoutSubtreeIfNeeded()

            try openCitationPreview(controller: controller, session: session, marker: 4)
            #expect(session.currentPageNumber == 1)
            #expect(!session.canGoBack && !session.canGoForward)
            #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "", keyCode: 53))))
            #expect(controller.rootView.citationPreviewOverlay.isHidden)
            #expect(session.currentPageNumber == 1)
            #expect(!session.canGoBack && !session.canGoForward)

            try openCitationPreview(controller: controller, session: session, marker: 4)
            controller.presentCommandPalette()
            #expect(controller.rootView.citationPreviewOverlay.isHidden)
            #expect(!controller.rootView.citationPreviewOverlay.hasCallbacksForTesting)
            #expect(!session.canGoBack && !session.canGoForward)
            controller.dismissAllTransientOverlays()

            try openCitationPreview(controller: controller, session: session, marker: 4)
            controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: controller.window))
            #expect(controller.rootView.citationPreviewOverlay.isHidden)
            #expect(!controller.rootView.citationPreviewOverlay.hasCallbacksForTesting)
            #expect(!session.canGoBack && !session.canGoForward)
            try openCitationPreview(controller: controller, session: session, marker: 4)
            let searchedReference = controller.rootView.citationPreviewOverlay.referenceTextForTesting
            #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(
                characters: "\r",
                modifiers: [.shift],
                keyCode: 36
            ))))
            #expect(controller.rootView.citationPreviewOverlay.isHidden)
            #expect(searchedReferences == [searchedReference])
            #expect(session.currentPageNumber == 1)
            #expect(!session.canGoBack && !session.canGoForward)
            try openCitationPreview(controller: controller, session: session, marker: 4)
            #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36))))
            #expect(controller.rootView.citationPreviewOverlay.isHidden)
            #expect(session.currentPageNumber == 2)
            #expect(session.canGoBack)
            #expect(session.goBack() == .verifiedLanding)
            #expect(session.currentPageNumber == 1)
            #expect(!session.canGoBack)
            #expect(session.goForward() == .verifiedLanding)
            #expect(session.currentPageNumber == 2)
        }
    }

    @Test("real corpus positives resolve and author-year sample falls back without mutation")
    func realCorpusContract() throws {
        let samples: [(path: String, expected: [Int])] = [
            ("test-pdf/citation-annotation-corpus/NeurIPS/2022-federated-submodel-optimization.pdf", [3, 4, 5, 6]),
            ("test-pdf/citation-annotation-corpus/NeurIPS/2025-primacy-of-magnitude.pdf", [1, 2, 3, 4, 5]),
            ("test-pdf/citation-annotation-corpus/ICLR/2022-s4.pdf", [1, 13]),
        ]
        guard samples.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return }

        for sample in samples {
            let url = URL(fileURLWithPath: sample.path)
            let before = try PDFFixtureFactory.sha256(of: url)
            let document = try #require(PDFDocument(url: url))
            let resolver = CitationPreviewResolver(document: document)
            let found = allLinks(in: document).contains { link in
                guard case let .preview(group) = resolver.resolve(link) else { return false }
                return group.items.map(\.marker) == sample.expected
            }
            #expect(found, "Missing verified group \(sample.expected) in \(sample.path)")
            #expect(try PDFFixtureFactory.sha256(of: url) == before)
        }

        let fallbackURL = URL(fileURLWithPath: "test-pdf/citation-annotation-corpus/NeurIPS/2024-microadam.pdf")
        let before = try PDFFixtureFactory.sha256(of: fallbackURL)
        let fallbackDocument = try #require(PDFDocument(url: fallbackURL))
        let resolver = CitationPreviewResolver(document: fallbackDocument)
        #expect(allLinks(in: fallbackDocument).allSatisfy { link in
            guard case .activate = resolver.resolve(link) else { return false }
            return true
        })
        #expect(try PDFFixtureFactory.sha256(of: fallbackURL) == before)
    }

    private func openCitationPreview(
        controller: MainWindowController,
        session: ReaderSession,
        marker: Int
    ) throws {
        let links = LinkHintMerge.mergeLinks(session.linkTargets()).filter {
            !session.linkHintRects(for: $0, in: controller.rootView.linkHintOverlay).isEmpty
        }
        let index = try #require(links.firstIndex { link in
            guard case let .preview(group) = session.resolveLinkHint(link) else { return false }
            return group.items[group.selectedIndex].marker == marker
        })
        controller.presentLinkHints()
        let label = controller.rootView.linkHintOverlay.visibleLabels[index]
        for character in label {
            #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: String(character)))))
        }
        #expect(!controller.rootView.citationPreviewOverlay.isHidden)
    }

    private func allLinks(in document: PDFDocument) -> [ReaderLink] {
        (0..<document.pageCount).flatMap { index -> [ReaderLink] in
            guard let page = document.page(at: index) else { return [] }
            return links(on: page, in: document)
        }
    }

    private func links(on page: PDFPage, in document: PDFDocument) -> [ReaderLink] {
        let sourcePageIndex = document.index(for: page)
        return page.annotations.compactMap { annotation in
            guard let target = target(for: annotation, in: document) else { return nil }
            return ReaderLink(
                sourcePageIndex: sourcePageIndex,
                rects: [annotation.bounds],
                target: target,
                primaryLabelRect: annotation.bounds
            )
        }
    }

    private func target(for annotation: PDFAnnotation, in document: PDFDocument) -> ReaderLinkTarget? {
        if let action = annotation.action as? PDFActionGoTo,
           let page = action.destination.page,
           page.document === document {
            return .goTo(pageIndex: document.index(for: page), point: action.destination.point)
        }
        if let action = annotation.action as? PDFActionURL, let url = action.url {
            return .url(url.absoluteString)
        }
        if let url = annotation.url { return .url(url.absoluteString) }
        return nil
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("citation-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
