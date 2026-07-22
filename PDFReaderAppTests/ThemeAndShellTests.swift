import AppKit
import PDFKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("Polished native shell and AppKit themes")
@MainActor
struct ThemeAndShellTests {
    @Test("U-THEME-01 every built-in theme resolves complete AppKit chrome colors")
    func everyThemeResolvesAppKitColors() {
        for themeID in ThemeID.allCases {
            let theme = AppKitTheme(configuration: ThemeConfiguration(builtIn: themeID))
            #expect(theme.id == themeID)
            #expect(!theme.displayName.isEmpty)
            for token in ThemeToken.allCases {
                #expect(theme[token].usingColorSpace(.sRGB) != nil)
            }
            #expect(theme.focusRing.alphaComponent > 0)
            #expect(theme.hover.alphaComponent > 0)
            #expect(theme.searchHighlightPalette.activeResult.alphaComponent > 0)
        }
        #expect(ThemeAttributions.bundledPaletteNames.count == 4)
    }

    @Test("active search and focus colors are independently configurable semantic tokens")
    func independentSearchAndFocusTokens() throws {
        let activeSearch = try #require(ThemeColor(rawValue: "#01020380"))
        let focus = try #require(ThemeColor(rawValue: "#A0B0C0"))
        let theme = AppKitTheme(
            configuration: ThemeConfiguration(
                builtIn: .nord,
                overrides: [
                    .activeSearchHighlight: activeSearch,
                    .focusIndicator: focus,
                ]
            )
        )

        #expect(theme[.accent].hexRGB != "#010203")
        #expect(theme.searchHighlightPalette.activeResult.hexRGB == "#010203")
        #expect(theme.focusRing.hexRGB == "#A0B0C0")
    }

    @Test("U-THEME-02 one semantic override changes only that AppKit token")
    func sparseOverrideChangesOneToken() throws {
        let base = AppKitTheme(configuration: ThemeConfiguration(builtIn: .nord))
        let override = try #require(ThemeColor(rawValue: "#010203"))
        let changed = AppKitTheme(
            configuration: ThemeConfiguration(builtIn: .nord, overrides: [.accent: override])
        )

        #expect(changed[.accent].hexRGB == "#010203")
        for token in ThemeToken.allCases where token != .accent {
            #expect(changed[token].hexRGB == base[token].hexRGB)
        }
    }

    @Test("U-THEME-03 applying a theme styles shell chrome but never mutates presented content colors")
    func themeDoesNotRecolorPresentedContent() {
        let root = ReaderRootView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.systemRed.cgColor
        let original = content.layer?.backgroundColor
        let id = TabID()
        let snapshot = ReaderSessionStoreSnapshot(
            tabs: [ReaderTabSnapshot(id: id, title: "Content.pdf")],
            activeID: id
        )

        root.render(snapshot: snapshot, activeContentView: content, sessionStatus: .empty)
        for themeID in ThemeID.allCases {
            root.apply(theme: AppKitTheme(configuration: ThemeConfiguration(builtIn: themeID)))
            #expect(content.layer?.backgroundColor == original)
        }
    }

    @Test("background token reaches the real PDF surrounding canvas without recoloring page content")
    func backgroundTokenStylesRealReaderCanvas() throws {
        let override = try #require(ThemeColor(rawValue: "#123456"))
        let focus = try #require(ThemeColor(rawValue: "#FEDCBA"))
        let theme = AppKitTheme(
            configuration: ThemeConfiguration(
                builtIn: .nord,
                overrides: [
                    .background: override,
                    .focusIndicator: focus,
                ]
            )
        )
        let store = ReaderSessionStore()
        let controller = MainWindowController(
            sessionStore: store,
            theme: theme,
            actionHandler: { _ in }
        )
        let session = ReaderSession(
            sourceURL: URL(fileURLWithPath: "/tmp/Theme.pdf"),
            document: PDFDocument()
        )
        session.applyTheme(theme)
        #expect(store.insert(session))
        defer {
            _ = store.close(session.id)
            controller.close()
        }

        let readerView = try #require(session.focusView as? ReaderPDFView)
        #expect(readerView.backgroundColor.hexRGB == "#123456")
        let layerColor = try #require(session.contentView.layer?.backgroundColor)
        #expect(NSColor(cgColor: layerColor)?.hexRGB == "#123456")
        #expect(theme.canvasBackground.hexRGB == "#123456")
        #expect(controller.window?.firstResponder === readerView)
        #expect(readerView.layer?.borderWidth == WindowVisualMetrics.focusIndicatorWidth)
        #expect(NSColor(cgColor: try #require(readerView.layer?.borderColor))?.hexRGB == "#FEDCBA")

        controller.presentPrompt(
            PromptPresentation(kind: .search, text: "focus", validationMessage: nil)
        )
        #expect(controller.window?.firstResponder === controller.rootView.promptOverlay.textField.currentEditor())
        #expect(controller.rootView.promptOverlay.layer?.borderWidth == WindowVisualMetrics.focusIndicatorWidth)
        #expect(
            NSColor(cgColor: try #require(controller.rootView.promptOverlay.layer?.borderColor))?.hexRGB
                == "#FEDCBA"
        )

        controller.dismissPromptAndRestoreFocus()
        #expect(controller.window?.firstResponder === readerView)
    }

