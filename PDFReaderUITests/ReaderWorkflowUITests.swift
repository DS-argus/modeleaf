import AppKit
import Carbon
import CoreGraphics
import CoreText
import PDFKit
import CryptoKit
import XCTest

final class ReaderWorkflowUITests: XCTestCase {
    @MainActor
    func testE2E01EmptyLaunchRemappedOpenAndRealOpenPanel() throws {
        try withEnvironment(
            config: """
            [keymap]
            "document.open" = ["<D-F12>"]
            """
        ) { environment, app in
            let pdf = try makePDF(in: environment.fixtures, name: "Remapped.pdf", pages: 20)
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
            app.typeKey("o", modifierFlags: .command)
            XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 0.4))

            app.typeKey(.F12, modifierFlags: .command)
            try choosePDF(pdf, in: app)

            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", "Modeleaf fixture · page 1")).firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(tab(named: "Remapped.pdf", in: app).exists)
            XCTAssertTrue(waitForStatus("status.page", containing: "1 / 20", in: app))
        }
    }

    @MainActor
    func testE2E02TwoDocumentsTabMovementAndClose() throws {
        try withEnvironment { environment, app in
            let first = try makePDF(in: environment.fixtures, name: "First.pdf", pages: 3)
            let second = try makePDF(in: environment.fixtures, name: "Second.pdf", pages: 4)
            app.typeKey("o", modifierFlags: .command)
            try choosePDF(first, in: app)
            app.typeKey("o", modifierFlags: .command)
            try choosePDF(second, in: app)

            XCTAssertEqual(app.radioButtons.count, 2)
            app.typeKey("p", modifierFlags: .shift)
            XCTAssertEqual(tab(named: "First.pdf", in: app).value as? String, "selected")
            app.typeKey("n", modifierFlags: .shift)
            XCTAssertEqual(tab(named: "Second.pdf", in: app).value as? String, "selected")

            app.typeKey("w", modifierFlags: .command)
            XCTAssertFalse(tab(named: "Second.pdf", in: app).exists)
            XCTAssertEqual(tab(named: "First.pdf", in: app).value as? String, "selected")
        }
    }

    @MainActor
    func testE2E03VimMovementAndPageKeys() throws {
        try withEnvironment { environment, app in
            let pdf = try makePDF(in: environment.fixtures, name: "Movement.pdf", pages: 20)
            app.typeKey("o", modifierFlags: .command)
            try choosePDF(pdf, in: app)

            app.typeText("n")
            XCTAssertTrue(waitForStatus("status.page", containing: "2 / 20", in: app))
            app.typeText("p")
            XCTAssertTrue(waitForStatus("status.page", containing: "1 / 20", in: app))
            app.typeText("jkdulh")
            XCTAssertTrue(app.descendants(matching: .any)["pdfCanvas"].exists)
        }
    }

    @MainActor
    func testE2E04FirstLastAndPagePromptValidation() throws {
        try withEnvironment { environment, app in
            let pdf = try makePDF(in: environment.fixtures, name: "Pages.pdf", pages: 20)
            app.typeKey("o", modifierFlags: .command)
            try choosePDF(pdf, in: app)

            app.typeText("G")
            XCTAssertTrue(waitForStatus("status.page", containing: "20 / 20", in: app))
            app.typeText("gg")
            XCTAssertTrue(waitForStatus("status.page", containing: "1 / 20", in: app))
            app.typeText("g12")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitForStatus("status.page", containing: "12 / 20", in: app))

            app.typeText("g99")
            app.typeKey(.return, modifierFlags: [])
            let validation = app.descendants(matching: .any)["prompt.validation"]
            XCTAssertTrue(validation.waitForExistence(timeout: 2))
            XCTAssertTrue(validation.labelOrValue.contains("outside 1–20"))
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertFalse(app.descendants(matching: .any)["promptOverlay"].exists)
        }
    }

    @MainActor
    func testE2E05CommittedSearchTraversalAndClear() throws {
        try withEnvironment { environment, app in
            let pdf = try makePDF(
                in: environment.fixtures,
                name: "Search.pdf",
                pages: 3,
                text: "needle needle navigation"
            )
            app.typeKey("o", modifierFlags: .command)
            try choosePDF(pdf, in: app)

            app.typeText("/")
            let field = app.textFields["prompt.textField"]
            XCTAssertTrue(field.waitForExistence(timeout: 2))
            field.typeText("needle")
            XCTAssertFalse(status("status.diagnostic", in: app).labelOrValue.contains("Searching"))
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitForStatus("status.diagnostic", containing: "1 / 6", in: app))
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitForStatus("status.diagnostic", containing: "2 / 6", in: app))
            app.typeKey(.return, modifierFlags: .shift)
            XCTAssertTrue(waitForStatus("status.diagnostic", containing: "1 / 6", in: app))
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(waitForStatus("status.context", containing: "NORMAL", in: app))
        }
    }

    @MainActor
    func testE2E06ValidRemapReplacesRemovedDefault() throws {
        try withEnvironment(
            config: """
            [keymap]
            "page.next" = ["x"]
            """
        ) { environment, app in
            let pdf = try makePDF(in: environment.fixtures, name: "Remap.pdf", pages: 3)
            app.typeKey("o", modifierFlags: .command)
            try choosePDF(pdf, in: app)
            app.typeText("n")
            XCTAssertTrue(status("status.page", in: app).labelOrValue.contains("1 / 3"))
            app.typeText("x")
            XCTAssertTrue(waitForStatus("status.page", containing: "2 / 3", in: app))
        }
    }

    @MainActor
    func testE2E07InvalidConfigFallsBackWithAggregateDiagnostic() throws {
        try withEnvironment(
            config: """
            [navigation]
            zoom_factor = 9
            [keymap]
            "document.open" = ["o"]
            "bookmark.toggle" = ["b"]
            """
        ) { _, app in
            let diagnostic = status("status.diagnostic", in: app)
            XCTAssertTrue(diagnostic.waitForExistence(timeout: 5))
            XCTAssertTrue(diagnostic.labelOrValue.contains("built-in defaults active"))
            XCTAssertTrue((diagnostic.value as? String)?.contains("error") == true)
            app.typeKey("o", modifierFlags: .command)
            XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 2))
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    @MainActor
    func testE2E08FourThemesExposeStableSemanticSurfaces() throws {
        let themes = ["catppuccin-mocha", "tokyo-night", "gruvbox-dark", "nord"]
        for theme in themes {
            try withEnvironment(
                config: """
                [theme]
                built_in = "\(theme)"
                """
            ) { _, app in
                XCTAssertTrue(app.descendants(matching: .any)["emptyState"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.descendants(matching: .any)["statusBar"].exists)
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "theme-\(theme)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @MainActor
    func testE2E09GlobalMenuAndPromptPrecedence() throws {
        try withEnvironment(
            config: """
            [keymap]
            "document.open" = ["<D-F12>"]
            """
        ) { environment, app in
            app.menuBars.menuBarItems["File"].click()
            XCTAssertTrue(app.menuItems["Open PDF…"].exists)
            app.typeKey(.escape, modifierFlags: [])

            let pdf = try makePDF(in: environment.fixtures, name: "Menu.pdf", pages: 2)
            app.typeKey(.F12, modifierFlags: .command)
            try choosePDF(pdf, in: app)
            app.typeText("/")
            let field = app.textFields["prompt.textField"]
            XCTAssertTrue(field.waitForExistence(timeout: 2))
            field.typeText("literal")
            app.typeKey(.F12, modifierFlags: .command)
            XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 2))
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertFalse(app.descendants(matching: .any)["promptOverlay"].exists)
        }
    }

    @MainActor
    func testE2E10ResponderFocusLoopAndAccessibilityAudit() throws {
        try withEnvironment { environment, app in
            try app.performAccessibilityAudit()
            let first = try makePDF(in: environment.fixtures, name: "Audit.pdf", pages: 2)
            let second = try makePDF(in: environment.fixtures, name: "Audit Two.pdf", pages: 2)
            app.typeKey("o", modifierFlags: .command)
            try choosePDF(first, in: app)
            let canvas = app.descendants(matching: .any)["pdfDocumentView"]
            XCTAssertTrue(canvas.waitForExistence(timeout: 5))
            XCTAssertTrue(try hasKeyboardFocus(canvas))
            app.typeKey(.tab, modifierFlags: [])
            XCTAssertFalse(try hasKeyboardFocus(canvas))
            app.typeKey(.tab, modifierFlags: [.shift])
            XCTAssertTrue(try hasKeyboardFocus(canvas))
            app.typeText("/")
            let prompt = app.textFields["prompt.textField"]
            XCTAssertTrue(prompt.waitForExistence(timeout: 2))
            XCTAssertTrue(try hasKeyboardFocus(prompt))
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(try hasKeyboardFocus(canvas))
            app.typeKey("o", modifierFlags: .command)
            try choosePDF(second, in: app)
            XCTAssertEqual(app.radioButtons.count, 2)
            try app.performAccessibilityAudit()
        }
    }

    @MainActor
    func testE2E11ExcludedCapabilitiesStayUnreachable() throws {
        try withEnvironment { environment, app in
            let pdf = try makePDF(in: environment.fixtures, name: "Read Only.pdf", pages: 2)
            app.typeKey("o", modifierFlags: .command)
            try choosePDF(pdf, in: app)
            XCTAssertEqual(app.toolbars.count, 0)
            XCTAssertEqual(app.outlines.count, 0)
            for title in ["Print…", "Export…", "Add Bookmark", "Add Annotation", "Back", "Forward"] {
                XCTAssertFalse(app.menuItems[title].exists, "Unexpected capability: \(title)")
            }
            app.descendants(matching: .any)["pdfCanvas"].rightClick()
            for title in ["Print…", "Export…", "Add Annotation"] {
                XCTAssertFalse(app.menuItems[title].exists, "Unexpected context action: \(title)")
            }
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    func testE2E12ProductionSourceContainsNoTestOverrideSurface() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard let enumerator = FileManager.default.enumerator(
            at: root.appendingPathComponent("PDFReaderApp"),
            includingPropertiesForKeys: nil
        ) else {
            XCTFail("Could not enumerate production sources")
            return
        }
        var sources: [URL] = []
        for case let source as URL in enumerator where source.pathExtension == "swift" {
            sources.append(source)
        }
        XCTAssertFalse(sources.isEmpty, "Production source audit must not pass vacuously")
        let forbidden = ["PDF_READER_TEST", "fixtureURLOverride", "configURLOverride"]
        for source in sources {
            let text = try String(contentsOf: source, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(text.contains(token), "\(source.lastPathComponent) exposes \(token)")
            }
        }
    }

    @MainActor
    func testE2ETOCWidget() throws {
        try withEnvironment { environment, app in
            let pdf = try makeTOCPDF(in: environment.fixtures, name: "TOC.pdf")
            app.typeKey("o", modifierFlags: .command)
            try choosePDF(pdf, in: app)
            let sourceHash = try sha256(pdf)
            app.typeText("t")
            let widget = app.descendants(matching: .any)["tocWidget"]
            XCTAssertTrue(widget.waitForExistence(timeout: 3))
            XCTAssertFalse(app.descendants(matching: .any)["tocDrawer.header"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["tocWidget.row.0"].waitForExistence(timeout: 2))
            app.typeText("J")
            app.typeText("K")
            app.typeText("12")
            let selectedRow = app.descendants(matching: .any)["tocWidget.row.11"]
            XCTAssertTrue(selectedRow.waitForExistence(timeout: 2))
            XCTAssertEqual(selectedRow.value as? String, "Selected")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "toc-widget-list-only"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(try sha256(pdf), sourceHash)
            XCTAssertTrue(app.descendants(matching: .any)["pdfCanvas"].exists)
        }
    }

    @MainActor
    func testE2E13NativePromptLiteralDeadKeyAndUnicodeText() throws {
        try withEnvironment { environment, app in
            let pdf = try makePDF(in: environment.fixtures, name: "Unicode.pdf", pages: 2)
            app.typeKey("o", modifierFlags: .command)
            try choosePDF(pdf, in: app)
            app.typeText("/")
            let field = app.textFields["prompt.textField"]
            XCTAssertTrue(field.waitForExistence(timeout: 2))
            field.typeText("jké한글")
            XCTAssertEqual(field.value as? String, "jké한글")
            field.typeKey(.delete, modifierFlags: [])
            XCTAssertEqual(field.value as? String, "jké한")
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    @MainActor
    func testE2E14PromptSafeGlobalRejectsTextAndAcceptsCommandF12() throws {
        try withEnvironment(
            config: """
            [keymap]
            "document.open" = ["o"]
            """
        ) { _, app in
            XCTAssertTrue(status("status.diagnostic", in: app).labelOrValue.contains("built-in defaults active"))
        }

        try withEnvironment(
            config: """
            [keymap]
            "document.open" = ["<D-F12>"]
            """
        ) { environment, app in
            let pdf = try makePDF(in: environment.fixtures, name: "Safe Global.pdf", pages: 2)
            app.typeKey(.F12, modifierFlags: .command)
            try choosePDF(pdf, in: app)
            app.typeText("/")
            let field = app.textFields["prompt.textField"]
            XCTAssertTrue(field.waitForExistence(timeout: 2))
            field.typeText("literal")
            app.typeKey(.F12, modifierFlags: .command)
            XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 2))
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertFalse(app.descendants(matching: .any)["promptOverlay"].exists)
        }
    }

    @MainActor
    func testE2E15ViewerFirstSurfaceContainsNoResearchWorkflow() throws {
        try withEnvironment { environment, app in
            let pdf = try makePDF(in: environment.fixtures, name: "Viewer.pdf", pages: 2)
            app.typeKey("o", modifierFlags: .command)
            try choosePDF(pdf, in: app)
            app.typeText("/")
            XCTAssertTrue(app.descendants(matching: .any)["promptOverlay"].waitForExistence(timeout: 2))
            let forbidden = [
                "Bookmark", "Annotation", "Highlight", "Portal", "Smart Jump",
                "Command Palette", "Library", "Script", "Plugin", "OCR",
            ]
            for term in forbidden {
                XCTAssertFalse(app.staticTexts[term].exists)
                XCTAssertFalse(app.buttons[term].exists)
                XCTAssertFalse(app.menuItems[term].exists)
            }
            XCTAssertTrue(app.descendants(matching: .any)["statusBar"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["tabBar"].exists)
        }
    }

    @MainActor
    func testE2E16WholeBracketCitationPreviewPreservesPositionUntilEnter() throws {
        try withEnvironment { environment, app in
            let url = try makePDF(
                in: environment.fixtures, name: "Citation.pdf", pages: 8,
                text: "[7] Alpha. Verified citation reference. 2024."
            )
            guard let document = PDFDocument(url: url),
                  let source = document.page(at: 0),
                  let target = document.page(at: 1),
                  let selection = source.selection(for: NSRange(location: 0, length: 3))
            else { throw UITestFixtureError.cannotCreatePDF }
            let annotation = PDFAnnotation(bounds: selection.bounds(for: source), forType: .link, withProperties: nil)
            annotation.action = PDFActionGoTo(destination: PDFDestination(page: target, at: CGPoint(x: 72, y: 720)))
            source.addAnnotation(annotation)
            guard document.write(to: url) else { throw UITestFixtureError.cannotCreatePDF }
            app.typeKey("o", modifierFlags: .command)
            try choosePDF(url, in: app)
            app.typeText("gg")
            XCTAssertTrue(waitForStatus("status.page", containing: "1 / 8", in: app))
            app.typeKey("c", modifierFlags: .shift)
            XCTAssertTrue(waitForStatus("status.experimentalMode", containing: "CITATION PREVIEW", in: app))
            let originalPage = status("status.page", in: app).labelOrValue
            app.typeText("ff")
            let reference = app.textViews["citationPreview.referenceText"]
            XCTAssertTrue(reference.waitForExistence(timeout: 3))
            XCTAssertTrue(reference.labelOrValue.contains("Verified citation reference"))
            XCTAssertEqual(status("status.page", in: app).labelOrValue, originalPage)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "whole-bracket-citation-preview"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertEqual(status("status.page", in: app).labelOrValue, originalPage)
            app.typeText("ff")
            XCTAssertTrue(reference.waitForExistence(timeout: 3))
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitForStatus("status.page", containing: "2 / 8", in: app))
        }
    }
    @MainActor
    func testE2E17RealCitationFamiliesPreserveSelectionAndNativeTargets() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let cases: [(name: String, file: String, page: Int, annotations: [Int], members: Int)] = [
            ("numeric-single", "D01-primacy.pdf", 0, [12], 1),
            ("numeric-list", "D01-primacy.pdf", 0, Array(1...5), 5),
            ("numeric-range", "D03-neuralplexer3.pdf", 3, [2, 3], 3),
            ("author-single", "D08-grammaticality.pdf", 0, [0, 1], 1),
            ("author-group", "D11-submix.pdf", 0, Array(1...14), 7),
            ("opaque-group", "D15-improving-bandits.pdf", 0, [4, 5], 2),
            ("round-group", "D05-molvision.pdf", 0, [2, 3], 2),
            ("locator", "D18-orthogonal-manifold.pdf", 5, [6, 7], 1),
        ]
        for sample in cases {
            let original = root.appendingPathComponent("docs/citation-papers/\(sample.file)")
            guard FileManager.default.fileExists(atPath: original.path) else {
                throw XCTSkip("Local research fixture unavailable: \(sample.file)")
            }
            try withEnvironment { environment, app in
                let originalHash = try sha256(original)
                let document = try XCTUnwrap(PDFDocument(url: original))
                let source = try XCTUnwrap(document.page(at: sample.page))
                let first = source.annotations[sample.annotations[0]]
                let target = try XCTUnwrap((first.action as? PDFActionGoTo)?.destination.page)
                let targetPage = document.index(for: target) + 1
                for (index, annotation) in source.annotations.enumerated() where !sample.annotations.contains(index) {
                    source.removeAnnotation(annotation)
                }
                let copy = environment.fixtures.appendingPathComponent("\(sample.name).pdf")
                XCTAssertTrue(document.write(to: copy))
                app.typeKey("o", modifierFlags: .command)
                try choosePDF(copy, in: app)
                app.typeText("gg")
                app.typeKey("f", modifierFlags: .shift)
                for _ in 0..<sample.page { app.typeText("n") }
                XCTAssertTrue(waitForStatus("status.page", containing: "\(sample.page + 1) /", in: app), sample.name)
                app.typeKey("c", modifierFlags: .shift)
                XCTAssertTrue(waitForStatus("status.experimentalMode", containing: "CITATION PREVIEW", in: app))
                let originalPage = status("status.page", in: app).labelOrValue
                app.typeText("ff")
                let reference = app.textViews["citationPreview.referenceText"]
                XCTAssertTrue(reference.waitForExistence(timeout: 5), sample.name)
                XCTAssertTrue(waitForStatus("citationPreviewOverlay", containing: "of \(sample.members)", in: app), sample.name)
                let firstSelection = status("citationPreviewOverlay", in: app).labelOrValue
                XCTAssertFalse(firstSelection.contains("unresolved"), sample.name)
                if sample.members > 1 {
                    app.typeText("l")
                    XCTAssertNotEqual(status("citationPreviewOverlay", in: app).labelOrValue, firstSelection)
                    app.typeText("h")
                    XCTAssertEqual(status("citationPreviewOverlay", in: app).labelOrValue, firstSelection)
                    app.typeKey(.tab, modifierFlags: [])
                    XCTAssertNotEqual(status("citationPreviewOverlay", in: app).labelOrValue, firstSelection)
                    app.typeKey(.tab, modifierFlags: .shift)
                    XCTAssertEqual(status("citationPreviewOverlay", in: app).labelOrValue, firstSelection)
                    app.typeText("h")
                    XCTAssertNotEqual(status("citationPreviewOverlay", in: app).labelOrValue, firstSelection)
                    app.typeText("l")
                    XCTAssertEqual(status("citationPreviewOverlay", in: app).labelOrValue, firstSelection)
                }
                XCTAssertEqual(status("status.page", in: app).labelOrValue, originalPage)
                if sample.name == "locator" { XCTAssertTrue(reference.labelOrValue.contains("Chapter 3")) }
                let image = XCTAttachment(screenshot: app.screenshot())
                image.name = "native-\(sample.name)"
                image.lifetime = .keepAlways
                add(image)
                app.typeKey(.escape, modifierFlags: [])
                XCTAssertFalse(reference.exists)
                XCTAssertEqual(status("status.page", in: app).labelOrValue, originalPage)
                app.typeText("ff")
                XCTAssertTrue(reference.waitForExistence(timeout: 5))
                app.typeKey(.return, modifierFlags: [])
                XCTAssertTrue(waitForStatus("status.page", containing: "\(targetPage) /", in: app), sample.name)
                app.typeKey("o", modifierFlags: .control)
                XCTAssertTrue(waitForStatus("status.page", containing: "\(sample.page + 1) /", in: app), sample.name)
                XCTAssertEqual(try sha256(original), originalHash)
            }
        }
    }
    @MainActor
    func testE2E18UnresolvedCitationActionsAndDocumentLifecycle() throws {
        try withEnvironment { environment, app in
            let url = try makePDF(in: environment.fixtures, name: "Lifecycle-citations.pdf", pages: 8,
                pageTexts: ["[1, 2, 3]", "[1] Alpha. Native citation fixture. 2024.", "[3] Gamma. Native citation fixture. 2025."])
            let document = try XCTUnwrap(PDFDocument(url: url))
            let source = try XCTUnwrap(document.page(at: 0))
            for (offset, pageIndex) in [(1, 1), (7, 2)] {
                let selection = try XCTUnwrap(source.selection(for: NSRange(location: offset, length: 1)))
                let target = try XCTUnwrap(document.page(at: pageIndex))
                let annotation = PDFAnnotation(bounds: selection.bounds(for: source), forType: .link, withProperties: nil)
                annotation.action = PDFActionGoTo(destination: PDFDestination(page: target, at: CGPoint(x: 72, y: 720)))
                source.addAnnotation(annotation)
            }
            XCTAssertTrue(document.write(to: url))
            let other = try makePDF(in: environment.fixtures, name: "Lifecycle-other.pdf", pages: 8)
            app.typeKey("o", modifierFlags: .command)
            try choosePDF(url, in: app)
            app.typeText("gg")
            XCTAssertTrue(waitForStatus("status.page", containing: "1 / 8", in: app))
            app.typeKey("c", modifierFlags: .shift)
            app.typeText("ff")
            let reference = app.textViews["citationPreview.referenceText"]
            XCTAssertTrue(reference.waitForExistence(timeout: 3))
            app.typeText("l")
            XCTAssertTrue(waitForStatus("citationPreviewOverlay", containing: "[2] of 3 (unresolved)", in: app))
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(reference.exists)
            app.typeKey(.return, modifierFlags: .shift)
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertTrue(reference.exists)
            XCTAssertTrue(waitForStatus("status.page", containing: "1 / 8", in: app))
            app.typeKey(.rightArrow, modifierFlags: [])
            XCTAssertTrue(waitForStatus("citationPreviewOverlay", containing: "[3] of 3", in: app))
            app.typeKey(.leftArrow, modifierFlags: [])
            XCTAssertTrue(waitForStatus("citationPreviewOverlay", containing: "[2] of 3 (unresolved)", in: app))
            app.typeText("h")
            XCTAssertTrue(waitForStatus("citationPreviewOverlay", containing: "[1] of 3", in: app))
            app.typeKey("o", modifierFlags: .command)
            try choosePDF(other, in: app)
            XCTAssertFalse(reference.exists)
            XCTAssertTrue(waitForStatus("status.experimentalMode", containing: "CITATION PREVIEW", in: app))
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(tab(named: url.lastPathComponent, in: app).exists)
            app.typeText("ff")
            XCTAssertTrue(reference.waitForExistence(timeout: 3))
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(tab(named: url.lastPathComponent, in: app).exists)
            XCTAssertTrue(reference.exists)
            app.buttons["Close \(url.lastPathComponent)"].click()
            XCTAssertFalse(tab(named: url.lastPathComponent, in: app).exists)
            XCTAssertFalse(reference.exists)
            XCTAssertTrue(waitForStatus("status.experimentalMode", containing: "CITATION PREVIEW", in: app))
            app.terminate()
            app.launch()
            try positionTestWindow(app)
            XCTAssertTrue(waitForStatus("status.experimentalMode", containing: "CITATION PREVIEW", in: app))
            app.typeKey("o", modifierFlags: .command)
            try choosePDF(url, in: app)
            app.typeText("gg")
            app.typeText("ff")
            XCTAssertTrue(reference.waitForExistence(timeout: 3))
            app.typeKey(.return, modifierFlags: .shift)
            let browserActivated = NSPredicate { _, _ in app.state == .runningBackground }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: browserActivated, object: nil)], timeout: 5), .completed)
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = "resolved-citation-scholar-handoff"
            image.lifetime = .keepAlways
            add(image)
            app.activate()
            XCTAssertTrue(waitForStatus("status.page", containing: "1 / 8", in: app))
        }
    }
    @MainActor
    func testE2E19OriginalTableCitationsSurviveDelayAndReopen() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let original = root.appendingPathComponent("test-pdf/citation-annotation-corpus/UAI/2024-adversarial-weak-supervision.pdf")
        let originalHash = try sha256(original)
        let document = try XCTUnwrap(PDFDocument(url: original))
        let source = try XCTUnwrap(document.page(at: 7))
        let destination = try XCTUnwrap((source.annotations[0].action as? PDFActionGoTo)?.destination.page)
        let targetPage = document.index(for: destination) + 1
        try withEnvironment { environment, app in
            let copy = environment.fixtures.appendingPathComponent("Original-Table-1.pdf")
            try FileManager.default.copyItem(at: original, to: copy)
            let reference = app.textViews["citationPreview.referenceText"]
            @MainActor
            func openTable() throws {
                app.typeKey("o", modifierFlags: .command)
                try choosePDF(copy, in: app)
                app.typeText("gg")
                app.typeKey("f", modifierFlags: .shift)
                for _ in 0..<7 { app.typeText("n") }
                XCTAssertTrue(waitForStatus("status.page", containing: "8 / 49", in: app))
            }
            try openTable()
            app.typeKey("c", modifierFlags: .shift)
            XCTAssertTrue(waitForStatus("status.experimentalMode", containing: "CITATION PREVIEW", in: app))
            // Preserve all 40 original annotations: hints have two characters.
            for (label, author) in [("ff", "Xian"), ("fd", "Mazzetto"), ("ff", "Xian")] {
                app.typeText("f" + label)
                XCTAssertTrue(reference.waitForExistence(timeout: 5), author)
                XCTAssertTrue(reference.labelOrValue.contains(author), reference.labelOrValue)
                XCTAssertTrue(waitForStatus("status.page", containing: "8 / 49", in: app))
                app.typeKey(.escape, modifierFlags: [])
                XCTAssertFalse(reference.exists)
                let delay = expectation(description: "Allow delayed PDFKit text processing")
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { delay.fulfill() }
                wait(for: [delay], timeout: 6)
            }
            app.typeText("fff")
            XCTAssertTrue(reference.waitForExistence(timeout: 5))
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitForStatus("status.page", containing: "\(targetPage) / 49", in: app))
            app.typeKey("o", modifierFlags: .control)
            XCTAssertTrue(waitForStatus("status.page", containing: "8 / 49", in: app))
            app.typeKey("w", modifierFlags: .command)
            try openTable()
            app.typeText("fff")
            XCTAssertTrue(reference.waitForExistence(timeout: 5))
            XCTAssertTrue(reference.labelOrValue.contains("Xian"))
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertEqual(try sha256(copy), originalHash)
        }
        XCTAssertEqual(try sha256(original), originalHash)
    }

    @MainActor
    private func withEnvironment(
        config: String? = nil,
        body: (UITestEnvironment, XCUIApplication) throws -> Void
    ) throws {
        let environment = try UITestEnvironment(config: config)
        let originalInputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let app = XCUIApplication()
        app.launchEnvironment["HOME"] = environment.home.path
        app.launchEnvironment["CFFIXED_USER_HOME"] = environment.home.path
        var didCleanUp = false
        let cleanUp: @MainActor () -> Void = {
            guard !didCleanUp else { return }
            didCleanUp = true
            app.terminate()
            XCTAssertEqual(TISSelectInputSource(originalInputSource), noErr)
            environment.remove()
        }
        addTeardownBlock { @MainActor in cleanUp() }
        defer { cleanUp() }
        app.launch()
        try positionTestWindow(app)
        try body(environment, app)
    }

    @MainActor
    private func positionTestWindow(_ app: XCUIApplication) throws {
        let window = app.windows["mainWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        app.activate()
        let frame = window.frame
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let title = origin.withOffset(CGVector(dx: frame.width / 2, dy: 12))
        let destination = origin.withOffset(CGVector(dx: 80 - frame.minX + frame.width / 2, dy: 80 - frame.minY + 12))
        title.press(forDuration: 0.2, thenDragTo: destination)
        app.activate()
        XCTAssertEqual(TISSelectInputSource(TISCopyCurrentASCIICapableKeyboardInputSource().takeRetainedValue()), noErr)
    }

    @MainActor
    private func choosePDF(_ url: URL, in app: XCUIApplication) throws {
        guard app.descendants(matching: .any)["recentFilesOpenOverlay"].waitForExistence(timeout: 3) else { throw UITestFixtureError.missingControl("Recent-file chooser") }
        app.activate()
        app.typeKey(.return, modifierFlags: [])
        guard app.sheets.firstMatch.waitForExistence(timeout: 3) else { throw UITestFixtureError.missingControl("Open panel") }
        XCTAssertEqual(TISSelectInputSource(TISCopyCurrentASCIICapableKeyboardInputSource().takeRetainedValue()), noErr)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let pathField = app.sheets["GoToWindow"].textFields["PathTextField"]
        guard pathField.waitForExistence(timeout: 3) else { throw UITestFixtureError.missingControl("Go-to-path field") }
        XCTAssertEqual(TISSelectInputSource(TISCopyCurrentASCIICapableKeyboardInputSource().takeRetainedValue()), noErr)
        app.typeKey("a", modifierFlags: .command)
        pathField.typeText(url.path)
        app.typeKey(.return, modifierFlags: [])
        let open = app.sheets.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 2), "Open button did not appear")
        open.click()
        XCTAssertTrue(tab(named: url.lastPathComponent, in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    private func tab(named title: String, in app: XCUIApplication) -> XCUIElement {
        app.radioButtons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    @MainActor
    private func status(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @MainActor
    private func waitForStatus(
        _ identifier: String,
        containing text: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 3
    ) -> Bool {
        let element = status(identifier, in: app)
        let predicate = NSPredicate { value, _ in
            (value as? XCUIElement)?.labelOrValue.contains(text) == true
        }
        return XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
            timeout: timeout
        ) == .completed
    }

    @MainActor
    private func hasKeyboardFocus(_ element: XCUIElement) throws -> Bool {
        let snapshot = try element.snapshot()
        return (snapshot.dictionaryRepresentation[.hasFocus] as? NSNumber)?.boolValue == true
    }

    private func makePDF(
        in directory: URL,
        name: String,
        pages: Int,
        text: String = "Modeleaf fixture",
        pageTexts: [String] = []
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw UITestFixtureError.cannotCreatePDF
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18),
            .foregroundColor: NSColor.black,
        ]
        for page in 1...pages {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 72, y: 700)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: "\(pageTexts.indices.contains(page - 1) ? pageTexts[page - 1] : text) · page \(page)", attributes: attributes)
            )
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func makeTOCPDF(in directory: URL, name: String) throws -> URL {
        let url = try makePDF(in: directory, name: name, pages: 12)
        guard let document = PDFDocument(url: url) else { throw UITestFixtureError.cannotCreatePDF }
        let root = PDFOutline()
        for index in 0..<12 {
            guard let page = document.page(at: index) else { throw UITestFixtureError.cannotCreatePDF }
            let row = PDFOutline()
            row.label = "Section \(index + 1)"
            row.destination = PDFDestination(page: page, at: CGPoint(x: 72, y: 700))
            root.insertChild(row, at: index)
        }
        document.outlineRoot = root
        guard document.write(to: url), PDFDocument(url: url)?.outlineRoot?.numberOfChildren == 12 else {
            throw UITestFixtureError.cannotCreatePDF
        }
        return url
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct UITestEnvironment {
    let home: URL
    let fixtures: URL

    init(config: String?) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("modeleaf-ui-\(UUID().uuidString)", isDirectory: true)
        fixtures = home.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        if let config {
            let directory = home.appendingPathComponent(".config/modeleaf", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(config.utf8).write(to: directory.appendingPathComponent("config.toml"))
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }
}

private enum UITestFixtureError: Error {
    case cannotCreatePDF
    case missingControl(String)
}

private extension XCUIElement {
    var labelOrValue: String {
        if let value = value as? String, !value.isEmpty { return value }
        return label
    }
}
