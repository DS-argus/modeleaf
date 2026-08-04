import AppKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("Theme picker", .serialized)
@MainActor
struct ThemePickerTests {
    // ThemeID.allCases order: tokyoNight(0), gruvboxDark(1), solarizedDark(2), dracula(3), everforest(4), catppuccinLatte(5)
    private func keys() throws -> (down: NSEvent, up: NSEvent, ret: NSEvent, esc: NSEvent, j: NSEvent, k: NSEvent) {
        (
            down: try #require(makeKeyEvent(characters: "", keyCode: 125)),
            up: try #require(makeKeyEvent(characters: "", keyCode: 126)),
            ret: try #require(makeKeyEvent(characters: "\r", keyCode: 36)),
            esc: try #require(makeKeyEvent(characters: "\u{1B}", keyCode: 53)),
            j: try #require(makeKeyEvent(characters: "j", keyCode: 38)),
            k: try #require(makeKeyEvent(characters: "k", keyCode: 40))
        )
    }

    @Test("AC-3/AC-4 overlay live-previews on move and commits the selected theme")
    func overlayPreviewCommit() throws {
        let e = try keys()
        let overlay = ThemePickerOverlayView()
        var previews: [ThemeID] = []
        var committed: [ThemeID] = []
        overlay.onPreview = { previews.append($0) }
        overlay.onCommit = { committed.append($0) }

        overlay.present(selectedThemeID: .tokyoNight)
        #expect(!overlay.isHidden)
        #expect(previews.isEmpty)                         // open renders the current theme; no re-apply

        #expect(overlay.handleKeyDown(e.down))            // -> gruvboxDark
        #expect(overlay.handleKeyDown(e.j))               // -> solarizedDark
        #expect(previews == [.gruvboxDark, .solarizedDark])

        #expect(overlay.handleKeyDown(e.up))              // -> gruvboxDark
        #expect(overlay.handleKeyDown(e.k))               // -> tokyoNight
        #expect(previews == [.gruvboxDark, .solarizedDark, .gruvboxDark, .tokyoNight])

        #expect(overlay.handleKeyDown(e.down))            // -> gruvboxDark (selected)
        #expect(overlay.handleKeyDown(e.ret))             // commit gruvboxDark
        #expect(committed == [.gruvboxDark])
        overlay.dismiss()
        #expect(overlay.isHidden)
    }

    @Test("clamps at both ends without emitting redundant previews")
    func overlayClampsAtEnds() throws {
        let e = try keys()
        let overlay = ThemePickerOverlayView()
        var previews: [ThemeID] = []
        overlay.onPreview = { previews.append($0) }
        overlay.present(selectedThemeID: .tokyoNight)        // index 0
        #expect(overlay.handleKeyDown(e.up))                 // clamp at top, no preview
        #expect(previews.isEmpty)

        overlay.present(selectedThemeID: .catppuccinLatte)   // index 5 (last)
        previews.removeAll()
        #expect(overlay.handleKeyDown(e.down))               // clamp at bottom, no preview
        #expect(previews.isEmpty)
    }

    @Test("AC-4 escape cancels without committing")
    func overlayEscapeCancels() throws {
        let e = try keys()
        let overlay = ThemePickerOverlayView()
        var committed: [ThemeID] = []
        var cancelled = 0
        overlay.onCommit = { committed.append($0) }
        overlay.onCancel = { cancelled += 1 }
        overlay.present(selectedThemeID: .tokyoNight)
        #expect(overlay.handleKeyDown(e.down))
        #expect(overlay.handleKeyDown(e.esc))
        #expect(cancelled == 1)
        #expect(committed.isEmpty)
    }

