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

    @Test("author-year classifier joins split and hyphenated fragments and validates exact reference keys")
    func authorYearClassifierContract() throws {
        let simple = try #require(AuthorYearCitationClassifier.key(from: ["Germain et al.", "2015"]))
        #expect(simple.label == "Germain et al. 2015")
        #expect(simple.primarySurname == "Germain")
        #expect(AuthorYearCitationClassifier.validates(
            simple,
            referenceText: "Germain, P., Lacasse, A. A verified title. PMLR, 2015."
        ))
        #expect(!AuthorYearCitationClassifier.validates(
            simple,
            referenceText: "Letarte, G. A different title. PMLR, 2015."
        ))

        let wrapped = try #require(AuthorYearCitationClassifier.key(from: ["Swo-", "boda & Andres", "2017"]))
        #expect(wrapped.label == "Swoboda & Andres 2017")
        let suffixed = try #require(AuthorYearCitationClassifier.key(from: ["Smith et al.", "2020a"]))
        #expect(suffixed.yearSuffix == "a")
        #expect(AuthorYearCitationClassifier.key(from: ["et al.", "2020"]) == nil)
        #expect(AuthorYearCitationClassifier.key(from: ["Figure", "2020", "2021"]) == nil)
        #expect(AuthorYearCitationClassifier.isYearFragment("2020a"))
        #expect(!AuthorYearCitationClassifier.isYearFragment("Smith 2020"))
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
        #expect(citationScholarQuery(for: reference) == "Edward J. Hu et al. LoRA: Low-rank adaptation & fine-tuning.")
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
            #expect(group.items.map(\.label) == ["[3]", "[4]", "[5]"])
            #expect(group.items[group.selectedIndex].label == "[4]")
            #expect(group.items.allSatisfy { $0.referenceText.hasPrefix($0.label) })
            #expect(try PDFFixtureFactory.sha256(of: url) == before)
        }
    }

    @Test("overlay supports h/l, arrows, pointer tabs, Enter, Shift+Enter, Esc, and themed hints")
    func overlayContract() throws {
        let overlay = CitationPreviewOverlayView(frame: CGRect(x: 0, y: 0, width: 640, height: 420))
        let theme = AppKitTheme(themeID: .tokyoNight)
        overlay.apply(theme: theme)
        let group = CitationPreviewGroup(items: [
            CitationPreviewItem(label: "[3]", destinationPageIndex: 1, destinationPoint: CGPoint(x: 40, y: 700), referenceText: "[3] First"),
            CitationPreviewItem(label: "[4]", destinationPageIndex: 1, destinationPoint: CGPoint(x: 40, y: 660), referenceText: "[4] Second"),
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
        #expect(overlay.selectedLabelForTesting == "[4]")
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "h"))))
        #expect(overlay.selectedLabelForTesting == "[3]")
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "", keyCode: 124))))
        #expect(overlay.selectedLabelForTesting == "[4]")
        overlay.pointerEnterTabForTesting(at: 0)
        #expect(overlay.selectedLabelForTesting == "[3]")
        overlay.pointerActivateTabForTesting(at: 1)
        #expect(overlay.referenceTextForTesting == "[4] Second")
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "\r", modifiers: [.shift], keyCode: 36))))
        #expect(searched?.label == "[4]")
        #expect(committed == nil)
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "\r", keyCode: 36))))
        #expect(committed?.label == "[4]")
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

        let authorYearGroup = CitationPreviewGroup(items: [
            CitationPreviewItem(
                label: "Germain et al. 2015",
                destinationPageIndex: 1,
                destinationPoint: .zero,
                referenceText: "Germain, P. A reference. 2015."
            ),
            CitationPreviewItem(
                label: "Letarte et al. 2019",
                destinationPageIndex: 1,
                destinationPoint: .zero,
                referenceText: "Letarte, G. A reference. 2019."
            ),
        ], selectedIndex: 0)
        overlay.present(group: authorYearGroup, anchorRect: CGRect(x: 300, y: 300, width: 10, height: 10))
        #expect(overlay.visibleLabelsForTesting == ["Germain et al. 2015", "Letarte et al. 2019"])
        #expect(abs((overlay.tabWidthsForTesting.max() ?? 0) - (overlay.tabWidthsForTesting.min() ?? 0)) <= 1)
    }

    @Test("reference text wraps to content height and scrolls only when the window requires it")
    func referenceTextLayoutContract() {
        let overlay = CitationPreviewOverlayView(frame: CGRect(x: 0, y: 0, width: 700, height: 700))
        overlay.apply(theme: AppKitTheme(themeID: .tokyoNight))
        let short = CitationPreviewGroup(items: [
            CitationPreviewItem(label: "[7]", destinationPageIndex: 1, destinationPoint: .zero, referenceText: "[7] One-line reference"),
        ], selectedIndex: 0)
        overlay.present(group: short, anchorRect: CGRect(x: 300, y: 300, width: 10, height: 10))
        let shortHeight = overlay.cardFrameForTesting.height
        #expect(overlay.referenceFollowsTabsForTesting)
        #expect(!overlay.referenceRequiresScrollingForTesting)

        let longText = "[7] " + String(repeating: "Complete wrapped reference text remains available. ", count: 18)
        let long = CitationPreviewGroup(items: [
            CitationPreviewItem(label: "[7]", destinationPageIndex: 1, destinationPoint: .zero, referenceText: longText),
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
            #expect(searchedReferences == [citationScholarQuery(for: searchedReference)])
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

    @Test("author-year preview resolution remains nonmutating until Move commits one history jump")
    func authorYearHistoryContract() throws {
        let path = "test-pdf/citation-annotation-corpus/ICML/2022-pac-bayesian-rate-efficient.pdf"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        let before = try PDFFixtureFactory.sha256(of: url)
        let document = try #require(PDFDocument(url: url))
        let resolver = CitationPreviewResolver(document: document)
        let group = try #require(allLinks(in: document).compactMap { link -> CitationPreviewGroup? in
            guard case let .preview(group) = resolver.resolve(link),
                  group.items[group.selectedIndex].label == "Germain et al. 2015"
            else { return nil }
            return group
        }.first)
        let item = group.items[group.selectedIndex]

        let session = try PDFOpenService().open(url: url)
        let coordinator = PaneCoordinator()
        let controller = MainWindowController(
            coordinator: coordinator,
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { _ in }
        )
        defer { controller.close(); session.prepareForClose() }
        #expect(coordinator.insert(session, into: .createIfEmpty))
        controller.rootView.layoutSubtreeIfNeeded()
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        #expect(session.currentPageNumber == 1)
        #expect(!session.canGoBack && !session.canGoForward)
        session.activateLink(item.destination)
        #expect(session.currentPageNumber == item.destinationPageIndex + 1)
        #expect(session.canGoBack && !session.canGoForward)
        #expect(session.goBack() == .verifiedLanding)
        #expect(session.currentPageNumber == 1)
        #expect(try PDFFixtureFactory.sha256(of: url) == before)
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
                return group.items.map(\.label) == sample.expected.map { "[\($0)]" }
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

    @Test("NeurIPS 2025 multiline numeric groups are selection-invariant and references are complete")
    func neurIPS2025PhaseOneContract() throws {
        let path = "test-pdf/citation-annotation-corpus/NeurIPS/2025-primacy-of-magnitude.pdf"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        let before = try PDFFixtureFactory.sha256(of: url)
        let document = try #require(PDFDocument(url: url))
        let resolver = CitationPreviewResolver(document: document)
        let resolutions = allLinks(in: document).compactMap { link -> CitationPreviewGroup? in
            guard case let .preview(group) = resolver.resolve(link) else { return nil }
            return group
        }
        let expectedGroups = [
            [1, 2, 3, 4, 5],
            [23, 10, 24, 25, 26, 27, 28, 29],
            [43, 44, 39],
            [30, 38, 39],
        ]
        for expected in expectedGroups {
            let matching = resolutions.filter { $0.items.map(\.label) == expected.map { "[\($0)]" } }
            let selectedLabels = Set(matching.map { $0.items[$0.selectedIndex].label })
            #expect(selectedLabels == Set(expected.map { "[\($0)]" }), "Not every marker selected the complete group \(expected)")
        }

        let openingGroup = try #require(resolutions.first { $0.items.map(\.label) == ["[1]", "[2]", "[3]", "[4]", "[5]"] })
        let first = try #require(openingGroup.items.first { $0.label == "[1]" })
        #expect(first.referenceText == "[1] OpenAI Team. Language models are few-shot learners. In NeurIPS, 2020.")
        #expect(citationScholarQuery(for: first.referenceText) == "OpenAI Team. Language models are few-shot learners. In NeurIPS, 2020.")
        #expect(try PDFFixtureFactory.sha256(of: url) == before)
    }

    @Test("ICML two-column bibliography candidates preserve left and right entries without cross-column mixing")
    func icmlTwoColumnDestinationContract() throws {
        let fixtures: [(path: String, source: String, expected: String, rejectedNeighbor: String)] = [
            (
                "test-pdf/citation-annotation-corpus/ICML/2022-pac-bayesian-rate-efficient.pdf",
                "James",
                "James, G. M. Majority vote classifiers: theory and applica- tions. Stanford University, 1998.",
                "Vidot, E."
            ),
            (
                "test-pdf/citation-annotation-corpus/ICML/2022-pac-bayesian-rate-efficient.pdf",
                "Pradhan et al.",
                "Pradhan, S. S., Kusuma, J., and Ramchandran, K. Dis- tributed compression in a dense microsensor network. IEEE Signal Processing Magazine, 19(2):51–60, 2002.",
                "Germain, P."
            ),
            (
                "test-pdf/citation-annotation-corpus/ICML/2023-clusterfug.pdf",
                "Hu",
                "Hu, T. C. Multi-commodity network flows. Operations",
                "Bailoni, A."
            ),
        ]
        guard fixtures.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return }

        for fixture in fixtures {
            let url = URL(fileURLWithPath: fixture.path)
            let before = try PDFFixtureFactory.sha256(of: url)
            let document = try #require(PDFDocument(url: url))
            let destination = try #require(goToDestination(sourceText: fixture.source, in: document))
            let page = try #require(destination.page)
            let candidates = CitationReferenceEntryExtractor.candidates(
                destinationPoint: destination.point,
                on: page
            )
            let selected = try #require(CitationReferenceEntryExtractor.entry(
                destinationPoint: destination.point,
                on: page
            ))
            #expect(selected.rawText.hasPrefix(fixture.expected))
            #expect(!selected.rawText.contains(fixture.rejectedNeighbor))
            let exact = try #require(candidates.first { $0.rawText.hasPrefix(fixture.expected) })
            #expect(!exact.rawText.contains(fixture.rejectedNeighbor))
            #expect(Set(candidates.map(\.columnIndex)) == [0, 1])
            #expect(try PDFFixtureFactory.sha256(of: url) == before)
        }
    }

    @Test("column detector requires repeated bilateral line geometry")
    func columnDetectorContract() {
        let page = CGRect(x: 0, y: 0, width: 600, height: 800)
        let singleColumn = [
            CitationTextLine(text: "one", bounds: CGRect(x: 100, y: 700, width: 390, height: 10)),
            CitationTextLine(text: "two", bounds: CGRect(x: 100, y: 680, width: 390, height: 10)),
            CitationTextLine(text: "three", bounds: CGRect(x: 100, y: 660, width: 390, height: 10)),
        ]
        #expect(CitationReferenceEntryExtractor.layout(of: singleColumn, pageBounds: page) == .singleColumn)

        let twoColumn = (0..<4).flatMap { row in
            let y = CGFloat(700 - (row * 20))
            return [
                CitationTextLine(text: "left", bounds: CGRect(x: 50, y: y, width: 230, height: 10)),
                CitationTextLine(text: "right", bounds: CGRect(x: 320, y: y, width: 230, height: 10)),
            ]
        }
        #expect(CitationReferenceEntryExtractor.layout(of: twoColumn, pageBounds: page) == .twoColumns(splitX: 300))
    }

    @Test("ICML author-year fragments resolve from author or year without mutating corpus PDFs")
    func icmlAuthorYearPreviewContract() throws {
        var fixtures: [(path: String, sources: [String], label: String, referencePrefix: String)] = [
            (
                "test-pdf/citation-annotation-corpus/ICML/2022-pac-bayesian-rate-efficient.pdf",
                ["James", "1998"],
                "James 1998",
                "James, G. M. Majority vote classifiers"
            ),
            (
                "test-pdf/citation-annotation-corpus/ICML/2022-pac-bayesian-rate-efficient.pdf",
                ["Pradhan et al.", "2002"],
                "Pradhan et al. 2002",
                "Pradhan, S. S., Kusuma, J., and Ramchandran, K."
            ),
            (
                "test-pdf/citation-annotation-corpus/ICML/2022-pac-bayesian-rate-efficient.pdf",
                ["Sagi &", "Rokach", "2018"],
                "Sagi & Rokach 2018",
                "Sagi, O. and Rokach, L."
            ),
            (
                "test-pdf/citation-annotation-corpus/ICML/2023-clusterfug.pdf",
                ["Hu", "1963"],
                "Hu 1963",
                "Hu, T. C. Multi-commodity network flows."
            ),
            (
                "test-pdf/citation-annotation-corpus/ICML/2023-clusterfug.pdf",
                ["Swo-", "boda & Andres", "2017"],
                "Swoboda & Andres 2017",
                "Swoboda, P. and Andres, B."
            ),
        ]
        fixtures.append(contentsOf: [
            (
                path: "test-pdf/citation-annotation-corpus/ICML/2024-charmer.pdf",
                sources: ["Belinkov & Bisk"],
                label: "Belinkov & Bisk 2018",
                referencePrefix: "Belinkov, Y. and Bisk, Y."
            ),
            (
                path: "test-pdf/citation-annotation-corpus/ICML/2024-charmer.pdf",
                sources: ["Morris et al.", "2020a"],
                label: "Morris et al. 2020a",
                referencePrefix: "Morris, J., Lifland, E., Lanchantin, J., Ji, Y., and Qi, Y."
            ),
            (
                path: "test-pdf/citation-annotation-corpus/ICML/2025-code-vae.pdf",
                sources: ["Kingma & Welling"],
                label: "Kingma & Welling 2014",
                referencePrefix: "Kingma, D. P. and Welling, M."
            ),
        ])
        guard fixtures.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return }

        let expectedGroups = [
            "James 1998": ["James 1998", "Lacasse et al. 2006"],
            "Pradhan et al. 2002": ["Pradhan et al. 2002", "Xiao et al. 2006"],
            "Sagi & Rokach 2018": ["Sagi & Rokach 2018"],
            "Hu 1963": ["Hu 1963"],
            "Morris et al. 2020a": ["Morris et al. 2020a"],
            "Belinkov & Bisk 2018": ["Belinkov & Bisk 2018", "Alzantot et al. 2018"],
            "Kingma & Welling 2014": ["Kingma & Welling 2014", "Rezende et al. 2014"],
            "Swoboda & Andres 2017": [
                "Swoboda & Andres 2017",
                "Lange et al. 2018",
                "Abbas & Swoboda 2022",
            ],
        ]
        for fixture in fixtures {
            let url = URL(fileURLWithPath: fixture.path)
            let before = try PDFFixtureFactory.sha256(of: url)
            let document = try #require(PDFDocument(url: url))
            let resolver = CitationPreviewResolver(document: document)
            for source in fixture.sources {
                let matches = links(sourceText: source, in: document).compactMap { link -> CitationPreviewGroup? in
                    guard case let .preview(group) = resolver.resolve(link),
                          group.items[group.selectedIndex].label == fixture.label
                    else { return nil }
                    return group
                }
                let group = try #require(matches.first)
                #expect(group.items.map(\.label) == expectedGroups[fixture.label])
                let selected = group.items[group.selectedIndex]
                #expect(selected.referenceText.hasPrefix(fixture.referencePrefix))
            }
            #expect(try PDFFixtureFactory.sha256(of: url) == before)
        }

        let ambiguousURL = URL(fileURLWithPath: "test-pdf/citation-annotation-corpus/ICML/2025-code-vae.pdf")
        let ambiguousBefore = try PDFFixtureFactory.sha256(of: ambiguousURL)
        let ambiguousDocument = try #require(PDFDocument(url: ambiguousURL))
        let ambiguousResolver = CitationPreviewResolver(document: ambiguousDocument)
        let shorthandAuthorLink = try #require(links(sourceText: "Goodman", in: ambiguousDocument).first { link in
            guard case let .goTo(_, point?) = link.target else { return false }
            return abs(point.y - 216.845) < 0.5
        })
        guard case .activate = ambiguousResolver.resolve(shorthandAuthorLink) else {
            Issue.record("Expected partially resolvable shorthand group to fall back")
            return
        }
        let ambiguousLink = try #require(links(sourceText: "2019", in: ambiguousDocument).first { link in
            guard case let .goTo(_, point?) = link.target else { return false }
            return abs(point.y - 161.054) < 0.5
        })
        guard case .activate = ambiguousResolver.resolve(ambiguousLink) else {
            Issue.record("Expected omitted-author shorthand year to fall back")
            return
        }
        #expect(try PDFFixtureFactory.sha256(of: ambiguousURL) == ambiguousBefore)
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
            return group.items[group.selectedIndex].label == "[\(marker)]"
        })
        controller.presentLinkHints()
        let label = controller.rootView.linkHintOverlay.visibleLabels[index]
        for character in label {
            #expect(controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: String(character)))))
        }
        #expect(!controller.rootView.citationPreviewOverlay.isHidden)
    }

    private func goToDestination(sourceText: String, in document: PDFDocument) -> PDFDestination? {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                guard let action = annotation.action as? PDFActionGoTo else { continue }
                let text = (page.selection(for: annotation.bounds)?.string ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text == sourceText { return action.destination }
            }
        }
        return nil
    }
    private func links(sourceText: String, in document: PDFDocument) -> [ReaderLink] {
        var result: [ReaderLink] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let sourcePageIndex = document.index(for: page)
            for annotation in page.annotations {
                let text = (page.selection(for: annotation.bounds)?.string ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard text == sourceText, let target = target(for: annotation, in: document) else { continue }
                result.append(ReaderLink(
                    sourcePageIndex: sourcePageIndex,
                    rects: [annotation.bounds],
                    target: target,
                    primaryLabelRect: annotation.bounds
                ))
            }
        }
        return result
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
