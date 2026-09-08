import AppKit
import CoreText
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
        #expect(CitationPreviewClassifier.marker(in: "[7]") == 7)
        #expect(CitationPreviewClassifier.marker(in: " [ 13 ] ") == 13)
        #expect(CitationPreviewClassifier.marker(in: "[3, 4]") == nil)
        #expect(CitationPreviewClassifier.marker(in: "[7") == nil)
        #expect(CitationPreviewClassifier.marker(in: "3, 4") == nil)
        #expect(CitationPreviewClassifier.marker(in: "Smith 2024") == nil)
        #expect(CitationPreviewClassifier.bracketedMarkers(in: "Prior work [3, 4; 5] agrees", containing: 4) == [3, 4, 5])
        #expect(CitationPreviewClassifier.bracketedMarkers(in: "Figure (4) and section 5", containing: 4) == nil)
        #expect(CitationPreviewClassifier.bracketedMarkers(in: "[3-5]", containing: 3) == [3, 4, 5])
        #expect(CitationPreviewClassifier.bracketedMarkers(in: "[1, 3–5, 8]", containing: 4) == [1, 3, 4, 5, 8])
        #expect(CitationPreviewClassifier.bracketedMarkers(in: "[5–3]", containing: 3) == nil)
        #expect(CitationPreviewClassifier.bracketedMarkers(in: "[1–9999]", containing: 1) == nil)
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
        let forms: [([String], String)] = [
            (["(Alpha et al.,", "2020)"], "Alpha et al. 2020"),
            (["[Beta and Gamma,", "2021]"], "Beta and Gamma 2021"),
            (["Delta", "2022"], "Delta 2022"),
            (["Epsilon’s", "(2023)"], "Epsilon 2023"),
        ]
        for (fragments, expectedLabel) in forms {
            #expect(AuthorYearCitationClassifier.key(from: fragments)?.label == expectedLabel)
        }
        let suffixed = try #require(AuthorYearCitationClassifier.key(from: ["Smith et al.", "2020a"]))
        let possessive = try #require(AuthorYearCitationClassifier.key(from: ["Chomsky’s", "1957"]))
        #expect(possessive.label == "Chomsky 1957")
        let givenNameFirst = try #require(AuthorYearCitationClassifier.key(from: ["Warstadt et al.", "2019"]))
        #expect(AuthorYearCitationClassifier.validates(
            givenNameFirst,
            referenceText: "Alex Warstadt, Amanpreet Singh, and Samuel R. Bowman. 2019. Neural Network Acceptability Judgments."
        ))
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
        #expect(citationScholarQuery(for: "24. Lee, Lin & Fanti. Supplemental reference") == "Lee, Lin & Fanti. Supplemental reference")
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
        #expect(CitationReferenceExtractor.extract(
            marker: 24,
            from: [CitationTextLine(text: "24. Lee, Lin & Fanti. Supplemental reference", bounds: CGRect(x: 40, y: 700, width: 220, height: 12))]
        ) == "24. Lee, Lin & Fanti. Supplemental reference")
        #expect(CitationReferenceExtractor.extract(
            marker: 2019,
            from: [CitationTextLine(text: "2019.", bounds: CGRect(x: 40, y: 700, width: 40, height: 12))]
        ) == nil)

        let gapped = [
            lines[0],
            CitationTextLine(text: "must not be joined", bounds: CGRect(x: 40, y: 650, width: 220, height: 12)),
        ]
        #expect(CitationReferenceExtractor.extract(marker: 3, from: gapped) == "[3] Ada Author. A title")
    }

    @Test("mapped numeric lists preserve every member, source order and selected annotation")
    func mappedNumericListContracts() throws {
        let cases: [(String, Int, [Int], [Int])] = [
            ("D01-primacy.pdf", 0, [39, 40, 41], [36, 37, 30]),
            ("D01-primacy.pdf", 0, [1, 2, 3, 4, 5], [1, 2, 3, 4, 5]),
            ("D02-portfolio.pdf", 1, [4, 5], [7, 8]),
            ("D04-spegc.pdf", 1, [32, 33], [67, 68]),
            ("D01-primacy.pdf", 0, Array(25...32), [23, 10, 24, 25, 26, 27, 28, 29]),
            ("D07-realappiance.pdf", 2, [4], [9]),
            ("D07-realappiance.pdf", 2, [5], [8]),
            ("D07-realappiance.pdf", 2, [6], [6]),
            ("D07-realappiance.pdf", 2, [7], [3]),
            ("D07-realappiance.pdf", 2, [8], [2]),
            ("D03-neuralplexer3.pdf", 3, [2, 3], [12, 13, 14]),
            ("D04-spegc.pdf", 0, Array(9...14), [44, 45, 46, 56, 61, 69, 70]),
        ]
        for (file, pageIndex, annotations, members) in cases {
            let url = URL(fileURLWithPath: "docs/citation-papers/\(file)")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let document = try #require(PDFDocument(url: url))
            let page = try #require(document.page(at: pageIndex))
            let resolver = CitationPreviewResolver(document: document)
            for annotationIndex in annotations {
                let annotation = try #require(page.annotations.indices.contains(annotationIndex) ? page.annotations[annotationIndex] : nil)
                let link = try #require(links(on: page, in: document).first { $0.rects.contains(annotation.bounds) })
                let number = try #require(CitationPreviewClassifier.marker(in: page.selection(for: annotation.bounds)?.string ?? ""))
                let selectedIndex = try #require(members.firstIndex(of: number))
                guard case let .preview(group) = resolver.resolve(link) else {
                    Issue.record("\(file) p\(pageIndex + 1) a\(annotationIndex) did not preview")
                    continue
                }
                #expect(group.items.map(\.label) == members.map { "[\($0)]" })
                #expect(group.selectedIndex == selectedIndex)
                #expect(group.items.allSatisfy { $0.isResolved })
                if file == "D03-neuralplexer3.pdf" {
                    #expect(group.items[1].referenceText.contains("Kornilov"))
                    #expect(group.items[1].destinationPageIndex == 10)
                }
                if file == "D04-spegc.pdf", members.first == 44 {
                    #expect(group.items[1].referenceText.contains("Niu"))
                    #expect(group.items[1].destinationPageIndex == 9)
                }
                #expect(group.items[selectedIndex].destination == link.target)
            }
        }
    }
    @Test("numeric groups retain a member whose source annotation is missing")
    func missingNumericLinkMember() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeCitationPreviewPDF(in: directory)
            let document = try #require(PDFDocument(url: url))
            let page = try #require(document.page(at: 0))
            let missing = try #require(page.annotations.first {
                page.selection(for: $0.bounds)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "4"
            })
            page.removeAnnotation(missing)
            let selected = try #require(links(on: page, in: document).first {
                page.selection(for: $0.rects[0])?.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "3"
            })
            guard case let .preview(group) = CitationPreviewResolver(document: document).resolve(selected) else {
                Issue.record("Partially linked citation group must remain visible")
                return
            }
            #expect(group.items.map(\.label) == ["[3]", "[4]", "[5]"])
            #expect(group.items[1].state == .unresolved(reason: .missingTarget))
            #expect(group.items[1].destination == nil)
            #expect(group.items[0].isResolved && group.items[2].isResolved)
        }
    }

    @Test("reference lookup rejects nonfinite and sentinel destination coordinates")
    func destinationCoordinateGuards() {
        let page = PDFPage()
        let sentinel = CGFloat(Float.greatestFiniteMagnitude)
        let points = [
            CGPoint(x: CGFloat.nan, y: 700),
            CGPoint(x: 40, y: CGFloat.infinity),
            CGPoint(x: -sentinel, y: 700),
            CGPoint(x: 40, y: sentinel),
        ]
        for point in points {
            #expect(!CitationReferenceEntryExtractor.isUsableDestinationPoint(point))
            #expect(CitationReferenceEntryExtractor.numericEntry(marker: 7, destinationPoint: point, on: page) == nil)
            #expect(CitationReferenceEntryExtractor.entry(destinationPoint: point, on: page) == nil)
            #expect(CitationReferenceEntryExtractor.candidates(destinationPoint: point, on: page).isEmpty)
        }
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

    @Test("numeric lookup failures stay visible as unresolved members with their native target")
    func unresolvedResolverContract() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeCitationPreviewPDF(in: directory)
            let document = try #require(PDFDocument(url: url))
            let sourcePage = try #require(document.page(at: 0))
            let destinationPage = try #require(document.page(at: 1))
            let annotation = try #require(sourcePage.annotations.first { annotation in
                (sourcePage.selection(for: annotation.bounds)?.string ?? "").contains("4")
            })
            let nativeTarget = ReaderLinkTarget.goTo(
                pageIndex: 1,
                point: CGPoint(x: 40, y: 40)
            )
            annotation.action = PDFActionGoTo(
                destination: PDFDestination(page: destinationPage, at: CGPoint(x: 40, y: 40))
            )
            let link = ReaderLink(
                sourcePageIndex: 0,
                rects: [annotation.bounds],
                target: nativeTarget,
                primaryLabelRect: annotation.bounds
            )

            guard case let .preview(group) = CitationPreviewResolver(document: document).resolve(link) else {
                Issue.record("A verified citation context should retain an unresolved member")
                return
            }
            let selected = group.items[group.selectedIndex]
            #expect(selected.label == "[4]")
            #expect(selected.state == .unresolved(reason: .referenceUnavailable))
            #expect(selected.destination == nativeTarget)
            #expect(selected.referenceText.isEmpty)
        }
    }
    @Test("single-reference navigation remains selected and dismissed navigation is inert")
    func singleReferenceNavigation() throws {
        let overlay = CitationPreviewOverlayView(frame: CGRect(x: 0, y: 0, width: 640, height: 420))
        let item = CitationPreviewItem(label: "[1]", destinationPageIndex: 1, destinationPoint: .zero, referenceText: "Only reference")
        overlay.present(group: CitationPreviewGroup(items: [item], selectedIndex: 0), anchorRect: .zero)
        for (characters, modifiers, keyCode) in [
            ("h", NSEvent.ModifierFlags(), UInt16(0)), ("l", [], 0),
            ("\t", [], 48), ("\t", [.shift], 48),
        ] {
            #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: characters, modifiers: modifiers, keyCode: keyCode))))
            #expect(overlay.selectedLabelForTesting == "[1]")
        }
        overlay.dismiss()
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "\t", keyCode: 48))))
        #expect(overlay.selectedLabelForTesting == nil)
    }
    @Test("unresolved members remain selectable but Enter and Scholar are inert")
    func unresolvedSelectionActions() throws {
        let overlay = CitationPreviewOverlayView(frame: CGRect(x: 0, y: 0, width: 640, height: 420))
        let unresolved = CitationPreviewItem(
            label: "[9]",
            destination: .goTo(pageIndex: 4, point: nil),
            referenceText: "",
            state: .unresolved(reason: .referenceUnavailable)
        )
        let resolved = CitationPreviewItem(
            label: "[10]",
            destination: .goTo(pageIndex: 5, point: CGPoint(x: 40, y: 700)),
            referenceText: "[10] Verified reference",
            state: .resolved
        )
        var committed: CitationPreviewItem?
        var searched: CitationPreviewItem?
        overlay.onCommit = { committed = $0 }
        overlay.onSearch = { searched = $0 }
        overlay.present(
            group: CitationPreviewGroup(items: [unresolved, resolved], selectedIndex: 0),
            anchorRect: .zero
        )

        #expect(overlay.selectedStateForTesting == .unresolved(reason: .referenceUnavailable))
        #expect(unresolved.destinationPoint == nil)
        #expect(unresolved.destinationPageIndex == Optional(4))
        #expect(overlay.selectedIsResolvedForTesting == false)
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "\r", keyCode: 36))))
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "\r", modifiers: [.shift], keyCode: 36))))
        #expect(committed == nil)
        #expect(searched == nil)
        #expect(!overlay.isHidden)

        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "l"))))
        #expect(overlay.selectedLabelForTesting == "[10]")
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "\r", keyCode: 36))))
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "\r", modifiers: [.shift], keyCode: 36))))
        #expect(committed?.label == "[10]")
        #expect(searched?.label == "[10]")
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
        for (characters, modifiers, keyCode, expected) in [
            ("l", NSEvent.ModifierFlags(), UInt16(0), "[3]"),
            ("h", [], 0, "[4]"),
            ("\t", [], 48, "[3]"),
            ("\t", [.shift], 48, "[4]"),
            ("", [], 124, "[3]"),
            ("", [], 123, "[4]"),
        ] {
            #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: characters, modifiers: modifiers, keyCode: keyCode))))
            #expect(overlay.selectedLabelForTesting == expected)
        }
        #expect(!overlay.handleKeyDown(try #require(makeKeyEvent(characters: "\t", modifiers: [.control], keyCode: 48))))
        #expect(overlay.selectedLabelForTesting == "[4]")
        #expect(committed == nil)
        #expect(searched == nil)
        #expect(dismissed == 0)
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
        for shortcut in ["h/l", "⇥/⇧⇥", "↩", "⇧↩", "Esc"] {
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

    @Test("citation preview defaults OFF, persists Shift-C toggles, and bypasses resolution when disabled")
    func experimentalToggleContract() throws {
        try withTemporaryDirectory { directory in
            let pdfURL = try PDFFixtureFactory.makeCitationPreviewPDF(in: directory)
            let stateURL = directory.appendingPathComponent("state.json")
            let settingsStore = CitationPreviewSettingsStore(fileURL: stateURL)
            let controller = ApplicationController(
                configService: ConfigService(
                    source: ConfigFileSource(url: directory.appendingPathComponent("missing-config.toml"))
                ),
                themeStore: ThemeSelectionStore(fileURL: stateURL),
                indicatorSettingsStore: LinkDestinationIndicatorSettingsStore(fileURL: stateURL),
                recentFilesStore: RecentFilesStore(fileURL: stateURL),
                citationPreviewSettingsStore: settingsStore,
                terminationHandler: {}
            )
            defer {
                while controller.coordinator.closeActiveTab() {}
                controller.mainWindowController.close()
            }
            #expect(!controller.isCitationPreviewEnabled)
            #expect(settingsStore.load() == .absent)
            #expect(controller.openDocument(at: pdfURL))
            let session = try #require(controller.coordinator.activeSession as? ReaderSession)
            let sourceDocument = try #require(PDFDocument(url: pdfURL))
            let link = try #require(allLinks(in: sourceDocument).first { link in
                link.rects.contains { rect in
                    (sourceDocument.page(at: 0)?.selection(for: rect)?.string ?? "").contains("4")
                }
            })
            guard case .activate = session.resolveLinkHint(link) else {
                Issue.record("Preview must bypass resolution while experimental mode is OFF")
                return
            }

            #expect(controller.mainWindowController.routeKeyEventForTesting(try #require(makeKeyEvent(
                characters: "C",
                modifiers: [.shift],
                keyCode: 8
            ))))
            #expect(controller.isCitationPreviewEnabled)
            #expect(controller.mainWindowController.rootView.statusBar.presentation.isExperimentalMode)
            #expect(settingsStore.load() == .selected(true))
            guard case let .preview(group) = session.resolveLinkHint(link) else {
                Issue.record("Preview must resolve after enabling experimental mode")
                return
            }
            #expect(controller.mainWindowController.rootView.statusBar.presentation.detail.contains("Experimental · ON"))
            controller.mainWindowController.rootView.citationPreviewOverlay.present(
                group: group,
                anchorRect: CGRect(x: 100, y: 100, width: 10, height: 10)
            )
            controller.dispatch(.citationPreviewToggle)
            #expect(!controller.isCitationPreviewEnabled)
            #expect(!controller.mainWindowController.rootView.statusBar.presentation.isExperimentalMode)
            #expect(controller.mainWindowController.rootView.citationPreviewOverlay.isHidden)
            guard case .activate = session.resolveLinkHint(link) else {
                Issue.record("Disabling must restore ordinary link activation immediately")
                return
            }
            controller.dispatch(.citationPreviewToggle)
            #expect(controller.isCitationPreviewEnabled)
            #expect(settingsStore.load() == .selected(true))

            let restarted = ApplicationController(
                configService: ConfigService(
                    source: ConfigFileSource(url: directory.appendingPathComponent("missing-config.toml"))
                ),
                themeStore: ThemeSelectionStore(fileURL: stateURL),
                indicatorSettingsStore: LinkDestinationIndicatorSettingsStore(fileURL: stateURL),
                recentFilesStore: RecentFilesStore(fileURL: stateURL),
                citationPreviewSettingsStore: settingsStore,
                terminationHandler: {}
            )
            defer { restarted.mainWindowController.close() }
            #expect(restarted.isCitationPreviewEnabled)
            #expect(restarted.mainWindowController.rootView.statusBar.presentation.isExperimentalMode)
            #expect(restarted.openDocument(at: pdfURL))
            #expect(restarted.mainWindowController.rootView.statusBar.presentation.isExperimentalMode)
            #expect(restarted.coordinator.closeActiveTab())
            #expect(restarted.mainWindowController.rootView.statusBar.presentation.isExperimentalMode)
            restarted.dispatch(.citationPreviewToggle)
            #expect(!restarted.isCitationPreviewEnabled)
            #expect(settingsStore.load() == .selected(false))
            #expect(restarted.mainWindowController.rootView.statusBar.presentation.detail.contains("Experimental · OFF"))
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
        session.activateLink(try #require(item.destination))
        let destinationPageIndex = try #require(item.destinationPageIndex)
        #expect(session.currentPageNumber == destinationPageIndex + 1)
        #expect(session.canGoBack && !session.canGoForward)
        #expect(session.goBack() == .verifiedLanding)
        #expect(session.currentPageNumber == 1)
        #expect(try PDFFixtureFactory.sha256(of: url) == before)
    }
    @Test("real corpus positives resolve author-year and noncitation links stay ordinary")
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
        guard FileManager.default.fileExists(atPath: fallbackURL.path) else { return }
        let before = try PDFFixtureFactory.sha256(of: fallbackURL)
        let fallbackDocument = try #require(PDFDocument(url: fallbackURL))
        let resolver = CitationPreviewResolver(document: fallbackDocument)
        let kingmaLink = try #require(allLinks(in: fallbackDocument).first { link in
            guard case .goTo = link.target,
                  let page = fallbackDocument.page(at: link.sourcePageIndex),
                  let rect = link.rects.first
            else { return false }
            return (page.selection(for: rect)?.string ?? "").localizedCaseInsensitiveContains("Kingma")
        })
        guard case let .preview(group) = resolver.resolve(kingmaLink) else {
            Issue.record("MicroAdam Kingma and Ba citation should resolve as an author-year preview")
            return
        }
        #expect(group.items.count == 1)
        #expect(group.items[group.selectedIndex].label == "Kingma and Ba 2014")
        #expect(group.items[group.selectedIndex].destination == kingmaLink.target)

        let urlLink = try #require(allLinks(in: fallbackDocument).first { link in
            if case .url = link.target { return true }
            return false
        })
        guard case .activate = resolver.resolve(urlLink) else {
            Issue.record("MicroAdam URL links must remain ordinary activations")
            return
        }
        #expect(try PDFFixtureFactory.sha256(of: fallbackURL) == before)
    }

    @Test("D01 N01 resolves a single [7] from its source geometry")
    func primacySingleNumericContract() throws {
        let path = "test-pdf/citation-annotation-corpus/NeurIPS/2025-primacy-of-magnitude.pdf"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let document = try #require(PDFDocument(url: URL(fileURLWithPath: path)))
        let sourcePage = try #require(document.page(at: 0))
        let annotation = try #require(sourcePage.annotations.indices.contains(12) ? sourcePage.annotations[12] : nil)
        let link = try #require(links(on: sourcePage, in: document).first { $0.rects.contains(annotation.bounds) })
        guard case let .preview(group) = CitationPreviewResolver(document: document).resolve(link) else {
            Issue.record("D01 p1 a12 should resolve as a numeric single preview")
            return
        }
        let item = group.items[group.selectedIndex]
        #expect(group.items.map(\.label) == ["[7]"])
        #expect(item.state == .resolved)
        #expect(item.destination == link.target)
        #expect(item.destinationPageIndex == Optional(9))
        #expect(item.referenceText.contains("Edward J. Hu"))
        #expect(item.referenceText.localizedCaseInsensitiveContains("LoRA"))

    }
    @Test("D03 N05 resolves [24] against the supplemental bibliography, not main references")
    func neuralPlexerSupplementalSingleContract() throws {
        let path = "docs/citation-papers/D03-neuralplexer3.pdf"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let document = try #require(PDFDocument(url: URL(fileURLWithPath: path)))
        let sourcePage = try #require(document.page(at: 27))
        let link = try #require(links(on: sourcePage, in: document).first { link in
            guard let rect = link.rects.first,
                  sourcePage.selection(for: rect)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "24",
                  case let .goTo(pageIndex, _) = link.target
            else { return false }
            return pageIndex == 36
        })
        let resolver = CitationPreviewResolver(document: document)
        guard case let .preview(group) = resolver.resolve(link) else {
            Issue.record("D03 p28 a7 should resolve as a numeric single preview")
            return
        }
        let item = group.items[group.selectedIndex]
        #expect(group.items.map(\.label) == ["[24]"])
        #expect(item.state == .resolved)
        #expect(item.destination == link.target)
        #expect(item.destinationPageIndex == Optional(36))
        #expect(item.referenceText.contains("Lee, S., Lin, Z. & Fanti, G."))
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
        guard case let .preview(authorGroup) = ambiguousResolver.resolve(shorthandAuthorLink) else {
            Issue.record("Shorthand author should open the complete two-member group")
            return
        }
        #expect(authorGroup.items.map(\.label) == ["Wu & Goodman 2018", "Wu & Goodman 2019"])
        #expect(authorGroup.selectedIndex == 0)
        let ambiguousLink = try #require(links(sourceText: "2019", in: ambiguousDocument).first { link in
            guard case let .goTo(_, point?) = link.target else { return false }
            return abs(point.y - 161.054) < 0.5
        })
        guard case let .preview(yearGroup) = ambiguousResolver.resolve(ambiguousLink) else {
            Issue.record("Omitted-author year should resolve using same-group author context")
            return
        }
        #expect(yearGroup.items.map(\.label) == ["Wu & Goodman 2018", "Wu & Goodman 2019"])
        #expect(yearGroup.selectedIndex == 1)
        #expect(yearGroup.items.allSatisfy { $0.isResolved })
        #expect(try PDFFixtureFactory.sha256(of: ambiguousURL) == ambiguousBefore)
    }
    @Test("mapped author-year groups preserve every native target including omitted suffixes")
    func mappedAuthorYearGroupContracts() throws {
        let cases: [(String, Int, [Int], Int)] = [
            ("D09-codevae.pdf", 0, Array(5...8), 2),
            ("D10-posterior-sampling.pdf", 0, [2, 3], 2),
            ("D11-submix.pdf", 0, Array(1...14), 7),
            ("D14-structural-information.pdf", 2, Array(6...11), 3),
            ("D09-codevae.pdf", 0, Array(1...4), 2),
            ("D13-charmer.pdf", 1, Array(34...40), 4),
        ]
        for (file, pageIndex, indices, count) in cases {
            let url = URL(fileURLWithPath: "docs/citation-papers/\(file)")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let document = try #require(PDFDocument(url: url))
            let page = try #require(document.page(at: pageIndex))
            let sourceLinks = try indices.map { index in
                let annotation = try #require(page.annotations.indices.contains(index) ? page.annotations[index] : nil)
                return try #require(links(on: page, in: document).first { $0.rects.contains(annotation.bounds) })
            }
            var targets: [ReaderLinkTarget] = []
            for link in sourceLinks where !targets.contains(link.target) { targets.append(link.target) }
            #expect(targets.count == count)
            let resolver = CitationPreviewResolver(document: document)
            for link in sourceLinks {
                guard case let .preview(group) = resolver.resolve(link) else {
                    Issue.record("\(file) p\(pageIndex + 1) group did not preview")
                    continue
                }
                #expect(group.items.count == count)
                #expect(group.items.map(\.destination) == targets.map(Optional.some))
                #expect(group.items.allSatisfy { $0.isResolved })
                #expect(group.items[group.selectedIndex].destination == link.target)
                if file == "D13-charmer.pdf" {
                    #expect(group.items[1].label.contains("2023a"))
                    #expect(group.items[2].label.contains("2023b"))
                }
            }
        }
    }
    @Test("stage four author-year occurrences use native target and source-bound geometry")
    func stageFourAuthorYearCorpusContract() throws {
        let cases: [(file: String, sourcePage: Int, annotations: [Int], label: String, targetPage: Int)] = [
            ("D08-grammaticality.pdf", 0, [4, 5], "Warstadt et al. 2019", 9),
            ("D10-posterior-sampling.pdf", 0, [0], "Puterman 1994", 9),
            ("D11-submix.pdf", 1, [1, 2], "Chami et al. 2022", 8),
            ("D08-grammaticality.pdf", 0, [0, 1], "Pereira 2000", 8),
            ("D11-submix.pdf", 0, [21, 22], "Chiang et al. 2019", 8),
            ("D10-posterior-sampling.pdf", 2, [2, 3], "Al Marjani et al. 2021", 9),
            ("D08-grammaticality.pdf", 0, [2, 3], "Chomsky 1957", 8),
            ("D13-charmer.pdf", 0, [22, 23], "Morris et al. 2020a", 10),
            ("D08-grammaticality.pdf", 0, [6, 7], "Lau et al. 2017", 8),
            ("D08-grammaticality.pdf", 0, [8, 9], "Sprouse et al. 2018", 9),
            ("D12-model-routing.pdf", 2, [24, 25], "Cortes et al. 2021c", 10),
            ("D12-model-routing.pdf", 2, [26, 27], "Mohri et al. 2019", 11),
            ("D12-model-routing.pdf", 2, [28, 29], "Agarwal and Zhang 2022", 9),
            ("D08-grammaticality.pdf", 5, [26], "Pereira 2000", 8),
            ("D08-grammaticality.pdf", 5, [27, 28], "Saul and Pereira 1997", 9),
            ("D08-grammaticality.pdf", 5, [29], "Mikolov 2012", 8),
        ]
        for fixture in cases {
            let path = "docs/citation-papers/\(fixture.file)"
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let document = try #require(PDFDocument(url: URL(fileURLWithPath: path)))
            let page = try #require(document.page(at: fixture.sourcePage))
            let resolver = CitationPreviewResolver(document: document)
            for annotationIndex in fixture.annotations {
                let annotation = try #require(
                    page.annotations.indices.contains(annotationIndex) ? page.annotations[annotationIndex] : nil
                )
                let link = try #require(links(on: page, in: document).first {
                    $0.rects.contains(annotation.bounds)
                })
                guard case let .preview(group) = resolver.resolve(link) else {
                    Issue.record("\(fixture.file) p\(fixture.sourcePage + 1) a\(annotationIndex) did not preview")
                    continue
                }
                #expect(group.items.map(\.label) == [fixture.label])
                #expect(group.selectedIndex == 0)
                #expect(group.items[0].destination == link.target)
                #expect(group.items[0].destinationPageIndex == fixture.targetPage)
                #expect(group.items[0].state == .resolved)
            }
        }
    }
    @Test("synthetic author-year occurrences stay source-bound across whole, split, and bare links")
    func syntheticAuthorYearOccurrenceContract() throws {
        try withTemporaryDirectory { directory in
            let url = try makeAuthorYearSourceGeometryPDF(in: directory)
            let document = try #require(PDFDocument(url: url))
            let sourcePage = try #require(document.page(at: 0))
            let resolver = CitationPreviewResolver(document: document)
            let sourceText: (ReaderLink) -> String = { link in
                guard let rect = link.rects.first else { return "" }
                return sourcePage.selection(for: rect)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let links = links(on: sourcePage, in: document)
            let wholeLinks = links.filter { sourceText($0).contains("Whole") }
            #expect(wholeLinks.count == 2)
            for link in wholeLinks {
                guard case let .preview(group) = resolver.resolve(link) else {
                    Issue.record("Repeated whole author-year annotations must resolve independently")
                    continue
                }
                #expect(group.items.map(\.label) == ["Whole 2020"])
                #expect(group.items[group.selectedIndex].destination == link.target)
            }

            let squareLinks = links.filter { sourceText($0) == "Square" || sourceText($0) == "2021" }
            #expect(squareLinks.count == 2)
            for link in squareLinks {
                guard case let .preview(group) = resolver.resolve(link) else {
                    Issue.record("Split square author/year annotations must resolve as one occurrence")
                    continue
                }
                #expect(group.items.map(\.label) == ["Square 2021"])
            }

            let bareLink = try #require(links.first { sourceText($0) == "2022" })
            guard case let .preview(group) = resolver.resolve(bareLink) else {
                Issue.record("A linked year with an unlinked author must resolve from source context")
                return
            }
            #expect(group.items.map(\.label) == ["Bare 2022"])
        }
    }

    @Test("numeric source geometry keeps bracket occurrences independent and rejects a nearby range")
    func numericSourceGeometryContract() throws {
        try withTemporaryDirectory { directory in
            let url = try makeNumericSourceGeometryPDF(in: directory)
            let document = try #require(PDFDocument(url: url))
            let sourcePage = try #require(document.page(at: 0))
            let resolver = CitationPreviewResolver(document: document)
            let links = links(on: sourcePage, in: document)
            let sourceText: (ReaderLink) -> String = { link in
                guard let rect = link.rects.first else { return "" }
                return sourcePage.selection(for: rect)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }

            let repeated = links.filter {
                sourceText($0) == "[1]" && ($0.rects.first?.minY ?? 0) > 680
            }
            #expect(repeated.count == 2)
            for link in repeated {
                guard case let .preview(group) = resolver.resolve(link) else {
                    Issue.record("Repeated [1] must resolve as its own source group")
                    continue
                }
                #expect(group.items.map(\.label) == ["[1]"])
                #expect(group.items[group.selectedIndex].destination == link.target)
            }

            for marker in ["[2]", "[3]"] {
                let link = try #require(links.first { sourceText($0) == marker })
                guard case let .preview(group) = resolver.resolve(link) else {
                    Issue.record("Adjacent \(marker) must remain an independent source group")
                    continue
                }
                #expect(group.items.map(\.label) == [marker])
            }

            let rangeEndpoint = try #require(links.first {
                sourceText($0) == "1" && ($0.rects.first?.minY ?? 0) < 680
            })
            guard case let .preview(rangeGroup) = resolver.resolve(rangeEndpoint) else {
                Issue.record("Range membership must be preserved without borrowing nearby [1]")
                return
            }
            #expect(rangeGroup.items.map(\.label) == ["[1]", "[2]", "[3]"])
            #expect(rangeGroup.items[1].isUnresolved && rangeGroup.items[2].isUnresolved)

            let standaloneNearRange = try #require(links.first {
                sourceText($0) == "[1]" && ($0.rects.first?.minY ?? 0) < 680
            })
            guard case let .preview(group) = resolver.resolve(standaloneNearRange) else {
                Issue.record("The standalone [1] next to a range must still resolve")
                return
            }
            #expect(group.items.map(\.label) == ["[1]"])

            let wholeBracket = try #require(links.first { sourceText($0) == "[7]" })
            guard case let .preview(group) = resolver.resolve(wholeBracket) else {
                Issue.record("A whole-bracket annotation must resolve as a single citation")
                return
            }
            #expect(group.items.map(\.label) == ["[7]"])
            #expect(group.items[group.selectedIndex].destination == wholeBracket.target)
        }
    }
    private func makeNumericSourceGeometryPDF(in directory: URL) throws -> URL {
        let sourceURL = directory.appendingPathComponent("numeric-source-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        guard let consumer = CGDataConsumer(url: sourceURL as CFURL) else {
            throw PDFFixtureError.couldNotCreateConsumer
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFFixtureError.couldNotCreateContext
        }
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.black.cgColor,
        ]
        let sourceLines = [
            "Repeated [1] and [1]",
            "Adjacent [2][3]",
            "Range [1–3] nearby [1]",
            "Whole [7]",
        ]
        let sourceLineObjects = sourceLines.map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes))
        }
        context.beginPDFPage(nil)
        context.textMatrix = .identity
        for (index, line) in sourceLineObjects.enumerated() {
            context.textPosition = CGPoint(x: 48, y: CGFloat(700 - (index * 20)))
            CTLineDraw(line, context)
        }
        context.endPDFPage()

        let bibliographyLines = [
            ("[1] First verified reference.", CGFloat(700)),
            ("[2] Second verified reference.", CGFloat(680)),
            ("[3] Third verified reference.", CGFloat(660)),
            ("[7] Seventh verified reference.", CGFloat(640)),
        ]
        context.beginPDFPage(nil)
        for (text, y) in bibliographyLines {
            context.textPosition = CGPoint(x: 48, y: y)
            CTLineDraw(
                CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)),
                context
            )
        }
        context.endPDFPage()
        context.closePDF()

        guard let document = PDFDocument(url: sourceURL),
              let sourcePage = document.page(at: 0),
              let destinationPage = document.page(at: 1)
        else { throw PDFFixtureError.couldNotOpenGeneratedDocument }

        struct AnnotationSpec {
            let lineIndex: Int
            let token: String
            let occurrence: Int
            let destinationY: CGFloat
        }
        let specs = [
            AnnotationSpec(lineIndex: 0, token: "[1]", occurrence: 0, destinationY: 700),
            AnnotationSpec(lineIndex: 0, token: "[1]", occurrence: 1, destinationY: 700),
            AnnotationSpec(lineIndex: 1, token: "[2]", occurrence: 0, destinationY: 680),
            AnnotationSpec(lineIndex: 1, token: "[3]", occurrence: 0, destinationY: 660),
            AnnotationSpec(lineIndex: 2, token: "1", occurrence: 0, destinationY: 700),
            AnnotationSpec(lineIndex: 2, token: "[1]", occurrence: 0, destinationY: 700),
            AnnotationSpec(lineIndex: 3, token: "[7]", occurrence: 0, destinationY: 640),
        ]
        for spec in specs {
            let text = sourceLines[spec.lineIndex] as NSString
            var searchStart = 0
            var tokenRange = NSRange(location: NSNotFound, length: 0)
            for _ in 0...spec.occurrence {
                guard searchStart <= text.length else { break }
                let searchRange = NSRange(location: searchStart, length: text.length - searchStart)
                tokenRange = text.range(of: spec.token, options: [], range: searchRange)
                guard tokenRange.location != NSNotFound else { break }
                searchStart = tokenRange.location + tokenRange.length
            }
            guard tokenRange.location != NSNotFound else { continue }
            let line = sourceLineObjects[spec.lineIndex]
            let start = CTLineGetOffsetForStringIndex(line, tokenRange.location, nil)
            let end = CTLineGetOffsetForStringIndex(
                line,
                tokenRange.location + tokenRange.length,
                nil
            )
            let bounds = CGRect(
                x: 48 + start - 1,
                y: CGFloat(700 - (spec.lineIndex * 20)) - 3,
                width: max(8, end - start + 2),
                height: 18
            )
            let annotation = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
            annotation.action = PDFActionGoTo(
                destination: PDFDestination(
                    page: destinationPage,
                    at: CGPoint(x: 48, y: spec.destinationY + 4)
                )
            )
            sourcePage.addAnnotation(annotation)
        }

        let outputURL = directory.appendingPathComponent("numeric-source-geometry.pdf")
        guard document.write(to: outputURL), PDFDocument(url: outputURL) != nil else {
            throw PDFFixtureError.couldNotWriteDocument
        }
        return outputURL
    }
    private func makeAuthorYearSourceGeometryPDF(in directory: URL) throws -> URL {
        let sourceURL = directory.appendingPathComponent("author-year-source-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        guard let consumer = CGDataConsumer(url: sourceURL as CFURL) else {
            throw PDFFixtureError.couldNotCreateConsumer
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFFixtureError.couldNotCreateContext
        }
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.black.cgColor,
        ]
        let sourceLines = [
            "Whole (2020) and Whole (2020)",
            "[Square, 2021]",
            "Bare 2022",
        ]
        let sourceLineObjects = sourceLines.map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes))
        }
        context.beginPDFPage(nil)
        context.textMatrix = .identity
        for (index, line) in sourceLineObjects.enumerated() {
            context.textPosition = CGPoint(x: 48, y: CGFloat(700 - (index * 20)))
            CTLineDraw(line, context)
        }
        context.endPDFPage()

        let bibliographyLines = [
            ("Whole Author. 2020. Whole reference.", CGFloat(700)),
            ("Square Author. 2021. Square reference.", CGFloat(680)),
            ("Bare Author. 2022. Bare reference.", CGFloat(660)),
        ]
        context.beginPDFPage(nil)
        context.textMatrix = .identity
        for (text, y) in bibliographyLines {
            context.textPosition = CGPoint(x: 48, y: y)
            CTLineDraw(
                CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)),
                context
            )
        }
        context.endPDFPage()
        context.closePDF()

        guard let document = PDFDocument(url: sourceURL),
              let sourcePage = document.page(at: 0),
              let destinationPage = document.page(at: 1)
        else { throw PDFFixtureError.couldNotOpenGeneratedDocument }

        struct AnnotationSpec {
            let lineIndex: Int
            let token: String
            let occurrence: Int
            let destinationY: CGFloat
        }
        let specs = [
            AnnotationSpec(lineIndex: 0, token: "Whole (2020)", occurrence: 0, destinationY: 700),
            AnnotationSpec(lineIndex: 0, token: "Whole (2020)", occurrence: 1, destinationY: 700),
            AnnotationSpec(lineIndex: 1, token: "Square", occurrence: 0, destinationY: 680),
            AnnotationSpec(lineIndex: 1, token: "2021", occurrence: 0, destinationY: 680),
            AnnotationSpec(lineIndex: 2, token: "2022", occurrence: 0, destinationY: 660),
        ]
        for spec in specs {
            let text = sourceLines[spec.lineIndex] as NSString
            var searchStart = 0
            var tokenRange = NSRange(location: NSNotFound, length: 0)
            for _ in 0...spec.occurrence {
                guard searchStart <= text.length else { break }
                let searchRange = NSRange(location: searchStart, length: text.length - searchStart)
                tokenRange = text.range(of: spec.token, options: [], range: searchRange)
                guard tokenRange.location != NSNotFound else { break }
                searchStart = tokenRange.location + tokenRange.length
            }
            guard tokenRange.location != NSNotFound else { continue }
            let line = sourceLineObjects[spec.lineIndex]
            let start = CTLineGetOffsetForStringIndex(line, tokenRange.location, nil)
            let end = CTLineGetOffsetForStringIndex(
                line,
                tokenRange.location + tokenRange.length,
                nil
            )
            let bounds = CGRect(
                x: 48 + start - 1,
                y: CGFloat(700 - (spec.lineIndex * 20)) - 3,
                width: max(8, end - start + 2),
                height: 18
            )
            let annotation = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
            annotation.action = PDFActionGoTo(
                destination: PDFDestination(
                    page: destinationPage,
                    at: CGPoint(x: 48, y: spec.destinationY + 4)
                )
            )
            sourcePage.addAnnotation(annotation)
        }

        let outputURL = directory.appendingPathComponent("author-year-source-geometry.pdf")
        guard document.write(to: outputURL), PDFDocument(url: outputURL) != nil else {
            throw PDFFixtureError.couldNotWriteDocument
        }
        return outputURL
    }

    private func openCitationPreview(
        controller: MainWindowController,
        session: ReaderSession,
        marker: Int
    ) throws {
        session.applyCitationPreviewEnabled(true)
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