    @Test("AC-3/AC-6 dispatched picker previews without persisting, commit persists, restart restores")
    func endToEndPersistence() throws {
        let e = try keys()
        try withTemporaryDirectory { dir in
            let stateURL = dir.appendingPathComponent("state.json")
            let store = ThemeSelectionStore(fileURL: stateURL)
            let controller = ApplicationController(
                configService: ConfigService(source: ConfigFileSource(url: dir.appendingPathComponent("missing.toml"))),
                sessionStore: ReaderSessionStore(),
                themeStore: store,
                recentFilesStore: RecentFilesStore(fileURL: dir.appendingPathComponent("recent-state.json")),
                terminationHandler: {}
            )
            _ = controller.mainWindowController
            #expect(controller.currentThemeID == .tokyoNight)        // no state file -> hardcoded default

            controller.mainWindowController.presentThemePicker()
            let overlay = controller.mainWindowController.rootView.themePickerOverlay
            #expect(!overlay.isHidden)

            #expect(overlay.handleKeyDown(e.down))                   // preview -> gruvboxDark, not persisted
            #expect(controller.currentThemeID == .gruvboxDark)
            #expect(store.loadSelectedTheme() == nil)

            #expect(overlay.handleKeyDown(e.ret))                    // commit -> persist
            #expect(controller.currentThemeID == .gruvboxDark)
            #expect(store.loadSelectedTheme() == .gruvboxDark)
            #expect(overlay.isHidden)

            let restarted = ApplicationController(
                configService: ConfigService(source: ConfigFileSource(url: dir.appendingPathComponent("missing.toml"))),
                sessionStore: ReaderSessionStore(),
                themeStore: ThemeSelectionStore(fileURL: stateURL),
                recentFilesStore: RecentFilesStore(fileURL: dir.appendingPathComponent("recent-state.json")),
                terminationHandler: {}
            )
            #expect(restarted.currentThemeID == .gruvboxDark)
            restarted.mainWindowController.close()
            controller.mainWindowController.close()
        }
    }

    @Test("AC-4 escape reverts to the pre-open theme without persisting")
    func endToEndCancelReverts() throws {
        let e = try keys()
        try withTemporaryDirectory { dir in
            let stateURL = dir.appendingPathComponent("state.json")
            let store = ThemeSelectionStore(fileURL: stateURL)
            store.persist(.dracula)
            let controller = ApplicationController(
                configService: ConfigService(source: ConfigFileSource(url: dir.appendingPathComponent("missing.toml"))),
                sessionStore: ReaderSessionStore(),
                themeStore: store,
                recentFilesStore: RecentFilesStore(fileURL: dir.appendingPathComponent("recent-state.json")),
                terminationHandler: {}
            )
            _ = controller.mainWindowController
            #expect(controller.currentThemeID == .dracula)

            controller.mainWindowController.presentThemePicker()
            let overlay = controller.mainWindowController.rootView.themePickerOverlay
            #expect(overlay.handleKeyDown(e.down))                   // preview drifts off dracula
            #expect(controller.currentThemeID != .dracula)
            #expect(overlay.handleKeyDown(e.esc))                    // cancel -> revert
            #expect(controller.currentThemeID == .dracula)
            #expect(store.loadSelectedTheme() == .dracula)           // unchanged
            #expect(overlay.isHidden)
            controller.mainWindowController.close()
        }
    }
    @Test("replacing a previewing theme picker cancels exactly once and restores the pre-open theme")
    func replacingThemePickerRestoresPreview() throws {
        let keys = try keys()
        try withTemporaryDirectory { dir in
            let store = ThemeSelectionStore(fileURL: dir.appendingPathComponent("state.json"))
            store.persist(.dracula) // deterministic non-last theme so a down-arrow preview always drifts
            let controller = ApplicationController(
                configService: ConfigService(source: ConfigFileSource(url: dir.appendingPathComponent("missing.toml"))),
                sessionStore: ReaderSessionStore(),
                themeStore: store,
                recentFilesStore: RecentFilesStore(fileURL: dir.appendingPathComponent("recent-state.json")),
                terminationHandler: {}
            )
            defer { controller.mainWindowController.close() }
            _ = controller.mainWindowController
            let preOpenTheme = controller.currentThemeID
            #expect(preOpenTheme == .dracula)
            controller.mainWindowController.presentThemePicker()
            #expect(controller.mainWindowController.rootView.themePickerOverlay.handleKeyDown(keys.down))
            #expect(controller.currentThemeID != preOpenTheme)
            controller.mainWindowController.presentRecentFilesOverlay()
            #expect(controller.mainWindowController.rootView.themePickerOverlay.isHidden)
            #expect(controller.currentThemeID == preOpenTheme)
        }
    }


