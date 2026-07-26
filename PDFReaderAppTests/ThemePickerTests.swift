import AppKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("Theme picker", .serialized)
@MainActor
struct ThemePickerTests {
    // ThemeID.allCases order: mocha(0), tokyoNight(1), gruvboxDark(2), nord(3), catppuccinLatte(4)
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

        overlay.present(selectedThemeID: .catppuccinMocha)
        #expect(!overlay.isHidden)
        #expect(previews == [.catppuccinMocha])          // open seeds a preview at the current theme

        #expect(overlay.handleKeyDown(e.down))            // -> tokyoNight
        #expect(overlay.handleKeyDown(e.j))               // -> gruvboxDark
        #expect(previews == [.catppuccinMocha, .tokyoNight, .gruvboxDark])

        #expect(overlay.handleKeyDown(e.up))              // -> tokyoNight
        #expect(overlay.handleKeyDown(e.k))               // -> mocha
        #expect(previews == [.catppuccinMocha, .tokyoNight, .gruvboxDark, .tokyoNight, .catppuccinMocha])

        #expect(overlay.handleKeyDown(e.down))            // -> tokyoNight (selected)
        #expect(overlay.handleKeyDown(e.ret))             // commit tokyoNight
        #expect(committed == [.tokyoNight])
        overlay.dismiss()
        #expect(overlay.isHidden)
    }

    @Test("clamps at both ends without emitting redundant previews")
    func overlayClampsAtEnds() throws {
        let e = try keys()
        let overlay = ThemePickerOverlayView()
        var previews: [ThemeID] = []
        overlay.onPreview = { previews.append($0) }
        overlay.present(selectedThemeID: .catppuccinMocha)   // index 0
        #expect(overlay.handleKeyDown(e.up))                 // clamp at top, no new preview
        #expect(previews == [.catppuccinMocha])

        overlay.present(selectedThemeID: .catppuccinLatte)   // index 4
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
        overlay.present(selectedThemeID: .catppuccinMocha)
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
                terminationHandler: {}
            )
            _ = controller.mainWindowController
            #expect(controller.currentThemeID == .catppuccinMocha)   // no state file -> hardcoded default

            controller.mainWindowController.presentThemePicker()
            let overlay = controller.mainWindowController.rootView.themePickerOverlay
            #expect(!overlay.isHidden)

            #expect(overlay.handleKeyDown(e.down))                   // preview -> tokyoNight, not persisted
            #expect(controller.currentThemeID == .tokyoNight)
            #expect(store.loadSelectedTheme() == nil)

            #expect(overlay.handleKeyDown(e.ret))                    // commit -> persist
            #expect(controller.currentThemeID == .tokyoNight)
            #expect(store.loadSelectedTheme() == .tokyoNight)
            #expect(overlay.isHidden)

            let restarted = ApplicationController(
                configService: ConfigService(source: ConfigFileSource(url: dir.appendingPathComponent("missing.toml"))),
                sessionStore: ReaderSessionStore(),
                themeStore: ThemeSelectionStore(fileURL: stateURL),
                terminationHandler: {}
            )
            #expect(restarted.currentThemeID == .tokyoNight)
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
            store.persist(.nord)
            let controller = ApplicationController(
                configService: ConfigService(source: ConfigFileSource(url: dir.appendingPathComponent("missing.toml"))),
                sessionStore: ReaderSessionStore(),
                themeStore: store,
                terminationHandler: {}
            )
            _ = controller.mainWindowController
            #expect(controller.currentThemeID == .nord)

            controller.mainWindowController.presentThemePicker()
            let overlay = controller.mainWindowController.rootView.themePickerOverlay
            #expect(overlay.handleKeyDown(e.down))                   // preview drifts off nord
            #expect(controller.currentThemeID != .nord)
            #expect(overlay.handleKeyDown(e.esc))                    // cancel -> revert
            #expect(controller.currentThemeID == .nord)
            #expect(store.loadSelectedTheme() == .nord)              // unchanged
            #expect(overlay.isHidden)
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

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("modeleaf-theme-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}
