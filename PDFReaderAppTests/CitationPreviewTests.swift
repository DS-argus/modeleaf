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
    private enum CrossPageAuthorYearCase: CaseIterable, Equatable {
        case positive
        case sameTargetUnrelated
        case unmatchedAuthorBracket
        case unmatchedYearBracket
        case multiMember
        case differingTargets
        case unlinkedYear
        case interveningBodyBelowAuthor
        case precedingBodyBeforeYear
    }

    private enum CrossPageBibliographyCase: CaseIterable, Equatable {
        case positive
        case startsNewEntry
        case startsHeading
        case sourceNotAtPageEnd
        case unrelatedContinuation
        case missingBoundary
        case terminalPositive
        case terminalAmbiguous
        case capitalizedAmbiguous
        case mismatchedIndent
        case endOfDocument
    }

    private func citationFixtureExists(atPath path: String) -> Bool {
        guard !FileManager.default.fileExists(atPath: path) else { return true }
        if ProcessInfo.processInfo.environment["MODELEAF_REQUIRE_CITATION_FIXTURES"] == "1" {
            Issue.record("Required citation fixture is unavailable: \(path)")
        } else {
            print("UNAVAILABLE optional citation fixture (not verified): \(path)")
        }
        return false
    }
    @Test("numeric classifier distinguishes exact markers and expands scoped groups")
    func classifierContract() {
        #expect(CitationPreviewClassifier.marker(in: " 13 ") == 13)
        #expect(CitationPreviewClassifier.marker(in: "[7]") == 7)
        #expect(CitationPreviewClassifier.marker(in: " [ 13 ] ") == 13)
        #expect(CitationPreviewClassifier.marker(in: "[3, 4]") == nil)
        #expect(CitationPreviewClassifier.marker(in: "[7") == nil)
        #expect(CitationPreviewClassifier.marker(in: "3, 4") == nil)
        #expect(CitationPreviewClassifier.marker(in: "Smith 2024") == nil)
        #expect(CitationPreviewClassifier.bracketedGroups(in: "Prior work [3, 4; 5] agrees") == [[3, 4, 5]])
        #expect(CitationPreviewClassifier.bracketedGroups(in: "Figure 4 and section 5").isEmpty)
        #expect(CitationPreviewClassifier.bracketedGroups(in: "(4)") == [[4]])
        #expect(CitationPreviewClassifier.bracketedGroups(in: "(2;3)") == [[2, 3]])
        #expect(CitationPreviewClassifier.bracketedGroups(in: "(12–14)") == [[12, 13, 14]])
        #expect(CitationPreviewClassifier.bracketedGroups(in: "[12, pp. 13–14]") == [[12]])
        #expect(CitationPreviewClassifier.bracketedGroups(in: "[see 12, p. 3; 14, p. 8]") == [[12, 14]])
        #expect(CitationPreviewClassifier.bracketedGroups(in: "[3-5]") == [[3, 4, 5]])
        #expect(CitationPreviewClassifier.bracketedGroups(in: "[1, 3–5, 8]") == [[1, 3, 4, 5, 8]])
        #expect(CitationPreviewClassifier.bracketedGroups(in: "[5–3]").isEmpty)
        #expect(CitationPreviewClassifier.bracketedGroups(in: "[1–9999]").isEmpty)
    }
    @Test("round numeric citations and notes preserve citation membership and context")
    func citationNoteContracts() throws {
        let cases: [(String, Int, [Int], Int, String?)] = [
            ("D05-molvision.pdf", 0, [1], 1, nil),
            ("D05-molvision.pdf", 0, [2, 3], 2, nil),
            ("D12-model-routing.pdf", 3, [7, 8], 1, "e.g."),
            ("D12-model-routing.pdf", 7, Array(7...10), 2, "e.g."),
            ("D18-orthogonal-manifold.pdf", 5, [6, 7], 1, "Chapter 3"),
            ("D18-orthogonal-manifold.pdf", 5, [8, 9], 1, "Prop 15.23"),
            ("D16-labeldp-pro.pdf", 7, [26, 27], 1, "Section 5.2"),
            ("D16-labeldp-pro.pdf", 0, [29, 30], 1, nil),
            ("D16-labeldp-pro.pdf", 0, [31, 32], 1, nil),
        ]
        for (file, pageIndex, indices, count, context) in cases {
            let url = URL(fileURLWithPath: "test-pdf/citation-verification/mapped/\(file)")
            guard citationFixtureExists(atPath: url.path) else { continue }
            let document = try #require(PDFDocument(url: url))
            let page = try #require(document.page(at: pageIndex))
            for index in indices {
                let annotation = page.annotations[index]
                let link = try #require(links(on: page, in: document).first { $0.rects.contains(annotation.bounds) })
                guard case let .preview(group) = CitationPreviewResolver(document: document).resolve(link) else {
                    Issue.record("\(file) p\(pageIndex + 1) a\(index) did not preview")
                    continue
                }
                #expect(group.items.count == count)
                #expect(group.items.allSatisfy { $0.isResolved })
                #expect(group.items[group.selectedIndex].destination == link.target)
                if let context {
                    #expect(group.sourceContext?.contains(context) == true)
                    let overlay = CitationPreviewOverlayView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
                    overlay.present(group: group, anchorRect: .zero)
                    #expect(overlay.referenceTextForTesting.contains(context))
                }
            }
        }
        let noteURL = URL(fileURLWithPath: "test-pdf/citation-verification/mapped/D16-labeldp-pro.pdf")
        if citationFixtureExists(atPath: noteURL.path) {
            let document = try #require(PDFDocument(url: noteURL))
            let page = try #require(document.page(at: 7))
            let annotation = page.annotations[22]
            let link = try #require(links(on: page, in: document).first { $0.rects.contains(annotation.bounds) })
            #expect(CitationPreviewResolver(document: document).resolve(link) == .activate(link.target))
        }
    }
    @Test("alphabetic and opaque labels retain native bibliography identity")
    func opaqueCitationContracts() throws {
        for (file, indices, labels) in [
            ("D15-improving-bandits.pdf", [6], ["BR25"]),
            ("D15-improving-bandits.pdf", [4, 5], ["HKR16", "Pat+23"]),
            ("D16-labeldp-pro.pdf", [33], ["app"]),
        ] {
            let url = URL(fileURLWithPath: "test-pdf/citation-verification/mapped/\(file)")
            guard citationFixtureExists(atPath: url.path) else { continue }
            let document = try #require(PDFDocument(url: url))
            let page = try #require(document.page(at: 0))
            for (expectedSelection, index) in indices.enumerated() {
                let annotation = page.annotations[index]
                let link = try #require(links(on: page, in: document).first { $0.rects.contains(annotation.bounds) })
                guard case let .preview(group) = CitationPreviewResolver(document: document).resolve(link) else {
                    Issue.record("\(file) a\(index) did not preview")
                    continue
                }
                #expect(group.items.map(\.label) == labels)
                #expect(group.selectedIndex == expectedSelection)
                #expect(group.items.allSatisfy { $0.isResolved })
                #expect(group.items[group.selectedIndex].destination == link.target)
            }
        }
    }

    @Test("author-year classifier joins split and hyphenated fragments and validates exact reference keys")
    func authorYearClassifierContract() throws {
        let mentionedAuthors = try #require(AuthorYearCitationClassifier.key(from: ["Smith & Jones", "2020"]))
        #expect(!AuthorYearCitationClassifier.validates(mentionedAuthors,
            referenceText: "Brown, B. 2020. Smith and Jones benchmark."))
        #expect(!AuthorYearCitationClassifier.validates(mentionedAuthors,
            referenceText: "Smith and Jones benchmark, 2020. Brown, B."))
        let simple = try #require(AuthorYearCitationClassifier.key(from: ["Germain et al.", "2015"]))
        #expect(simple.label == "Germain et al. 2015")
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
        let locatorCollision = try #require(AuthorYearCitationClassifier.key(from: ["Ray and Page 2001, pp.2020"]))
        #expect(locatorCollision.label == "Ray and Page 2001")
        let possessive = try #require(AuthorYearCitationClassifier.key(from: ["Chomsky’s", "1957"]))
        #expect(possessive.label == "Chomsky 1957")
        let givenNameFirst = try #require(AuthorYearCitationClassifier.key(from: ["Warstadt et al.", "2019"]))
        #expect(AuthorYearCitationClassifier.validates(
            givenNameFirst,
            referenceText: "Alex Warstadt, Amanpreet Singh, and Samuel R. Bowman. 2019. Neural Network Acceptability Judgments."
        ))
        #expect(suffixed.yearSuffix == "a")
        let spacedDiacriticAuthors = try #require(AuthorYearCitationClassifier.key(from: ["B¨ orgers and Sarin", "1997"]))
        #expect(AuthorYearCitationClassifier.validates(
            spacedDiacriticAuthors,
            referenceText: "B¨ orgers, T. and Sarin, R. (1997). Learning through reinforcement and replicator dynamics."
        ))
        #expect(AuthorYearCitationClassifier.key(from: ["et al.", "2020"]) == nil)
        #expect(AuthorYearCitationClassifier.key(from: ["Figure", "2020", "2021"]) == nil)
        #expect(AuthorYearCitationClassifier.isYearFragment("2020a"))
        #expect(!AuthorYearCitationClassifier.isYearFragment("Smith 2020"))
    }
    @Test("author-year locator cleanup preserves Page surnames and source context")
    func authorYearLocatorContracts() throws {
        let whole = try #require(AuthorYearCitationClassifier.key(from: ["Ray and Page 2001, pp.2020"]))
        let split = try #require(AuthorYearCitationClassifier.key(from: ["Ray and Page", "2001, pp.2020"]))
        let lowercase = try #require(AuthorYearCitationClassifier.key(from: ["ray and page", "2001, pages 2020"]))
        let singlePage = try #require(AuthorYearCitationClassifier.key(from: ["Page", "2001"]))
        #expect(whole.label == "Ray and Page 2001")
        #expect(split == whole)
        #expect(lowercase.label == "ray and page 2001")
        #expect(singlePage.label == "Page 2001")

        #expect(CitationPreviewClassifier.sourceContext(in: "Ray and Page 2001", authorYear: true) == nil)
        #expect(CitationPreviewClassifier.sourceContext(in: "[Ray and Page 2001]", authorYear: true) == nil)
        let locatorContext = try #require(CitationPreviewClassifier.sourceContext(
            in: "[Ray and Page 2001, pp.2020]",
            authorYear: true
        ))
        #expect(locatorContext.contains("Ray and Page 2001"))
        #expect(locatorContext.contains("pp. 2020"))
        let pagesContext = try #require(CitationPreviewClassifier.sourceContext(
            in: "[Ray and Page 2001, pages 2020]",
            authorYear: true
        ))
        #expect(pagesContext.contains("pages 2020"))
    }

    @Test("Google Scholar URL preserves the complete reference as one encoded query")
    func googleScholarSearchURLContract() throws {
        #expect(citationScholarQuery(for: "[12] García & 李.\nA title.") == "García & 李.\nA title.")
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

    @Test("numeric extraction refuses to mark capped reference prefixes as complete")
    func truncatedNumericReferenceContract() {
        let lines = (0..<9).map { index in
            CitationTextLine(text: index == 0 ? "[7] Long reference" : "continuation \(index)",
                bounds: CGRect(x: 40, y: 700 - index * 14, width: 220, height: 12))
        }
        #expect(CitationReferenceExtractor.extract(marker: 7, from: lines) == nil)
        #expect(CitationReferenceExtractor.extract(marker: 7, from: Array(lines.prefix(8))) != nil)
        let overlong = CitationTextLine(text: "[7] " + String(repeating: "x", count: 701), bounds: lines[0].bounds)
        #expect(CitationReferenceExtractor.extract(marker: 7, from: [overlong]) == nil)
    }
    @Test("extractor stops at the next marker, large gap, and bounded size")
    func extractorContract() {
        let wrapped = [
            CitationTextLine(text: "[3] Author. Title", bounds: CGRect(x: 40, y: 700, width: 220, height: 12)),
            CitationTextLine(text: "2019. Journal, volume pages.", bounds: CGRect(x: 52, y: 684, width: 220, height: 12)),
        ]
        #expect(CitationReferenceExtractor.extract(marker: 3, from: wrapped) == "[3] Author. Title 2019. Journal, volume pages.")
        let ambiguous = CitationTextLine(text: "2019. Beta reference.", bounds: CGRect(x: 40, y: 684, width: 220, height: 12))
        #expect(CitationReferenceExtractor.extract(marker: 3, from: [wrapped[0], ambiguous]) == nil)
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
        #expect(!CitationReferenceEntryExtractor.isReferenceStart("References"))
        #expect(CitationReferenceEntryExtractor.isReferenceStart("B¨ orgers, T. and Sarin, R. (1997). Learning through reinforcement."))
        #expect(CitationReferenceEntryExtractor.isReferenceStart("´ de Montbrun, E. and Renault, J. (2022). Convergence."))
        #expect(!CitationReferenceEntryExtractor.isReferenceStart("In NeurIPS."))
        #expect(!CitationReferenceEntryExtractor.isReferenceStart("A Continuation."))
        #expect(!CitationReferenceEntryExtractor.isReferenceStart("Theory and Practice."))
        #expect(!CitationReferenceEntryExtractor.isReferenceStart("Deep Learning and Neural Networks."))
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
            let url = URL(fileURLWithPath: "test-pdf/citation-verification/mapped/\(file)")
            guard citationFixtureExists(atPath: url.path) else { continue }
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
            CGPoint(x: -10000, y: 700),
            CGPoint(x: CGFloat.nan, y: 700),
            CGPoint(x: 40, y: CGFloat.infinity),
            CGPoint(x: -sentinel, y: 700),
            CGPoint(x: 40, y: sentinel),
        ]
        for point in points {
            #expect(!CitationReferenceEntryExtractor.isUsableDestinationPoint(point, on: page))
            #expect(CitationReferenceEntryExtractor.numericEntry(marker: 7, destinationPoint: point, on: page) == nil)
            #expect(CitationReferenceEntryExtractor.entry(destinationPoint: point, on: page, nativeBoundaryPoints: [:]) == nil)
            #expect(CitationReferenceEntryExtractor.candidates(destinationPoint: point, on: page, nativeBoundaryPoints: [:]).isEmpty)
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
        overlay.onCommit = { _ in Issue.record("Stale commit must not run") }
        overlay.present(group: CitationPreviewGroup(items: [item], selectedIndex: 0), anchorRect: .zero)
        overlay.present(group: CitationPreviewGroup(items: [], selectedIndex: 0), anchorRect: .zero)
        #expect(overlay.isHidden && !overlay.hasCallbacksForTesting)
        #expect(overlay.referenceTextForTesting.isEmpty && overlay.selectedLabelForTesting == nil)
        #expect(overlay.handleKeyDown(try #require(makeKeyEvent(characters: "\r", keyCode: 36))))
        overlay.setFrameSize(NSSize(width: 200, height: 420))
        overlay.present(group: CitationPreviewGroup(items: [item], selectedIndex: 0), anchorRect: .zero)
        overlay.layoutSubtreeIfNeeded()
        #expect(overlay.cardFrameForTesting.minX >= 0)
        #expect(overlay.cardFrameForTesting.maxX <= overlay.bounds.maxX)
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
    @Test("citation preview tears down when closing the last document")
    func previewTeardownOnLastDocumentClose() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeCitationPreviewPDF(in: directory)
            let session = try PDFOpenService().open(url: url)
            let coordinator = PaneCoordinator()
            let controller = MainWindowController(
                coordinator: coordinator,
                theme: AppKitTheme(themeID: .tokyoNight),
                actionHandler: { _ in }
            )
            defer {
                while coordinator.closeActiveTab() {}
                controller.close()
            }
            #expect(coordinator.insert(session, into: .createIfEmpty))
            controller.rootView.layoutSubtreeIfNeeded()
            controller.window?.contentView?.layoutSubtreeIfNeeded()

            try openCitationPreview(controller: controller, session: session, marker: 4)
            let overlay = controller.rootView.citationPreviewOverlay
            #expect(!overlay.isHidden)
            #expect(coordinator.closeActiveTab())
            #expect(coordinator.snapshot.isEmpty)
            #expect(coordinator.snapshot.activeID == nil)
            #expect(overlay.isHidden)
            #expect(overlay.selectedLabelForTesting == nil)
            #expect(overlay.selectedStateForTesting == nil)
            #expect(overlay.referenceTextForTesting.isEmpty)
            #expect(!overlay.hasCallbacksForTesting)
            #expect(coordinator.snapshot.inputContext == .navigation)
            #expect(controller.inputContextForTesting == .navigation)
        }
    }

    @Test("citation preview invalidates on session refresh and active document change")
    func previewTeardownOnActiveDocumentChange() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeCitationPreviewPDF(in: directory)
            let first = try PDFOpenService().open(url: url)
            let second = try PDFOpenService().open(url: url)
            let coordinator = PaneCoordinator()
            let controller = MainWindowController(
                coordinator: coordinator,
                theme: AppKitTheme(themeID: .tokyoNight),
                actionHandler: { _ in }
            )
            defer {
                while coordinator.closeActiveTab() {}
                controller.close()
            }
            #expect(coordinator.insert(first, into: .createIfEmpty))
            #expect(coordinator.insert(second, into: .createIfEmpty))
            #expect(coordinator.activate(tab: first.id))
            controller.rootView.layoutSubtreeIfNeeded()
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            let paneID = try #require(coordinator.snapshot.activePaneID)

            try openCitationPreview(controller: controller, session: first, marker: 4)
            let overlay = controller.rootView.citationPreviewOverlay
            let firstPage = first.currentPageNumber
            #expect(!overlay.isHidden)
            let store = try #require(coordinator.store(for: paneID))
            store.sessionDidChange(first.id)
            #expect(overlay.isHidden)
            #expect(!overlay.hasCallbacksForTesting)
            try openCitationPreview(controller: controller, session: first, marker: 4)
            #expect(!overlay.isHidden)

            #expect(coordinator.activate(tab: second.id))
            #expect(coordinator.snapshot.activeID == second.id)
            #expect(overlay.isHidden)
            #expect(overlay.selectedLabelForTesting == nil)
            #expect(overlay.selectedStateForTesting == nil)
            #expect(overlay.referenceTextForTesting.isEmpty)
            #expect(!overlay.hasCallbacksForTesting)
            #expect(coordinator.snapshot.inputContext == .navigation)
            #expect(controller.inputContextForTesting == .navigation)

            _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "", keyCode: 53)))
            _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36)))
            #expect(first.currentPageNumber == firstPage)
            #expect(second.currentPageNumber == 1)
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
        guard citationFixtureExists(atPath: path) else { return }
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
    @Test("real numeric corpus positives resolve and external links retain ordinary activation")
    func realCorpusContract() throws {
        let samples: [(path: String, expected: [Int])] = [
            ("test-pdf/citation-annotation-corpus/NeurIPS/2022-federated-submodel-optimization.pdf", [3, 4, 5, 6]),
            ("test-pdf/citation-annotation-corpus/NeurIPS/2025-primacy-of-magnitude.pdf", [1, 2, 3, 4, 5]),
            ("test-pdf/citation-annotation-corpus/ICLR/2022-s4.pdf", [1, 13]),
        ]
        guard samples.allSatisfy({ citationFixtureExists(atPath: $0.path) }) else { return }

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
        guard citationFixtureExists(atPath: fallbackURL.path) else { return }
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
        guard citationFixtureExists(atPath: path) else { return }
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
        let path = "test-pdf/citation-verification/mapped/D03-neuralplexer3.pdf"
        guard citationFixtureExists(atPath: path) else { return }
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
        guard citationFixtureExists(atPath: path) else { return }
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
        guard fixtures.allSatisfy({ citationFixtureExists(atPath: $0.path) }) else { return }

        for fixture in fixtures {
            let url = URL(fileURLWithPath: fixture.path)
            let before = try PDFFixtureFactory.sha256(of: url)
            let document = try #require(PDFDocument(url: url))
            let destination = try #require(goToDestination(sourceText: fixture.source, in: document))
            let page = try #require(destination.page)
            let nativePoints = CitationReferenceEntryExtractor.nativeDestinationPoints(in: document)
            let candidates = CitationReferenceEntryExtractor.candidates(
                destinationPoint: destination.point,
                on: page, nativeBoundaryPoints: nativePoints
            )
            let selected = try #require(CitationReferenceEntryExtractor.entry(
                destinationPoint: destination.point,
                on: page, nativeBoundaryPoints: nativePoints
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
        #expect(CitationReferenceEntryExtractor.layout(of: Array(twoColumn.prefix(4)), pageBounds: page) == .twoColumns(splitX: 300))
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
        guard fixtures.allSatisfy({ citationFixtureExists(atPath: $0.path) }) else { return }

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
    @Test("author contribution markers preserve bibliography boundaries without changing text")
    func authorContributionMarkerBoundaryContract() {
        for text in [
            "Siyuan Guo*, Viktor Tóth*, Bernhard Schölkopf, and",
            "Alice Example*, Bob Other, and Carol Third.",
            "Example*, A. and Other, B. 2023. A reference.",
            "Alice Example**, Bob Other. 2023. A reference."
        ] {
            #expect(CitationReferenceEntryExtractor.isReferenceStart(text))
        }
        for text in ["In NeurIPS.*", "A Continuation*", "Deep Learning*", "continuation * text"] {
            #expect(!CitationReferenceEntryExtractor.isReferenceStart(text))
        }
    }

    @Test("D14 Guo 2025 excludes the following starred-author reference")
    func structuralInformationReferenceBoundaryContract() throws {
        let path = "test-pdf/citation-verification/mapped/D14-structural-information.pdf"
        guard citationFixtureExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        let before = try PDFFixtureFactory.sha256(of: url)
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let resolver = CitationPreviewResolver(document: document)
        for index in [1, 2] {
            let annotation = page.annotations[index]
            let destination = try #require(target(for: annotation, in: document))
            #expect(destination == .goTo(pageIndex: 9, point: CGPoint(x: 65.875, y: 739.138)))
            let link = ReaderLink(sourcePageIndex: 0, rects: [annotation.bounds],
                                  target: destination, primaryLabelRect: annotation.bounds)
            guard case let .preview(group) = resolver.resolve(link) else {
                Issue.record("D14 author and year must both preview Guo 2025")
                continue
            }
            #expect(group.items.count == 1)
            let item = group.items[group.selectedIndex]
            #expect(item.isResolved)
            #expect(item.destination == destination)
            #expect(item.referenceText.hasPrefix("Siyuan Guo and Bernhard Schölkopf. 2025."))
            #expect(item.referenceText.contains("2509.21049"))
            #expect(!item.referenceText.contains("Viktor"))
            #expect(!item.referenceText.contains("2023"))
            #expect(!item.referenceText.contains("Causal de finetti"))
        }
        #expect(try PDFFixtureFactory.sha256(of: url) == before)
    }
    @Test("additional corpus boundaries preserve exact author-year targets and stop at successor authors")
    func additionalCitationRepairContracts() throws {
        let cases: [(path: String, sourcePage: Int, annotation: Int, target: ReaderLinkTarget, label: String, group: [String], prefix: String, rejected: [String])] = [
            (
                "test-pdf/citation-annotation-corpus/ICML/2024-charmer.pdf",
                0,
                9,
                .goTo(pageIndex: 8, point: CGPoint(x: 35.52, y: 385.975)),
                "Alzantot et al. 2018",
                ["Belinkov & Bisk 2018", "Alzantot et al. 2018"],
                "Alzantot, M., Sharma, Y., Elgohary, A., Ho, B.-J., Srivas-",
                ["Belinkov,", "Gao,"]
            ),
            (
                "test-pdf/citation-annotation-corpus/ICML/2024-charmer.pdf",
                0,
                34,
                .goTo(pageIndex: 8, point: CGPoint(x: 35.52, y: 385.975)),
                "Alzantot et al. 2018",
                ["Alzantot et al. 2018", "Gao et al. 2018", "Jin et al. 2020", "Li et al. 2020", "Garg & Ramakrishnan 2020", "Wallace et al. 2020"],
                "Alzantot, M., Sharma, Y., Elgohary, A., Ho, B.-J., Srivas-",
                ["Belinkov,", "Gao,"]
            ),
            (
                "test-pdf/citation-annotation-corpus/AISTATS/2023-last-iterate-zero-sum.pdf",
                0,
                24,
                .goTo(pageIndex: 9, point: CGPoint(x: 43.075, y: 653.891)),
                "Daskalakis and Panageas 2019",
                ["Daskalakis and Panageas 2019", "Wei et al. 2021b"],
                "Daskalakis, C. and Panageas, I. (2019). Last-iterate conver-",
                ["de Montbrun", "Renault"]
            ),
            (
                "test-pdf/citation-annotation-corpus/AISTATS/2023-last-iterate-zero-sum.pdf",
                1,
                11,
                .goTo(pageIndex: 8, point: CGPoint(x: 295.075, y: 721.993)),
                "Bauer et al. 2019",
                ["Hofbauer and Sigmund 1998", "Hofbauer et al. 2009", "Zagorsky et al. 2013", "Bauer et al. 2019"],
                "Bauer, J., Broom, M., and Alonso, E. (2019). The stabiliza-",
                ["Bena¨ ım", "Hirsch"]
            ),
            (
                "test-pdf/citation-annotation-corpus/AISTATS/2023-last-iterate-zero-sum.pdf",
                1,
                1,
                .goTo(pageIndex: 8, point: CGPoint(x: 295.075, y: 261.934)),
                "B¨ orgers and Sarin 1997",
                ["B¨ orgers and Sarin 1997", "Bloembergen et al. 2015"],
                "B¨ orgers, T. and Sarin, R. (1997). Learning through rein-",
                ["Cai,", "Bloembergen,"]
            ),
        ]
        guard cases.allSatisfy({ citationFixtureExists(atPath: $0.path) }) else { return }

        for fixture in cases {
            let url = URL(fileURLWithPath: fixture.path)
            let before = try PDFFixtureFactory.sha256(of: url)
            let document = try #require(PDFDocument(url: url))
            let page = try #require(document.page(at: fixture.sourcePage))
            let annotation = try #require(
                page.annotations.indices.contains(fixture.annotation) ? page.annotations[fixture.annotation] : nil
            )
            let target = try #require(self.target(for: annotation, in: document))
            #expect(target == fixture.target)
            let link = ReaderLink(
                sourcePageIndex: fixture.sourcePage,
                rects: [annotation.bounds],
                target: target,
                primaryLabelRect: annotation.bounds
            )
            let resolver = CitationPreviewResolver(document: document)
            guard case let .preview(group) = resolver.resolve(link) else {
                Issue.record("\(fixture.path) p\(fixture.sourcePage + 1) a\(fixture.annotation) did not produce a preview")
                continue
            }
            #expect(group.items.map(\.label) == fixture.group)
            #expect(group.items[group.selectedIndex].label == fixture.label)
            #expect(group.items[group.selectedIndex].destination == fixture.target)
            #expect(group.items.allSatisfy { $0.isResolved })
            let selected = group.items[group.selectedIndex]
            #expect(selected.referenceText.hasPrefix(fixture.prefix))
            for rejected in fixture.rejected {
                #expect(!selected.referenceText.contains(rejected))
            }
            #expect(try PDFFixtureFactory.sha256(of: url) == before)
        }
    }
    @Test("Charmer p2 Alzantot author and year links preview the native reference")
    func charmerAuthorYearPreviewContract() throws {
        let path = "test-pdf/citation-annotation-corpus/ICML/2024-charmer.pdf"
        guard citationFixtureExists(atPath: path) else { return }
        let document = try #require(PDFDocument(url: URL(fileURLWithPath: path)))
        let page = try #require(document.page(at: 1))
        let resolver = CitationPreviewResolver(document: document)
        let expectedTarget = ReaderLinkTarget.goTo(pageIndex: 8, point: CGPoint(x: 35.52, y: 385.975))
        for annotationIndex in [32, 33] {
            let annotation = try #require(page.annotations.indices.contains(annotationIndex) ? page.annotations[annotationIndex] : nil)
            let target = try #require(self.target(for: annotation, in: document))
            #expect(target == expectedTarget)
            let link = ReaderLink(
                sourcePageIndex: 1,
                rects: [annotation.bounds],
                target: target,
                primaryLabelRect: annotation.bounds
            )
            guard case let .preview(group) = resolver.resolve(link) else {
                Issue.record("Charmer p2 a\(annotationIndex) did not produce an Alzantot preview")
                continue
            }
            #expect(group.items.map(\.label) == ["Alzantot et al. 2018"])
            #expect(group.selectedIndex == 0)
            #expect(group.items[0].destination == expectedTarget)
            #expect(group.items[0].isResolved)
            #expect(group.items[0].referenceText.hasPrefix("Alzantot, M., Sharma, Y., Elgohary, A., Ho, B.-J., Srivas-"))
            #expect(!group.items[0].referenceText.contains("Belinkov,"))
        }
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
            let url = URL(fileURLWithPath: "test-pdf/citation-verification/mapped/\(file)")
            guard citationFixtureExists(atPath: url.path) else { continue }
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
            let path = "test-pdf/citation-verification/mapped/\(fixture.file)"
            guard citationFixtureExists(atPath: path) else { continue }
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
    @Test("reported bibliography boundaries and adjacent-page author-year links remain native")
    func reportedCitationRepairContracts() throws {
        let uai2025Path = "test-pdf/citation-annotation-corpus/UAI/2025-aggregating-data.pdf"
        let uai2024Path = "test-pdf/citation-annotation-corpus/UAI/2024-adversarial-weak-supervision.pdf"
        let microAdamPath = "test-pdf/citation-annotation-corpus/NeurIPS/2024-microadam.pdf"
        guard [uai2025Path, uai2024Path, microAdamPath].allSatisfy({ citationFixtureExists(atPath: $0) }) else { return }

        func sourceText(_ link: ReaderLink, in document: PDFDocument) -> String {
            guard let page = document.page(at: link.sourcePageIndex), let rect = link.rects.first else { return "" }
            return page.selection(for: rect)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func destinationPage(_ target: ReaderLinkTarget) -> Int? {
            guard case let .goTo(pageIndex, _) = target else { return nil }
            return pageIndex
        }

        func destinationPoint(_ target: ReaderLinkTarget) -> CGPoint? {
            guard case let .goTo(_, point) = target else { return nil }
            return point
        }
        let uai2025 = try #require(PDFDocument(url: URL(fileURLWithPath: uai2025Path)))
        let uai2025Page = try #require(uai2025.page(at: 2))
        let uai2025Resolver = CitationPreviewResolver(document: uai2025)
        let uai2025Cases: [(Int, String, [String], String)] = [
            (24, "Quadrianto et al. 2009", ["Estimating labels from label proportions", "J. Mach. Learn. Res."], "Multiple instance regression"),
            (30, "Liu et al. 2019", ["Learning from label proportions with generative adversarial networks", "Proc. NeurIPS"], "Zhigang Lu"),
            (34, "Saket et al. 2022", ["On combining bags", "PMLR"], "C. Scott and J. Zhang")
        ]
        for (annotationIndex, label, positiveContinuations, rejectedSuccessor) in uai2025Cases {
            let link = try #require(links(on: uai2025Page, in: uai2025).first {
                $0.primaryLabelRect == uai2025Page.annotations[annotationIndex].bounds
            })
            guard case let .preview(group) = uai2025Resolver.resolve(link) else {
                Issue.record("UAI 2025 a\(annotationIndex) did not produce a citation preview")
                continue
            }
            #expect(group.items.count == 6)
            #expect(group.items[group.selectedIndex].label == label)
            #expect(group.items[group.selectedIndex].destination == link.target)
            #expect(!group.items[group.selectedIndex].referenceText.contains(rejectedSuccessor))
            #expect(group.items[group.selectedIndex].isResolved)
            for continuation in positiveContinuations {
                #expect(group.items[group.selectedIndex].referenceText.contains(continuation))
            }
        }

        let rayLink = try #require(links(sourceText: "Ray and Page", in: uai2025).first {
            $0.sourcePageIndex == 2 && destinationPage($0.target) == 9
                && abs((destinationPoint($0.target)?.y ?? .greatestFiniteMagnitude) - 442.700) < 1
        })
        guard case let .preview(rayGroup) = uai2025Resolver.resolve(rayLink) else {
            Issue.record("Ray and Page 2001 should preserve its author/year key")
            return
        }
        #expect(rayGroup.items.map(\.label) == ["Ray and Page 2001"])
        #expect(rayGroup.items[0].destination == rayLink.target)
        #expect(rayGroup.items[0].isResolved)
        #expect(rayGroup.items[0].referenceText.contains("S. Ray and D. Page"))
        #expect(!rayGroup.items[0].referenceText.contains("Soumya Ray and Mark Craven"))

        let uai2024 = try #require(PDFDocument(url: URL(fileURLWithPath: uai2024Path)))
        let uai2024Page = try #require(uai2024.page(at: 0))
        let uai2024Resolver = CitationPreviewResolver(document: uai2024)
        let balsubLink = try #require(links(on: uai2024Page, in: uai2024).first {
            sourceText($0, in: uai2024) == "Balsubramani and Freund"
                && destinationPage($0.target) == 10
                && abs((destinationPoint($0.target)?.y ?? .greatestFiniteMagnitude) - 473.003) < 1
        })
        guard case let .preview(balsubGroup) = uai2024Resolver.resolve(balsubLink) else {
            Issue.record("UAI 2024 Balsubramani 2015a should produce a citation preview")
            return
        }
        #expect(balsubGroup.items.map(\.label) == ["Balsubramani and Freund 2015a"])
        #expect(balsubGroup.items[0].destination == balsubLink.target)
        #expect(balsubGroup.items[0].isResolved)
        #expect(balsubGroup.items[0].referenceText.contains("Optimally"))
        #expect(balsubGroup.items[0].referenceText.contains("Learning Theory"))
        for rejected in ["Scalable", "Optimal Binary Classifier", "Avrim Blum", "Stephen Boyd"] {
            #expect(!balsubGroup.items[0].referenceText.contains(rejected))
        }

        let microAdam = try #require(PDFDocument(url: URL(fileURLWithPath: microAdamPath)))
        let microResolver = CitationPreviewResolver(document: microAdam)
        let frantarLinks = allLinks(in: microAdam).filter {
            let text = sourceText($0, in: microAdam)
            return (text == "Frantar et al." || text == "2021")
                && destinationPage($0.target) == 10
                && abs((destinationPoint($0.target)?.y ?? .greatestFiniteMagnitude) - 396.473) < 1
        }
        #expect(frantarLinks.count == 2)
        for link in frantarLinks {
            guard case let .preview(group) = microResolver.resolve(link) else {
                Issue.record("MicroAdam Frantar source fragment did not produce a preview")
                continue
            }
            #expect(group.items.map(\.label) == ["Frantar et al. 2021"])
            #expect(group.items[group.selectedIndex].destination == link.target)
            #expect(group.items[group.selectedIndex].referenceText.contains("E. Frantar"))
            #expect(group.items[group.selectedIndex].isResolved)
            #expect(group.items[group.selectedIndex].referenceText.contains("M-fac: Efficient matrix-free approximations"))
            #expect(group.items[group.selectedIndex].referenceText.contains("second-order information"))
            #expect(!group.items[group.selectedIndex].referenceText.contains("Ghadimi"))
        }
    }
    @Test("Yarowsky bibliography continuation keeps both native author-year links and excludes the next entry")
    func yarowskyBibliographyContinuationContract() throws {
        let path = "test-pdf/citation-annotation-corpus/UAI/2024-adversarial-weak-supervision.pdf"
        guard citationFixtureExists(atPath: path) else { return }
        let document = try #require(PDFDocument(url: URL(fileURLWithPath: path)))
        func sourceText(_ link: ReaderLink) -> String {
            guard let page = document.page(at: link.sourcePageIndex), let rect = link.rects.first else { return "" }
            return page.selection(for: rect)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func targetPage(_ target: ReaderLinkTarget) -> Int? {
            guard case let .goTo(pageIndex, _) = target else { return nil }
            return pageIndex
        }
        func targetPoint(_ target: ReaderLinkTarget) -> CGPoint? {
            guard case let .goTo(_, point) = target else { return nil }
            return point
        }
        let links = allLinks(in: document).filter { link in
            let text = sourceText(link)
            return (text == "Yarowsky" || text == "1995")
                && targetPage(link.target) == 11
                && abs((targetPoint(link.target)?.x ?? .greatestFiniteMagnitude) - 286.712) < 1
                && abs((targetPoint(link.target)?.y ?? .greatestFiniteMagnitude) - 86.91) < 1
        }
        #expect(links.count == 2)
        let resolver = CitationPreviewResolver(document: document)
        for link in links {
            guard case let .preview(group) = resolver.resolve(link) else {
                Issue.record("Yarowsky \(sourceText(link)) did not produce a citation preview")
                continue
            }
            #expect(group.items.map(\.label) == ["Yarowsky 1995"])
            #expect(group.selectedIndex == 0)
            let item = group.items[group.selectedIndex]
            #expect(item.isResolved)
            #expect(item.destination == link.target)
            #expect(item.destination == ReaderLinkTarget.goTo(pageIndex: 11, point: CGPoint(x: 286.712, y: 86.91)))
            #expect(item.referenceText.contains("Unsupervised Word Sense Disambigua"))
            #expect(item.referenceText.contains("tion Rivaling Supervised Methods"))
            #expect(item.referenceText.contains("the 33rd Annual Meeting of the Association for Computa- tional Linguistics"))
            #expect(item.referenceText.contains("pages 189–196, 1995"))
            #expect(!item.referenceText.contains("Yue Yu"))
        }
    }

    @Test("bounded bibliography continuation requires an edge, paragraph evidence, and a real next boundary")
    func boundedBibliographyContinuationBoundaryContract() throws {
        for scenario in CrossPageBibliographyCase.allCases {
            try withTemporaryDirectory { directory in
                let url = try makeCrossPageBibliographyPDF(in: directory, scenario: scenario)
                let document = try #require(PDFDocument(url: url))
                if scenario == .endOfDocument { document.removePage(at: 2) }
                let sourcePage = try #require(document.page(at: 0))
                let sourceLinks = links(on: sourcePage, in: document)
                #expect(sourceLinks.count == 2)
                let resolver = CitationPreviewResolver(document: document)
                for link in sourceLinks {
                    let resolution = resolver.resolve(link)
                    if scenario == .positive || scenario == .terminalPositive {
                        guard case let .preview(group) = resolution else {
                            Issue.record("Positive bibliography continuation did not produce a preview")
                            continue
                        }
                        #expect(group.items.map(\.label) == ["Anchor 2020"])
                        #expect(group.items[group.selectedIndex].isResolved)
                        #expect(group.items[group.selectedIndex].destination == link.target)
                        #expect(group.items[group.selectedIndex].referenceText.contains("next-page continuation"))
                        #expect(!group.items[group.selectedIndex].referenceText.contains("Next Author"))
                    } else if [.sourceNotAtPageEnd, .startsNewEntry, .startsHeading, .endOfDocument].contains(scenario) {
                        guard case let .preview(group) = resolution else {
                            Issue.record("Proven reference end did not preserve the complete original entry")
                            continue
                        }
                        let item = group.items[group.selectedIndex]
                        #expect(item.isResolved)
                        #expect(item.destination == link.target)
                        #expect(!item.referenceText.contains("next-page continuation"))
                        #expect(!item.referenceText.contains("Next Author"))
                    } else {
                        guard case let .activate(target) = resolution else {
                            Issue.record("Ambiguous bibliography seam must not resolve a truncated prefix")
                            continue
                        }
                        #expect(target == link.target)
                    }
                }
            }
        }
    }


    @Test("R03 cross-page author-year fragments require exact brackets, body edges, and native targets")
    func crossPageAuthorYearBoundaryContract() throws {
        func sourceText(_ link: ReaderLink, in document: PDFDocument) -> String {
            guard let page = document.page(at: link.sourcePageIndex), let rect = link.rects.first else { return "" }
            return page.selection(for: rect)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func rejectIncompleteFrantar(_ resolution: LinkHintResolution, caseName: String, source: String) {
            guard case let .preview(group) = resolution else { return }
            #expect(group.items.map(\.label) != ["Frantar et al. 2021"], "\(caseName) \(source) yielded an incomplete Frantar preview")
        }

        try withTemporaryDirectory { directory in
            let url = try makeCrossPageAuthorYearPDF(in: directory, scenario: .positive)
            let document = try #require(PDFDocument(url: url))
            #expect(document.pageCount == 3)
            let authorPage = try #require(document.page(at: 0))
            let yearPage = try #require(document.page(at: 1))
            let bibliographyPage = try #require(document.page(at: 2))
            let authorLink = try #require(links(on: authorPage, in: document).first {
                sourceText($0, in: document) == "Frantar et al."
            })
            let yearLink = try #require(links(on: yearPage, in: document).first {
                sourceText($0, in: document) == "2021"
            })
            #expect(authorPage.string?.contains("[Frantar et al.,") == true)
            #expect(yearPage.string?.contains("2021]") == true)
            #expect((authorLink.rects.first?.minY ?? .greatestFiniteMagnitude) < 126)
            #expect((yearLink.rects.first?.maxY ?? 0) > 665)
            #expect(authorLink.target == yearLink.target)
            #expect(authorLink.target == .goTo(pageIndex: 2, point: CGPoint(x: 48, y: 704)))

            let resolver = CitationPreviewResolver(document: document)
            for link in [authorLink, yearLink] {
                guard case let .preview(group) = resolver.resolve(link) else {
                    Issue.record("Positive cross-page Frantar fragment did not produce a preview")
                    continue
                }
                #expect(group.items.map(\.label) == ["Frantar et al. 2021"])
                #expect(group.selectedIndex == 0)
                let item = group.items[group.selectedIndex]
                #expect(item.isResolved)
                #expect(item.destination == link.target)
                #expect(item.destination == authorLink.target)
                #expect(item.destinationPageIndex == 2)
                #expect(item.referenceText.hasPrefix("E. Frantar, E. Kurtic, and D. Alistarh."))
                #expect(item.referenceText.contains("M-fac: Efficient matrix-free approximations"))
                #expect(item.referenceText.contains("In NeurIPS, 2021."))
                #expect(item.referenceText.contains("Publication continuation remains"))
            }
            #expect(bibliographyPage.string?.contains("E. Frantar, E. Kurtic, and D. Alistarh") == true)
        }

        for scenario in CrossPageAuthorYearCase.allCases where scenario != .positive {
            try withTemporaryDirectory { directory in
                let url = try makeCrossPageAuthorYearPDF(in: directory, scenario: scenario)
                let document = try #require(PDFDocument(url: url))
                let resolver = CitationPreviewResolver(document: document)
                let authorPage = try #require(document.page(at: 0))
                let yearPage = try #require(document.page(at: 1))
                let links = links(on: authorPage, in: document) + links(on: yearPage, in: document)
                let frantarLinks = links.filter {
                    sourceText($0, in: document) == "Frantar et al." || sourceText($0, in: document) == "2021"
                }
                #expect(frantarLinks.count == (scenario == .unlinkedYear ? 1 : 2))
                if scenario == .differingTargets, frantarLinks.count == 2 {
                    #expect(frantarLinks[0].target != frantarLinks[1].target)
                }
                for link in frantarLinks {
                    let resolution = resolver.resolve(link)
                    if scenario == .multiMember, case let .preview(group) = resolution {
                        #expect(group.items.contains { $0.label == "Smith 2020" })
                    }
                    rejectIncompleteFrantar(resolution, caseName: String(describing: scenario), source: sourceText(link, in: document))
                }
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
            let wholeLinks = links.filter { sourceText($0).contains("Whole") && !sourceText($0).contains(";") }
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
                #expect(group.items[group.selectedIndex].destination == link.target)
                #expect(group.items[group.selectedIndex].isResolved)
            }

            let bareLink = try #require(links.first { sourceText($0) == "2022" })
            guard case let .preview(group) = resolver.resolve(bareLink) else {
                Issue.record("A linked year with an unlinked author must resolve from source context")
                return
            }
            #expect(group.items.map(\.label) == ["Bare 2022"])
            for token in ["Red", "Blue"] {
                let link = try #require(links.first { sourceText($0) == token })
                guard case let .preview(customGroup) = resolver.resolve(link) else {
                    Issue.record("Custom opaque multicitation must resolve without a numeric or year assumption")
                    continue
                }
                #expect(customGroup.items.map(\.label) == ["Red", "Blue"])
                #expect(customGroup.items.allSatisfy { $0.isResolved })
                #expect(customGroup.items[customGroup.selectedIndex].destination == link.target)
            }
            let multi = try #require(links.first { sourceText($0).contains("Whole") && sourceText($0).contains(";") })
            guard case let .preview(wholeGroup) = resolver.resolve(multi) else {
                Issue.record("Whole author-year multicitation must preserve unmatched members")
                return
            }
            #expect(wholeGroup.items.map(\.label) == ["Whole 2020", "Square 2021"])
            #expect(wholeGroup.items[0].destination == multi.target)
            #expect(wholeGroup.items[1].destination == nil && wholeGroup.items[1].isUnresolved)
            let suffixLink = try #require(links.first { sourceText($0) == "b" })
            guard case let .preview(suffixGroup) = resolver.resolve(suffixLink) else {
                Issue.record("Suffix b must resolve independently of a")
                return
            }
            #expect(suffixGroup.items.map(\.label) == ["Suffix 2023a", "Suffix 2023b"])
            #expect(suffixGroup.selectedIndex == 1)
            #expect(suffixGroup.items[0].referenceText == "Suffix Author. 2023a. First suffix reference.")
            #expect(suffixGroup.items[1].referenceText == "Suffix Author. 2023b. Second suffix reference.")
            #expect(suffixGroup.items[1].destination == suffixLink.target)
            let continuationLink = try #require(links.first { sourceText($0).contains("SameIndent") })
            guard case let .preview(continued) = resolver.resolve(continuationLink) else {
                Issue.record("Same-indent continuation must remain in its reference")
                return
            }
            #expect(continued.items[0].referenceText == "SameIndent Author. 2024. Title. In NeurIPS.")
            let ampersand = try #require(links.first { sourceText($0) == "2018" })
            guard case let .preview(ampersandGroup) = resolver.resolve(ampersand) else {
                Issue.record("Bare linked year must preserve ampersand-separated authors")
                return
            }
            #expect(ampersandGroup.items[0].label == "Sagi & Rokach 2018")
            #expect(ampersandGroup.items[0].destination == ampersand.target)
        }
    }

    @Test("numeric occurrences preserve independent wrappers, whole links and unresolved range members")
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
            for link in links where link.rects[0].minY < 630 && link.rects[0].minY > 570 {
                guard case let .preview(extra) = resolver.resolve(link) else {
                    Issue.record("Baseline numeric, round range and locator fixtures must preview")
                    continue
                }
                let y = link.rects[0].minY
                if y > 610 {
                    #expect(extra.items.count == 1)
                } else if y > 590 {
                    #expect(extra.items.map(\.label) == ["[1]", "[2]", "[3]"])
                    #expect(extra.items.allSatisfy { $0.isResolved })
                } else {
                    #expect(extra.items.map(\.label) == ["[7]"])
                    #expect(extra.sourceContext?.contains("pp. 13–14") == true)
                }
                #expect(extra.items[extra.selectedIndex].destination == link.target)
            }
            for link in links where link.rects[0].minY < 550 && sourceText(link) != "[7]" {
                guard case let .preview(wholeGroup) = resolver.resolve(link) else {
                    Issue.record("Whole numeric group must preserve members: \(sourceText(link))")
                    continue
                }
                #expect(wholeGroup.items.count == (sourceText(link).contains("–") ? 3 : 2))
                #expect(wholeGroup.items[0].destination == link.target)
                #expect(wholeGroup.items[0].isResolved)
                #expect(wholeGroup.items[0].referenceText == "[1] First verified reference.")
                #expect(wholeGroup.items.dropFirst().allSatisfy { $0.isUnresolved && $0.destination == nil })
            }
            let duplicate = try #require(links.first { sourceText($0) == "[7]" && $0.rects[0].minY < 500 })
            guard case let .preview(duplicateGroup) = resolver.resolve(duplicate) else {
                Issue.record("Same-page duplicate marker must bind to its own native destination")
                return
            }
            #expect(duplicateGroup.items[0].referenceText == "[7] Duplicate reference.")
            #expect(duplicateGroup.items[0].destination == duplicate.target)
            let bibliographyPage = try #require(document.page(at: 1))
            #expect(CitationReferenceEntryExtractor.numericEntry(marker: 7, destinationPoint: CGPoint(x: 48, y: 604), on: bibliographyPage) == nil)
            let locatorLink = try #require(links.first { sourceText($0) == "7" && $0.rects[0].minY < 590 })
            let merged = ReaderLink(sourcePageIndex: 0, rects: wholeBracket.rects + locatorLink.rects,
                target: locatorLink.target, primaryLabelRect: locatorLink.primaryLabelRect)
            guard case let .preview(mergedGroup) = resolver.resolve(merged) else {
                Issue.record("Merged-link primary rectangle must retain selected occurrence")
                return
            }
            #expect(mergedGroup.sourceContext?.contains("pp. 13–14") == true)

            let bare = try #require(links.first { sourceText($0) == "7" && $0.rects[0].minY > 610 && $0.rects[0].minY < 630 })
            let footnote = try #require(sourcePage.selection(for: sourcePage.bounds(for: .cropBox))?.selectionsByLine().first { $0.string?.contains("7. Footnote text") == true })
            let annotation = try #require(sourcePage.annotations.first { $0.bounds == bare.primaryLabelRect })
            let point = CGPoint(x: 48, y: footnote.bounds(for: sourcePage).maxY)
            annotation.action = PDFActionGoTo(destination: PDFDestination(page: sourcePage, at: point))
            let noteLink = ReaderLink(sourcePageIndex: 0, rects: bare.rects, target: .goTo(pageIndex: 0, point: point), primaryLabelRect: bare.primaryLabelRect)
            #expect(resolver.resolve(noteLink) == .activate(noteLink.target))
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
            "Bare 7 then 3",
            "Round (1–3)",
            "Locator [7, pp. 13–14]",
            "7. Footnote text",
            "Whole list [1,3]",
            "Whole range [1–3]",
            "[1,",
            "3]",
            "Duplicate [7]",
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
            ("References", CGFloat(730)),
            ("[1] First verified reference.", CGFloat(700)),
            ("[2] Second verified reference.", CGFloat(680)),
            ("[3] Third verified reference.", CGFloat(660)),
            ("[7] Seventh verified reference.", CGFloat(640)),
            ("[7] Duplicate reference.", CGFloat(620)),
            ("[7] This reference is too wide for the detected column.", CGFloat(600)),
        ]
        context.beginPDFPage(nil)
        for (text, y) in bibliographyLines {
            context.textPosition = CGPoint(x: 48, y: y)
            CTLineDraw(
                CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)),
                context
            )
        }
        for (text, y) in [("[90] Remote entry.", CGFloat(700)), ("Remote continuation.", CGFloat(680))] {
            context.textPosition = CGPoint(x: 350, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
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
            AnnotationSpec(lineIndex: 4, token: "7", occurrence: 0, destinationY: 640),
            AnnotationSpec(lineIndex: 4, token: "3", occurrence: 0, destinationY: 660),
            AnnotationSpec(lineIndex: 5, token: "1", occurrence: 0, destinationY: 700),
            AnnotationSpec(lineIndex: 5, token: "3", occurrence: 0, destinationY: 660),
            AnnotationSpec(lineIndex: 6, token: "7", occurrence: 0, destinationY: 640),
            AnnotationSpec(lineIndex: 8, token: "[1,3]", occurrence: 0, destinationY: 700),
            AnnotationSpec(lineIndex: 9, token: "[1–3]", occurrence: 0, destinationY: 700),
            AnnotationSpec(lineIndex: 12, token: "[7]", occurrence: 0, destinationY: 620),
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

        let wrappedRange = (try #require(sourcePage.string) as NSString).range(of: "[1,\n3]")
        guard wrappedRange.location != NSNotFound, let wrapped = sourcePage.selection(for: wrappedRange) else {
            throw PDFFixtureError.couldNotWriteDocument
        }
        let multilineAnnotation = PDFAnnotation(bounds: wrapped.bounds(for: sourcePage), forType: .link, withProperties: nil)
        multilineAnnotation.action = PDFActionGoTo(destination: PDFDestination(page: destinationPage, at: CGPoint(x: 48, y: 704)))
        sourcePage.addAnnotation(multilineAnnotation)
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
            "[Red; Blue]",
            "(Whole 2020; Square 2021)",
            "(Suffix 2023a,b)",
            "(SameIndent 2024)",
            "Sagi & Rokach 2018",
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
            ("[Red] Custom red reference without a year.", CGFloat(640)),
            ("[Blue] Custom blue reference without a year.", CGFloat(620)),
            ("Suffix Author. 2023a. First suffix reference.", CGFloat(600)),
            ("Suffix Author. 2023b. Second suffix reference.", CGFloat(580)),
            ("SameIndent Author. 2024. Title.", CGFloat(560)),
            ("In NeurIPS.", CGFloat(546)),
            ("1234. Another reference.", CGFloat(530)),
            ("Sagi, O. and Rokach, L. 2018. Bare authors.", CGFloat(500)),
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
            AnnotationSpec(lineIndex: 3, token: "Red", occurrence: 0, destinationY: 640),
            AnnotationSpec(lineIndex: 3, token: "Blue", occurrence: 0, destinationY: 620),
            AnnotationSpec(lineIndex: 4, token: "(Whole 2020; Square 2021)", occurrence: 0, destinationY: 700),
            AnnotationSpec(lineIndex: 5, token: "Suffix 2023a", occurrence: 0, destinationY: 600),
            AnnotationSpec(lineIndex: 5, token: "b", occurrence: 0, destinationY: 580),
            AnnotationSpec(lineIndex: 6, token: "(SameIndent 2024)", occurrence: 0, destinationY: 560),
            AnnotationSpec(lineIndex: 7, token: "2018", occurrence: 0, destinationY: 500),
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

    private func makeCrossPageAuthorYearPDF(
        in directory: URL,
        scenario: CrossPageAuthorYearCase
    ) throws -> URL {
        let sourceURL = directory.appendingPathComponent("cross-page-author-year-\(UUID().uuidString).pdf")
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
        let authorText: String
        let yearText: String
        let bodyBelowAuthor: String?
        let bodyBeforeYear: String?
        let annotateYear: Bool
        let yearDestinationY: CGFloat
        switch scenario {
        case .positive, .differingTargets, .unlinkedYear, .interveningBodyBelowAuthor, .precedingBodyBeforeYear:
            authorText = "[Frantar et al.,"
            yearText = "2021]"
            bodyBelowAuthor = scenario == .interveningBodyBelowAuthor ? "Intervening body text follows below." : nil
            bodyBeforeYear = scenario == .precedingBodyBeforeYear ? "Intervening body text precedes above." : nil
            annotateYear = scenario != .unlinkedYear
            yearDestinationY = scenario == .differingTargets ? 580 : 700
        case .sameTargetUnrelated:
            authorText = "Earlier work: Frantar et al.,"
            yearText = "2021]"
            bodyBelowAuthor = nil
            bodyBeforeYear = nil
            annotateYear = true
            yearDestinationY = 700
        case .unmatchedAuthorBracket:
            authorText = "Frantar et al.,"
            yearText = "2021]"
            bodyBelowAuthor = nil
            bodyBeforeYear = nil
            annotateYear = true
            yearDestinationY = 700
        case .unmatchedYearBracket:
            authorText = "[Frantar et al.,"
            yearText = "2021"
            bodyBelowAuthor = nil
            bodyBeforeYear = nil
            annotateYear = true
            yearDestinationY = 700
        case .multiMember:
            authorText = "[Smith 2020; Frantar et al.,"
            yearText = "2021]"
            bodyBelowAuthor = nil
            bodyBeforeYear = nil
            annotateYear = true
            yearDestinationY = 700
        }

        let authorLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: authorText, attributes: attributes)
        )
        let yearLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: yearText, attributes: attributes)
        )
        let bodyBelowLine = bodyBelowAuthor.map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes))
        }
        let bodyBeforeLine = bodyBeforeYear.map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes))
        }
        let referenceLines = [
            "E. Frantar, E. Kurtic, and D. Alistarh.",
            "M-fac: Efficient matrix-free approximations",
            "of second-order information. In NeurIPS, 2021.",
            "Publication continuation remains in the same",
            "bibliography entry.",
        ].map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes)) }
        let duplicateLine = CTLineCreateWithAttributedString(NSAttributedString(
            string: "E. Frantar et al. Different work. 2021.",
            attributes: attributes
        ))

        context.beginPDFPage(nil)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 48, y: 100)
        CTLineDraw(authorLine, context)
        if let bodyBelowLine {
            context.textPosition = CGPoint(x: 48, y: 70)
            CTLineDraw(bodyBelowLine, context)
        }
        context.endPDFPage()

        context.beginPDFPage(nil)
        context.textMatrix = .identity
        if let bodyBeforeLine {
            context.textPosition = CGPoint(x: 48, y: 740)
            CTLineDraw(bodyBeforeLine, context)
        }
        context.textPosition = CGPoint(x: 48, y: 710)
        CTLineDraw(yearLine, context)
        context.endPDFPage()

        context.beginPDFPage(nil)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 48, y: 760)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "References", attributes: attributes)), context)
        for (index, line) in referenceLines.enumerated() {
            context.textPosition = CGPoint(x: 48, y: 700 - CGFloat(index) * 16)
            CTLineDraw(line, context)
        }
        if scenario == .differingTargets {
            context.textPosition = CGPoint(x: 48, y: 580)
            CTLineDraw(duplicateLine, context)
        }
        context.endPDFPage()
        context.closePDF()

        guard let document = PDFDocument(url: sourceURL),
              let authorPage = document.page(at: 0),
              let yearPage = document.page(at: 1),
              let bibliographyPage = document.page(at: 2)
        else { throw PDFFixtureError.couldNotOpenGeneratedDocument }

        func addAnnotation(
            to page: PDFPage,
            line: CTLine,
            lineText: String,
            token: String,
            baselineY: CGFloat,
            destinationY: CGFloat
        ) {
            let text = lineText as NSString
            let range = text.range(of: token)
            guard range.location != NSNotFound else { return }
            let start = CTLineGetOffsetForStringIndex(line, range.location, nil)
            let end = CTLineGetOffsetForStringIndex(line, range.location + range.length, nil)
            let bounds = CGRect(
                x: 48 + start - 1,
                y: baselineY - 3,
                width: max(8, end - start),
                height: 18
            )
            let annotation = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
            annotation.action = PDFActionGoTo(destination: PDFDestination(
                page: bibliographyPage,
                at: CGPoint(x: 48, y: destinationY + 4)
            ))
            page.addAnnotation(annotation)
        }

        addAnnotation(
            to: authorPage,
            line: authorLine,
            lineText: authorText,
            token: "Frantar et al.",
            baselineY: 100,
            destinationY: 700
        )
        if annotateYear {
            addAnnotation(
                to: yearPage,
                line: yearLine,
                lineText: yearText,
                token: "2021",
                baselineY: 710,
                destinationY: yearDestinationY
            )
        }

        let outputURL = directory.appendingPathComponent("cross-page-author-year.pdf")
        guard document.write(to: outputURL), PDFDocument(url: outputURL) != nil else {
            throw PDFFixtureError.couldNotWriteDocument
        }
        return outputURL
    }

    private func makeCrossPageBibliographyPDF(
        in directory: URL,
        scenario: CrossPageBibliographyCase
    ) throws -> URL {
        let sourceURL = directory.appendingPathComponent("cross-page-bibliography-\(UUID().uuidString).pdf")
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
        func line(_ text: String) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        func draw(_ text: String, at point: CGPoint) {
            context.textPosition = point
            CTLineDraw(line(text), context)
        }

        let sourceText = "[Anchor, 2020]"
        let sourceLine = line(sourceText)
        let entryText: String
        switch scenario {
        case .sourceNotAtPageEnd, .endOfDocument:
            entryText = "Anchor Author. 2020. A deliberately wrapped bibliography title ends."
        case .terminalPositive, .terminalAmbiguous, .capitalizedAmbiguous:
            entryText = "Anchor Author. A deliberately wrapped bibliography title with its publication year already present. 2020."
        case .unrelatedContinuation, .missingBoundary, .positive, .startsNewEntry, .startsHeading, .mismatchedIndent:
            entryText = "Anchor Author. 2020. A deliberately wrapped bibliography title continues without a terminal mark"
        }
        let entryLines = wrapTextInsidePage(entryText, attributes: attributes, maxWidth: 500)
        let entryLastBaseline: CGFloat = scenario == .sourceNotAtPageEnd ? 420 : 70
        let entryFirstBaseline = entryLastBaseline + CGFloat(max(0, entryLines.count - 1) * 16)

        context.beginPDFPage(nil)
        context.textMatrix = .identity
        draw(sourceText, at: CGPoint(x: 48, y: 700))
        context.endPDFPage()

        context.beginPDFPage(nil)
        context.textMatrix = .identity
        draw("References", at: CGPoint(x: 48, y: 740))
        for (index, text) in entryLines.enumerated() {
            draw(text, at: CGPoint(
                x: index == 0 ? 48 : 64,
                y: entryFirstBaseline - CGFloat(index * 16)
            ))
        }
        context.endPDFPage()

        context.beginPDFPage(nil)
        context.textMatrix = .identity
        switch scenario {
        case .positive:
            draw("next-page continuation supplies the remaining venue and pages.", at: CGPoint(x: 64, y: 720))
            draw("Additional publication details remain here.", at: CGPoint(x: 64, y: 704))
            draw("Next Author. Next reference.", at: CGPoint(x: 48, y: 680))
        case .startsNewEntry:
            draw("Next Author. Next reference.", at: CGPoint(x: 48, y: 720))
            draw("next-page continuation should not be borrowed.", at: CGPoint(x: 64, y: 704))
        case .startsHeading:
            draw("References", at: CGPoint(x: 48, y: 740))
            draw("next-page continuation should not be borrowed.", at: CGPoint(x: 64, y: 720))
            draw("Next Author. Next reference.", at: CGPoint(x: 48, y: 680))
        case .sourceNotAtPageEnd:
            draw("next-page continuation should not be borrowed.", at: CGPoint(x: 64, y: 720))
            draw("Next Author. Next reference.", at: CGPoint(x: 48, y: 680))
        case .unrelatedContinuation:
            draw("Unrelated continuation without paragraph evidence.", at: CGPoint(x: 64, y: 720))
            draw("Next Author. Next reference.", at: CGPoint(x: 48, y: 680))
        case .missingBoundary:
            draw("next-page continuation has no proven boundary.", at: CGPoint(x: 64, y: 720))
            draw("another continuation line remains unbounded.", at: CGPoint(x: 64, y: 704))
        case .terminalPositive:
            draw("In next-page continuation with the remaining venue.", at: CGPoint(x: 64, y: 720))
            draw("Next Author. Next reference.", at: CGPoint(x: 48, y: 680))
        case .terminalAmbiguous:
            draw("Unrelated continuation after a terminal year.", at: CGPoint(x: 64, y: 720))
            draw("Next Author. Next reference.", at: CGPoint(x: 48, y: 680))
        case .capitalizedAmbiguous:
            draw("Deep Learning.", at: CGPoint(x: 64, y: 720))
            draw("Next Author. Next reference.", at: CGPoint(x: 48, y: 680))
        case .mismatchedIndent:
            draw("next-page continuation with different indentation.", at: CGPoint(x: 80, y: 720))
            draw("Next Author. Next reference.", at: CGPoint(x: 48, y: 680))
        case .endOfDocument:
            break
        }
        context.endPDFPage()
        context.closePDF()

        guard let document = PDFDocument(url: sourceURL),
              let sourcePage = document.page(at: 0),
              let bibliographyPage = document.page(at: 1)
        else { throw PDFFixtureError.couldNotOpenGeneratedDocument }

        func addAnnotation(to page: PDFPage, token: String) {
            let text = sourceText as NSString
            let range = text.range(of: token)
            guard range.location != NSNotFound else { return }
            let start = CTLineGetOffsetForStringIndex(sourceLine, range.location, nil)
            let end = CTLineGetOffsetForStringIndex(sourceLine, range.location + range.length, nil)
            let annotation = PDFAnnotation(
                bounds: CGRect(x: 48 + start - 1, y: 697, width: max(8, end - start), height: 18),
                forType: .link,
                withProperties: nil
            )
            annotation.action = PDFActionGoTo(destination: PDFDestination(
                page: bibliographyPage,
                at: CGPoint(x: 48, y: entryFirstBaseline + 4)
            ))
            page.addAnnotation(annotation)
        }
        addAnnotation(to: sourcePage, token: "Anchor")
        addAnnotation(to: sourcePage, token: "2020")

        let outputURL = directory.appendingPathComponent("cross-page-bibliography.pdf")
        guard document.write(to: outputURL), PDFDocument(url: outputURL) != nil else {
            throw PDFFixtureError.couldNotWriteDocument
        }
        return outputURL
    }

    private func wrapTextInsidePage(
        _ text: String,
        attributes: [NSAttributedString.Key: Any],
        maxWidth: CGFloat
    ) -> [String] {
        var result: [String] = []
        var current = ""
        for word in text.split(whereSeparator: \.isWhitespace) {
            let value = String(word)
            let candidate = current.isEmpty ? value : current + " " + value
            let candidateLine = CTLineCreateWithAttributedString(
                NSAttributedString(string: candidate, attributes: attributes)
            )
            let width = CGFloat(CTLineGetTypographicBounds(candidateLine, nil, nil, nil))
            if !current.isEmpty, width > maxWidth {
                result.append(current)
                current = value
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
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
