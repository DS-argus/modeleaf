import AppKit
import PDFKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("Theme red-team QA", .serialized)
@MainActor
struct ThemeRedTeamQATests {
    @Test("STATE-FILE TORTURE: classifications, fallback, and config isolation")
    func stateFileTorture() throws {
        try withTemporaryDirectory { directory in
            let configURL = directory.appendingPathComponent("config.toml")
            let stateURL = directory.appendingPathComponent("state.json")
            let store = ThemeSelectionStore(fileURL: stateURL)

            for id in ThemeID.allCases {
                #expect(store.persist(id) == .persisted)
                #expect(store.load() == .selected(id))
                #expect(store.resolvedTheme() == id)
            }
            #expect(!FileManager.default.fileExists(atPath: configURL.path))

            let invalidCases: [Data] = [
                Data(),
                Data("{\"selected_theme\":\"nord\"".utf8),
                Data("{\"selected_theme\":123}".utf8),
                Data("{\"selected_theme\":\"not-a-preset\"}".utf8),
            ]
            for data in invalidCases {
                try data.write(to: stateURL)
                #expect(store.load() == .invalid)
                #expect(store.resolvedTheme() == .tokyoNight)
                let controller = makeController(directory: directory, stateURL: stateURL)
                #expect(ThemeID.allCases.contains(controller.currentThemeID))
                controller.mainWindowController.close()
            }

            try Data("{\"selected_theme\":\"dracula\",\"ignored\":true}".utf8).write(to: stateURL)
            #expect(store.load() == .selected(.dracula))
            try FileManager.default.removeItem(at: stateURL)
            #expect(store.load() == .absent)
            try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
            if case .ioError = store.load() {} else { Issue.record("Directory state path must classify as ioError") }
            #expect(store.resolvedTheme() == .tokyoNight)
            try FileManager.default.removeItem(at: stateURL)

            let readOnlyParent = directory.appendingPathComponent("readonly", isDirectory: true)
            try FileManager.default.createDirectory(at: readOnlyParent, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyParent.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyParent.path) }
            let blockedStore = ThemeSelectionStore(fileURL: readOnlyParent.appendingPathComponent("state.json"))
            if case .failed = blockedStore.persist(.dracula) {} else { Issue.record("Read-only state parent allowed persistence") }
            #expect(!FileManager.default.fileExists(atPath: configURL.path))
        }
    }

    @Test("PICKER STATE MACHINE: clamps, rollback, commit, reopen, and double-open")
    func pickerStateMachine() throws {
        let keys = try pickerKeys()
        try withTemporaryDirectory { directory in
            let stateURL = directory.appendingPathComponent("state.json")
            let controller = makeController(directory: directory, stateURL: stateURL)
            defer { controller.mainWindowController.close() }
            let window = controller.mainWindowController
            let overlay = window.rootView.themePickerOverlay

            window.presentThemePicker()
            window.presentThemePicker()
            #expect(!overlay.isHidden)
            #expect(controller.currentThemeID == .tokyoNight)
            #expect(overlay.handleKeyDown(keys.escape))
            #expect(controller.currentThemeID == .tokyoNight)

            window.presentThemePicker()
            for _ in 0..<20 { #expect(overlay.handleKeyDown(keys.up)) }
            #expect(controller.currentThemeID == .tokyoNight)
            for _ in 0..<20 { #expect(overlay.handleKeyDown(keys.down)) }
            #expect(controller.currentThemeID == .catppuccinLatte)
            #expect(overlay.handleKeyDown(keys.escape))
            #expect(controller.currentThemeID == .tokyoNight)

            window.presentThemePicker()
            #expect(overlay.handleKeyDown(keys.j))
            #expect(controller.currentThemeID == .gruvboxDark)
            #expect(overlay.handleKeyDown(keys.returnKey))
            #expect(storeTheme(at: stateURL) == .gruvboxDark)
            window.presentThemePicker()
            #expect(controller.currentThemeID == .gruvboxDark)
            #expect(overlay.handleKeyDown(keys.escape))
        }
    }

    @Test("PROPAGATION: picker commit reaches every live pane in single, split, and 2x2 layouts")
    func pickerPropagation() throws {
        let keys = try pickerKeys()
        for expectedPaneCount in [1, 2, 4] {
            try withTemporaryDirectory { directory in
                let controller = makeController(directory: directory, stateURL: directory.appendingPathComponent("state.json"))
                defer { controller.mainWindowController.close() }
                var sessions = [QARecordingSession(title: "one.pdf")]
                controller.coordinator.configureDuplication { _ in
                    let session = QARecordingSession(title: "copy-\(sessions.count).pdf")
                    sessions.append(session)
                    return session
                }
                #expect(controller.coordinator.insert(sessions[0], into: .createIfEmpty))
                if expectedPaneCount >= 2 { #expect(controller.coordinator.split(direction: .sideBySide) != nil) }
                if expectedPaneCount == 4 {
                    #expect(controller.coordinator.split(direction: .stacked) != nil)
                    let untouchedPane = try #require(controller.coordinator.snapshot.layout.paneIDs.first)
                    #expect(controller.coordinator.activatePane(untouchedPane))
                    #expect(controller.coordinator.split(direction: .stacked) != nil)
                }
                #expect(controller.coordinator.snapshot.layout.paneIDs.count == expectedPaneCount)
                sessions.forEach { $0.applied.removeAll() }
                controller.mainWindowController.presentThemePicker()
                #expect(controller.mainWindowController.rootView.themePickerOverlay.handleKeyDown(keys.down))
                #expect(controller.mainWindowController.rootView.themePickerOverlay.handleKeyDown(keys.returnKey))
                #expect(controller.currentThemeID == .gruvboxDark)
                #expect(sessions.count == expectedPaneCount)
                #expect(sessions.allSatisfy { $0.applied == [.gruvboxDark, .gruvboxDark] })
                #expect(controller.mainWindowController.window?.backgroundColor?.isEqual(AppKitTheme(themeID: .gruvboxDark)[.background]) == true)
            }
        }
    }

    @Test("CONFIG COMPAT: deprecated theme does not mask valid keymap or genuine errors")
    func configCompatibility() throws {
        try withTemporaryDirectory { directory in
            let config = directory.appendingPathComponent("config.toml")
            try Data("""
            [theme]
            built_in = "nord"
            [theme.overrides]
            accent = "#FFFFFF"
            [keymap]
            "theme.picker" = ["<C-t>"]
            """.utf8).write(to: config)
            let accepted = ConfigService(source: ConfigFileSource(url: config)).load()
            #expect(accepted.origin == .userFile)
            #expect(!accepted.usedFallback)
            #expect(accepted.diagnostics.contains { $0.code == .deprecatedTheme && $0.severity == .warning })
            #expect(accepted.activeConfig.keymap.bindings(for: .themePicker).map(\.description) == ["<C-t>"])

            try Data("""
            [theme]
            built_in = "nord"
            [keymap]
            "not.real" = ["x"]
            """.utf8).write(to: config)
            let rejected = ConfigService(source: ConfigFileSource(url: config)).load()
            #expect(rejected.usedFallback)
            #expect(rejected.diagnostics.contains { $0.code == .deprecatedTheme && $0.severity == .warning })
            #expect(rejected.diagnostics.contains { $0.code == .unknownAction && $0.severity == .error })
        }
    }

    @Test("PIXEL INVARIANCE: real PDF fixture page raster is unchanged by every theme")
    func pixelInvariance() throws {
        try withTemporaryDirectory { directory in
            let fixture = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 1)
            let document = try #require(PDFDocument(url: fixture))
            let page = try #require(document.page(at: 0))
            let baseline = try raster(page)
            for id in ThemeID.allCases {
                let session = ReaderSession(sourceURL: fixture, document: document)
                session.applyTheme(AppKitTheme(themeID: id))
                #expect(try raster(page) == baseline)
            }
        }
    }

    @Test("PROMPT-SAFETY: Shift-T is blocked in prompts and rebound Control-T opens in navigation")
    func promptSafetyAndRebinding() throws {
        try withTemporaryDirectory { directory in
            let config = directory.appendingPathComponent("config.toml")
            try Data("[keymap]\n\"theme.picker\" = [\"<C-t>\"]\n".utf8).write(to: config)
            let controller = ApplicationController(configService: ConfigService(source: ConfigFileSource(url: config)), sessionStore: ReaderSessionStore(), themeStore: ThemeSelectionStore(fileURL: directory.appendingPathComponent("state.json")), terminationHandler: {})
            defer { controller.mainWindowController.close() }
            let window = controller.mainWindowController
            let shiftT = try #require(makeKeyEvent(characters: "T", charactersIgnoringModifiers: "t", modifiers: [.shift], keyCode: 17))
            window.presentPrompt(PromptPresentation(kind: .page, text: "", validationMessage: nil))
            _ = window.routeKeyEventForTesting(shiftT)
            #expect(window.rootView.themePickerOverlay.isHidden)
            window.dismissPromptAndRestoreFocus()
            window.presentPrompt(PromptPresentation(kind: .search, text: "", validationMessage: nil))
            _ = window.routeKeyEventForTesting(shiftT)
            #expect(window.rootView.themePickerOverlay.isHidden)
            window.dismissPromptAndRestoreFocus()
            let controlT = try #require(makeKeyEvent(characters: "t", modifiers: [.control], keyCode: 17))
            #expect(window.routeKeyEventForTesting(controlT))
            #expect(!window.rootView.themePickerOverlay.isHidden)
        }
    }

    private func makeController(directory: URL, stateURL: URL) -> ApplicationController {
        ApplicationController(configService: ConfigService(source: ConfigFileSource(url: directory.appendingPathComponent("missing.toml"))), sessionStore: ReaderSessionStore(), themeStore: ThemeSelectionStore(fileURL: stateURL), terminationHandler: {})
    }

    private func storeTheme(at url: URL) -> ThemeID? { ThemeSelectionStore(fileURL: url).loadSelectedTheme() }
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("theme-red-team-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
    private func pickerKeys() throws -> (up: NSEvent, down: NSEvent, j: NSEvent, returnKey: NSEvent, escape: NSEvent) {
        (try #require(makeKeyEvent(characters: "", keyCode: 126)), try #require(makeKeyEvent(characters: "", keyCode: 125)), try #require(makeKeyEvent(characters: "j", keyCode: 38)), try #require(makeKeyEvent(characters: "\r", keyCode: 36)), try #require(makeKeyEvent(characters: "\u{1B}", keyCode: 53)))
    }
    private func raster(_ page: PDFPage) throws -> Data {
        let image = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 300, height: 400).fill()
        page.draw(with: .mediaBox, to: NSGraphicsContext.current!.cgContext)
        return try #require(image.representation(using: .png, properties: [:]))
    }
}

@MainActor
private final class QARecordingSession: ReaderSessionPresenting, ReaderDuplicationSnapshotProviding {
    let id = TabID()
    let title: String
    let contentView = NSView()
    var applied: [ThemeID] = []
    init(title: String) { self.title = title }
    var statusSnapshot: ReaderStatusSnapshot { ReaderStatusSnapshot(context: "NORMAL", page: "1 / 1", zoom: "100%", detail: title) }
    var duplicationSnapshot: ReaderDuplicationSnapshot { ReaderDuplicationSnapshot(sourceURL: URL(fileURLWithPath: "/tmp/\(title)"), oneBasedPage: 1) }
    func applyTheme(_ theme: AppKitTheme) { applied.append(theme.id) }
    func prepareForClose() {}
}