    @Test("AC-7 operational state read failure launches on default and surfaces a diagnostic")
    func startupIOErrorSurfacesDiagnostic() throws {
        try withTemporaryDirectory { dir in
            // A directory at the state-file path is an operational I/O failure,
            // NOT one of the silent absent/invalid cases.
            let stateURL = dir.appendingPathComponent("state.json")
            try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
            let controller = ApplicationController(
                configService: ConfigService(source: ConfigFileSource(url: dir.appendingPathComponent("missing.toml"))),
                sessionStore: ReaderSessionStore(),
                themeStore: ThemeSelectionStore(fileURL: stateURL),
                recentFilesStore: RecentFilesStore(fileURL: dir.appendingPathComponent("recent-state.json")),
                terminationHandler: {}
            )
            #expect(controller.currentThemeID == .tokyoNight)        // launch continuity
            controller.start()
            let status = controller.mainWindowController.rootView.statusBar.presentation
            #expect(status.detail.contains("Could not read the saved theme"))
            controller.mainWindowController.close()
        }
    }

    @Test("AC-4/AC-7 a failed durable commit still applies the theme but reports the save failure")
    func commitPersistFailureIsReported() throws {
        let e = try keys()
        try withTemporaryDirectory { dir in
            // Make the state parent a FILE so persist() cannot create it.
            let parent = dir.appendingPathComponent("blocked", isDirectory: false)
            try Data("x".utf8).write(to: parent)
            let stateURL = parent.appendingPathComponent("state.json")
            let controller = ApplicationController(
                configService: ConfigService(source: ConfigFileSource(url: dir.appendingPathComponent("missing.toml"))),
                sessionStore: ReaderSessionStore(),
                themeStore: ThemeSelectionStore(fileURL: stateURL),
                recentFilesStore: RecentFilesStore(fileURL: dir.appendingPathComponent("recent-state.json")),
                terminationHandler: {}
            )
            _ = controller.mainWindowController
            controller.mainWindowController.presentThemePicker()
            let overlay = controller.mainWindowController.rootView.themePickerOverlay
            #expect(overlay.handleKeyDown(e.down))   // -> gruvboxDark
            #expect(overlay.handleKeyDown(e.ret))     // commit (persist fails)
            #expect(controller.currentThemeID == .gruvboxDark)   // applied for this session
            let status = controller.mainWindowController.rootView.statusBar.presentation
            #expect(status.detail.contains("could not be saved"))
            controller.mainWindowController.close()
        }
    }

    @Test("AC-7 a config warning and a state-file I/O error are both surfaced at startup")
    func aggregatedStartupDiagnostics() throws {
        try withTemporaryDirectory { dir in
            // Legacy [theme] in the config -> deprecation WARNING diagnostic.
            let configURL = dir.appendingPathComponent("config.toml")
            try Data("[theme]\nbuilt_in = \"nord\"\n".utf8).write(to: configURL)
            // A directory at the state path -> operational ioError.
            let stateURL = dir.appendingPathComponent("state.json")
            try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
            let controller = ApplicationController(
                configService: ConfigService(source: ConfigFileSource(url: configURL)),
                sessionStore: ReaderSessionStore(),
                themeStore: ThemeSelectionStore(fileURL: stateURL),
                recentFilesStore: RecentFilesStore(fileURL: dir.appendingPathComponent("recent-state.json")),
                terminationHandler: {}
            )
            controller.start()
            let status = controller.mainWindowController.rootView.statusBar.presentation
            // The config warning occupies the summary AND the theme I/O error is
            // folded into the expanded detail (neither failure is hidden).
            #expect(status.detail.contains("warning") || status.tone == .normal)
            #expect(status.expandedDetail?.contains("Could not read the saved theme") == true)
            controller.mainWindowController.close()
        }
    }