    @Test("unbound Tab and Backtab move the real PDF canvas through the AppKit key-view loop")
    func readerCanvasStartsKeyViewTraversal() throws {
        let store = ReaderSessionStore()
        let controller = MainWindowController(
            sessionStore: store,
            theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
            actionHandler: { _ in }
        )
        let session = ReaderSession(
            sourceURL: URL(fileURLWithPath: "/tmp/Keyboard Navigation.pdf"),
            document: PDFDocument()
        )
        #expect(store.insert(session))
        defer {
            _ = store.close(session.id)
            controller.close()
        }

        let window = try #require(controller.window)
        let readerView = try #require(session.focusView as? ReaderPDFView)
        #expect(window.makeFirstResponder(readerView))
        let forwardTarget = try #require(readerView.nextKeyView)
        #expect(forwardTarget.accessibilityIdentifier().hasPrefix("tab."))

        let tab = try #require(makeKeyEvent(
            characters: "\t",
            keyCode: 48,
            windowNumber: window.windowNumber
        ))
        readerView.keyDown(with: tab)
        #expect(window.firstResponder === forwardTarget)
        #expect(readerView.layer?.borderWidth == 0)

        var returnedToReader = false
        for _ in 0..<64 {
            window.selectNextKeyView(nil)
            if window.firstResponder === readerView {
                returnedToReader = true
                break
            }
        }
        #expect(returnedToReader)

        #expect(window.makeFirstResponder(readerView))
        let backwardTarget = try #require(readerView.previousKeyView)
        #expect(backwardTarget.accessibilityIdentifier().hasPrefix("tab.close."))
        let backtab = try #require(makeKeyEvent(
            characters: "\t",
            modifiers: [.shift],
            keyCode: 48,
            windowNumber: window.windowNumber
        ))
        readerView.keyDown(with: backtab)
        #expect(window.firstResponder === backwardTarget)
        #expect(readerView.layer?.borderWidth == 0)
    }

    @Test("empty, single-tab, multi-tab, prompt, search, and error states keep stable accessible surfaces")
    func shellStatesExposeStableAccessibilityIdentifiers() {
        let store = ReaderSessionStore()
        var actions: [ActionID] = []
        let controller = MainWindowController(
            sessionStore: store,
            theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
            actionHandler: { actions.append($0) }
        )

        #expect(controller.rootView.emptyState.isHidden == false)
        #expect(controller.rootView.tabBar.isHidden)
        #expect(controller.window?.accessibilityIdentifier() == "mainWindow")
        #expect(controller.rootView.emptyState.accessibilityIdentifier() == "emptyState")
        #expect(controller.rootView.emptyState.accessibilityRole() == .group)
        #expect(controller.rootView.emptyState.openButton.accessibilityRole() == .button)
        #expect(controller.rootView.emptyState.openButton.accessibilityLabel() == "Open PDF")
        #expect(controller.rootView.emptyState.openButton.keyEquivalent.isEmpty)
        #expect(controller.rootView.statusBar.accessibilityIdentifier() == "statusBar")
        #expect(controller.rootView.statusBar.accessibilityRole() == .group)

        controller.rootView.emptyState.openButton.performClick(nil)
        #expect(actions == [.documentOpen])

        let first = StubReaderSession(id: TabID(), title: "One.pdf")
        let second = StubReaderSession(id: TabID(), title: "Two.pdf")
        #expect(store.insert(first))
        #expect(controller.rootView.emptyState.isHidden)
        #expect(!controller.rootView.tabBar.isHidden)
        #expect(store.insert(second))
        #expect(store.snapshot.tabs.count == 2)
        #expect(controller.rootView.tabBar.accessibilityRole() == .group)
        let activeTabID = "tab.\(second.id.rawValue.uuidString.lowercased())"
        let activeTab = findDescendant(in: controller.rootView.tabBar, identifier: activeTabID)
        #expect(activeTab?.accessibilityRole() == .radioButton)
        #expect(activeTab?.accessibilityValue() as? String == "selected")
        #expect(activeTab?.accessibilityLabel()?.contains("tab 2 of 2") == true)
        second.page = 2
        second.publishPresentationChange()
        #expect(findDescendant(in: controller.rootView.tabBar, identifier: activeTabID) === activeTab)
        #expect(controller.rootView.statusBar.presentation.page == "2 / 10")
        let closeID = "tab.close.\(second.id.rawValue.uuidString.lowercased())"
        #expect(findDescendant(in: controller.rootView.tabBar, identifier: closeID)?.accessibilityRole() == .button)

        controller.presentPrompt(PromptPresentation(kind: .page, text: "12", validationMessage: nil))
        #expect(!controller.rootView.promptOverlay.isHidden)
        #expect(controller.rootView.promptOverlay.accessibilityRole() == .group)
        #expect(controller.rootView.promptOverlay.textField.accessibilityIdentifier() == "prompt.textField")
        #expect(controller.rootView.promptOverlay.textField.accessibilityLabel() == "Page number")
        #expect(controller.rootView.promptOverlay.commitButton.accessibilityRole() == .button)
        #expect(controller.rootView.promptOverlay.cancelButton.accessibilityRole() == .button)
        controller.dismissPromptAndRestoreFocus()
        #expect(controller.rootView.promptOverlay.isHidden)

        controller.presentPrompt(PromptPresentation(kind: .search, text: "native", validationMessage: nil))
        #expect(controller.rootView.promptOverlay.textField.accessibilityLabel() == "Search query")
        #expect(controller.rootView.promptOverlay.accessibilityValue() as? String == "Search prompt")
        controller.showPromptValidation("Enter text to search.")
        let validation = findDescendant(in: controller.rootView.promptOverlay, identifier: "prompt.validation")
        #expect(validation?.accessibilityValue() as? String == "Enter text to search.")
        controller.dismissPromptAndRestoreFocus(to: .searchResults, reason: .promptCommitted)
        #expect(controller.rootView.statusBar.presentation.context == "SEARCH")

        controller.showDiagnostic("Malformed configuration")
        #expect(controller.rootView.statusBar.presentation.tone == .error)
        #expect(controller.rootView.statusBar.presentation.detail == "Malformed configuration")
        #expect(
            (controller.rootView.statusBar.accessibilityValue() as? String)?
                .contains("Malformed configuration") == true
        )
        let diagnostic = findDescendant(in: controller.rootView.statusBar, identifier: "status.diagnostic")
        #expect(diagnostic?.accessibilityValue() as? String == "Malformed configuration")

        #expect(store.close(first.id))
        #expect(store.close(second.id))
        #expect(controller.rootView.emptyState.isHidden == false)
        #expect(controller.window != nil)
    }

    @Test("tab pointer controls compose only stable tab and document actions")
    func tabPointerControlsUseDispatcherActions() throws {
        let store = ReaderSessionStore()
        let first = StubReaderSession(id: TabID(), title: "One.pdf")
        let second = StubReaderSession(id: TabID(), title: "Two.pdf")
        let third = StubReaderSession(id: TabID(), title: "Three.pdf")
        let dispatcher = ActionDispatcher(
            sessionStore: store,
            navigation: BuiltInDefaults.config.navigation
        )
        var actions: [ActionID] = []
        let controller = MainWindowController(
            sessionStore: store,
            theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
            actionHandler: {
                actions.append($0)
                dispatcher.dispatch($0)
            }
        )
        dispatcher.presentation = controller
        #expect(store.insert(first))
        #expect(store.insert(second))
        #expect(store.insert(third))

        let firstTabID = "tab.\(first.id.rawValue.uuidString.lowercased())"
        let firstTab = try #require(
            findDescendant(in: controller.rootView.tabBar, identifier: firstTabID) as? NSButton
        )
        firstTab.performClick(nil)
        #expect(actions == [.tabNext])
        #expect(store.activeSession?.id == first.id)

        let closeSecondID = "tab.close.\(second.id.rawValue.uuidString.lowercased())"
        let closeSecond = try #require(
            findDescendant(in: controller.rootView.tabBar, identifier: closeSecondID) as? NSButton
        )
        closeSecond.performClick(nil)
        #expect(actions == [.tabNext, .tabNext, .documentClose, .tabNext])
        #expect(store.session(for: second.id) == nil)
        #expect(store.activeSession?.id == first.id)

        let activeFirst = try #require(
            findDescendant(in: controller.rootView.tabBar, identifier: firstTabID) as? NSButton
        )
        activeFirst.performClick(nil)
        #expect(actions == [.tabNext, .tabNext, .documentClose, .tabNext])
    }

    @Test("V-THEME-01 four themes render the six required visual acceptance states")
    func visualAcceptanceMatrix() throws {
        let output = try snapshotOutputDirectory()
        var allPNGs: [Data] = []

        for themeID in ThemeID.allCases {
            let theme = AppKitTheme(configuration: ThemeConfiguration(builtIn: themeID))
            var themePNGs: [(state: VisualAcceptanceState, data: Data)] = []

            for state in VisualAcceptanceState.allCases {
                let rendered = makeVisualState(state, theme: theme)
                let png = try renderPNG(rendered.root)
                #expect(png.count > 10_000)
                if state == .empty {
                    #expect(rendered.paperColor == nil)
                    #expect(rendered.canvasColor == nil)
                } else {
                    #expect(rendered.paperColor == "#F7F7F5")
                    #expect(rendered.canvasColor == theme.canvasBackground.hexRGB)
                }
                themePNGs.append((state, png))
                allPNGs.append(png)

                if let output {
                    try png.write(
                        to: output.appendingPathComponent("\(themeID.rawValue)-\(state.rawValue).png")
                    )
                }
            }

            #expect(Set(themePNGs.map(\.data)).count == VisualAcceptanceState.allCases.count)
            if let output {
                let contactSheet = try renderContactSheet(theme: theme, images: themePNGs)
                #expect(contactSheet.count > 50_000)
                try contactSheet.write(
                    to: output.appendingPathComponent("\(themeID.rawValue)-contact-sheet.png")
                )
            }
        }

        #expect(allPNGs.count == ThemeID.allCases.count * VisualAcceptanceState.allCases.count)
        #expect(Set(allPNGs).count == allPNGs.count)
    }

    private func makeRoot(theme: AppKitTheme) -> ReaderRootView {
        let root = ReaderRootView(
            frame: NSRect(origin: .zero, size: WindowVisualMetrics.initialSize)
        )
        root.apply(theme: theme)
        return root
    }

    private func renderPNG(_ view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        let representation = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        return try #require(representation.representation(using: .png, properties: [:]))
    }

    private func makeVisualState(
        _ state: VisualAcceptanceState,
        theme: AppKitTheme
    ) -> (root: ReaderRootView, paperColor: String?, canvasColor: String?) {
        let root = makeRoot(theme: theme)
        let firstID = TabID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let secondID = TabID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        let thirdID = TabID(rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!)
        let canvas = PreviewCanvasView(
            canvasBackground: theme.canvasBackground,
            searchPalette: state == .search ? theme.searchHighlightPalette : nil
        )

        switch state {
        case .empty:
            root.render(
                snapshot: ReaderSessionStoreSnapshot(tabs: [], activeID: nil),
                activeContentView: nil,
                sessionStatus: nil
            )
        case .singleTab:
            root.render(
                snapshot: ReaderSessionStoreSnapshot(
                    tabs: [ReaderTabSnapshot(id: firstID, title: "Reading.pdf")],
                    activeID: firstID
                ),
                activeContentView: canvas,
                sessionStatus: ReaderStatusSnapshot(
                    context: "NORMAL",
                    page: "7 / 84",
                    zoom: "100%",
                    detail: "Reading.pdf"
                )
            )
        case .multiTab:
            root.render(
                snapshot: ReaderSessionStoreSnapshot(
                    tabs: [
                        ReaderTabSnapshot(id: firstID, title: "Reference.pdf"),
                        ReaderTabSnapshot(id: secondID, title: "Design Notes.pdf"),
                        ReaderTabSnapshot(id: thirdID, title: "API Guide.pdf"),
                    ],
                    activeID: secondID
                ),
                activeContentView: canvas,
                sessionStatus: ReaderStatusSnapshot(
                    context: "NORMAL",
                    page: "12 / 240",
                    zoom: "112%",
                    detail: "Design Notes.pdf"
                )
            )
        case .prompt:
            root.render(
                snapshot: ReaderSessionStoreSnapshot(
                    tabs: [
                        ReaderTabSnapshot(id: firstID, title: "Reference.pdf"),
                        ReaderTabSnapshot(id: secondID, title: "Design Notes.pdf"),
                    ],
                    activeID: secondID
                ),
                activeContentView: canvas,
                sessionStatus: ReaderStatusSnapshot(
                    context: "PAGE",
                    page: "12 / 240",
                    zoom: "112%",
                    detail: "Design Notes.pdf"
                )
            )
            root.setInputContext(.pagePrompt)
            root.setPendingPrefix("g")
            root.promptOverlay.present(
                PromptPresentation(kind: .page, text: "48", validationMessage: nil)
            )
        case .search:
            root.render(
                snapshot: ReaderSessionStoreSnapshot(
                    tabs: [
                        ReaderTabSnapshot(id: firstID, title: "Reference.pdf"),
                        ReaderTabSnapshot(id: secondID, title: "Design Notes.pdf"),
                    ],
                    activeID: firstID
                ),
                activeContentView: canvas,
                sessionStatus: ReaderStatusSnapshot(
                    context: "SEARCH",
                    page: "19 / 240",
                    zoom: "112%",
                    detail: "3 / 8 · “navigation”"
                )
            )
            root.setInputContext(.searchResults)
        case .error:
            root.render(
                snapshot: ReaderSessionStoreSnapshot(
                    tabs: [ReaderTabSnapshot(id: firstID, title: "Reading.pdf")],
                    activeID: firstID
                ),
                activeContentView: canvas,
                sessionStatus: ReaderStatusSnapshot(
                    context: "NORMAL",
                    page: "7 / 84",
                    zoom: "100%",
                    detail: "Reading.pdf"
                )
            )
            root.showDiagnostic("config.toml:18 — keymap.page.next: duplicate binding ‘n’")
        }

        return (
            root,
            state == .empty ? nil : canvas.paperColor.hexRGB,
            state == .empty ? nil : canvas.canvasColor.hexRGB
        )
    }

    private func snapshotOutputDirectory() throws -> URL? {
        guard let directory = ProcessInfo.processInfo.environment["PDF_READER_SNAPSHOT_DIR"] else {
            return nil
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        return output
    }

    private func renderContactSheet(
        theme: AppKitTheme,
        images: [(state: VisualAcceptanceState, data: Data)]
    ) throws -> Data {
        let columns = 3
        let rows = 2
        let imageSize = NSSize(width: 520, height: 380)
        let labelHeight: CGFloat = 30
        let sheetSize = NSSize(
            width: imageSize.width * CGFloat(columns),
            height: (imageSize.height + labelHeight) * CGFloat(rows)
        )
        let sheet = NSImage(size: sheetSize, flipped: false) { bounds in
            theme[.background].setFill()
            NSBezierPath(rect: bounds).fill()

            for (index, item) in images.enumerated() {
                guard let image = NSImage(data: item.data) else { return false }
                let column = index % columns
                let rowFromTop = index / columns
                let row = rows - rowFromTop - 1
                let origin = NSPoint(
                    x: CGFloat(column) * imageSize.width,
                    y: CGFloat(row) * (imageSize.height + labelHeight)
                )
                image.draw(
                    in: NSRect(origin: origin, size: imageSize),
                    from: .zero,
                    operation: .copy,
                    fraction: 1
                )
                let label = "\(theme.displayName) · \(item.state.title)" as NSString
                label.draw(
                    in: NSRect(
                        x: origin.x + 12,
                        y: origin.y + imageSize.height + 7,
                        width: imageSize.width - 24,
                        height: labelHeight - 7
                    ),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                        .foregroundColor: theme[.foreground],
                    ]
                )
            }
            return true
        }
        let representation = try #require(sheet.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        return try #require(representation.representation(using: .png, properties: [:]))
    }

    private func findDescendant(in view: NSView, identifier: String) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        for subview in view.subviews {
            if let match = findDescendant(in: subview, identifier: identifier) {
                return match
            }
        }
        return nil
    }
}

