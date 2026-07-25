import AppKit
import CoreGraphics
import CoreText
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

            XCTAssertTrue(app.descendants(matching: .any)["pdfCanvas"].waitForExistence(timeout: 5))
            XCTAssertTrue(tab(named: "Remapped.pdf", in: app).exists)
            XCTAssertTrue(status("status.page", in: app).labelOrValue.contains("1 / 20"))
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
            app.typeText("gT")
            XCTAssertEqual(tab(named: "First.pdf", in: app).value as? String, "selected")
            app.typeText("gt")
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
    private func withEnvironment(
        config: String? = nil,
        body: (UITestEnvironment, XCUIApplication) throws -> Void
    ) throws {
        let environment = try UITestEnvironment(config: config)
        defer { environment.remove() }
        let app = XCUIApplication()
        app.launchEnvironment["HOME"] = environment.home.path
        app.launchEnvironment["CFFIXED_USER_HOME"] = environment.home.path
        app.launch()
        defer { app.terminate() }
        try body(environment, app)
    }

    @MainActor
    private func choosePDF(_ url: URL, in app: XCUIApplication) throws {
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 3), "Open panel did not appear")
        app.typeKey("g", modifierFlags: [.command, .shift])
        let pathField = app.textFields.element(boundBy: max(0, app.textFields.count - 1))
        XCTAssertTrue(pathField.waitForExistence(timeout: 2), "Go-to-path field did not appear")
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
        text: String = "Modeleaf fixture"
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
                NSAttributedString(string: "\(text) · page \(page)", attributes: attributes)
            )
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
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
}

private extension XCUIElement {
    var labelOrValue: String {
        if let value = value as? String, !value.isEmpty { return value }
        return label
    }
}