    @Test("AC-5 theme.picker is prompt-safe, navigation-scoped, default T, and rebindable")
    func actionSurfaceAndPromptSafety() throws {
        let descriptor = try #require(ActionRegistry.v1.descriptor(for: .themePicker))
        #expect(descriptor.isActive(in: .navigation))
        #expect(descriptor.isActive(in: .searchResults))
        #expect(!descriptor.isActive(in: .pagePrompt))
        #expect(!descriptor.isActive(in: .searchPrompt))
        #expect(BuiltInDefaults.keymap[.themePicker]?.map(\.description) == ["T"])
        #expect(ActionSurfaceRegistry.validate().isEmpty)

        let rebound = try KeySequenceParser.parse("<C-t>")
        let effective = BuiltInDefaults.keymap.merging([.themePicker: [rebound]]) { _, new in new }
        let evaluated = ActionBindingPolicy.evaluateEffective(effective, registry: ActionRegistry.v1)
        #expect(evaluated.diagnostics.isEmpty)
        #expect(evaluated.validatedKeymap?.bindings(for: .themePicker) == [rebound])
    }

    @Test("AC-10 picker preview and commit theme every session in single and split panes")
    func pickerPropagatesThemeAcrossLivePaneSessions() throws {
        let e = try keys()
        for paneCount in [1, 2] {
            try withTemporaryDirectory { directory in
                let sessionStore = ReaderSessionStore()
                let controller = ApplicationController(
                    configService: ConfigService(source: ConfigFileSource(url: directory.appendingPathComponent("missing.toml"))),
                    sessionStore: sessionStore,
                    themeStore: ThemeSelectionStore(fileURL: directory.appendingPathComponent("state.json")),
                    recentFilesStore: RecentFilesStore(fileURL: directory.appendingPathComponent("recent-state.json")),
                    terminationHandler: {}
                )
                let first = ThemeRecordingSession(title: "First.pdf")
                let second = ThemeRecordingSession(title: "Second.pdf")
                controller.coordinator.configureDuplication { _ in second }
                #expect(controller.coordinator.insert(first, into: .createIfEmpty))
                if paneCount == 2 {
                    #expect(controller.coordinator.split(direction: .sideBySide) != nil)
                }
                #expect(controller.coordinator.snapshot.layout.paneIDs.count == paneCount)

                controller.mainWindowController.presentThemePicker()
                let overlay = controller.mainWindowController.rootView.themePickerOverlay
                first.appliedThemeIDs.removeAll()
                second.appliedThemeIDs.removeAll()
                #expect(overlay.handleKeyDown(e.down))
                #expect([first, second].prefix(paneCount).allSatisfy { $0.appliedThemeIDs == [.gruvboxDark] })
                #expect(overlay.handleKeyDown(e.ret))
                #expect([first, second].prefix(paneCount).allSatisfy { $0.appliedThemeIDs == [.gruvboxDark, .gruvboxDark] })
                controller.mainWindowController.close()
            }
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("modeleaf-theme-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

}
@MainActor
private final class ThemeRecordingSession: ReaderSessionPresenting, ReaderDuplicationSnapshotProviding {
    let id = TabID()
    let title: String
    let contentView = NSView()
    var appliedThemeIDs: [ThemeID] = []

    init(title: String) { self.title = title }

    var statusSnapshot: ReaderStatusSnapshot {
        ReaderStatusSnapshot(context: "NORMAL", page: "1 / 1", zoom: "100%", detail: title)
    }

    var duplicationSnapshot: ReaderDuplicationSnapshot? {
        ReaderDuplicationSnapshot(sourceURL: URL(fileURLWithPath: "/tmp/\(title)"), navigation: NavigationSnapshot(pageIndex: 0, pageSpacePoint: .zero)!)
    }

    func applyTheme(_ theme: AppKitTheme) { appliedThemeIDs.append(theme.id) }
    func prepareForClose() {}
}