private enum VisualAcceptanceState: String, CaseIterable {
    case empty
    case singleTab = "single-tab"
    case multiTab = "multi-tab"
    case prompt
    case search
    case error

    var title: String {
        switch self {
        case .empty: "Empty"
        case .singleTab: "Single tab"
        case .multiTab: "Multiple tabs"
        case .prompt: "Page prompt"
        case .search: "Search results"
        case .error: "Error diagnostic"
        }
    }
}

@MainActor
private final class PreviewCanvasView: NSView {
    private let page = NSView()
    let paperColor = NSColor(srgbRed: 0.969, green: 0.969, blue: 0.961, alpha: 1)
    let canvasColor: NSColor

    init(canvasBackground: NSColor, searchPalette: SearchHighlightPalette? = nil) {
        self.canvasColor = canvasBackground
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = canvasBackground.cgColor

        page.wantsLayer = true
        page.layer?.backgroundColor = paperColor.cgColor
        page.layer?.cornerRadius = 2
        page.layer?.shadowColor = NSColor.black.cgColor
        page.layer?.shadowOpacity = 0.32
        page.layer?.shadowRadius = 10
        page.layer?.shadowOffset = NSSize(width: 0, height: -3)
        page.prepareForAutoLayout()
        addSubview(page)

        let eyebrow = makeDocumentLabel(
            "PDF READER · PRODUCT BRIEF",
            size: 9,
            weight: .semibold,
            color: NSColor(calibratedWhite: 0.36, alpha: 1)
        )
        let title = makeDocumentLabel(
            "Navigation-first reading",
            size: 22,
            weight: .semibold,
            color: NSColor(calibratedWhite: 0.10, alpha: 1)
        )
        let subtitle = makeDocumentLabel(
            "A focused macOS PDF viewer with configurable Vim keys.",
            size: 12,
            weight: .regular,
            color: NSColor(calibratedWhite: 0.30, alpha: 1)
        )
        let body = [
            "Move with h j k l and larger d / u steps.",
            "Jump directly with g plus a page number.",
            "Keep independent documents open in native tabs.",
            "Search embedded text without changing the source PDF.",
            "Configure every reader action in one TOML file.",
        ].enumerated().map { index, text in
            let label = makeDocumentLabel(
                text,
                size: 11,
                weight: index == 1 ? .medium : .regular,
                color: NSColor(calibratedWhite: 0.18, alpha: 1)
            )
            if let searchPalette, index == 0 || index == 1 || index == 3 {
                label.drawsBackground = true
                label.backgroundColor = index == 1 ? searchPalette.activeResult : searchPalette.allResults
            }
            return label
        }
        let bodyStack = NSStackView(views: body)
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 12

        let stack = NSStackView(views: [eyebrow, title, subtitle, bodyStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.setCustomSpacing(22, after: subtitle)
        stack.prepareForAutoLayout()
        page.addSubview(stack)

        NSLayoutConstraint.activate([
            page.centerXAnchor.constraint(equalTo: centerXAnchor),
            page.centerYAnchor.constraint(equalTo: centerYAnchor),
            page.widthAnchor.constraint(equalToConstant: 430),
            page.heightAnchor.constraint(equalToConstant: 608),
            stack.topAnchor.constraint(equalTo: page.topAnchor, constant: 64),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 52),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: page.trailingAnchor, constant: -52),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func makeDocumentLabel(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.maximumNumberOfLines = 1
        return label
    }
}

private extension NSColor {
    var hexRGB: String? {
        guard let color = usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }
}
