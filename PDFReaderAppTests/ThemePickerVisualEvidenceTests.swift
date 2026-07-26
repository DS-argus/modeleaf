import AppKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

/// Env-gated (THEME_QA_DIR) visual-evidence generator: opens the theme
/// picker, previews the light preset, and writes a real cacheDisplay PNG.
/// No-op in the normal suite. Mirrors visualAcceptanceMatrix/duplication measurement.
@Suite("Theme picker visual evidence") @MainActor struct ThemePickerVisualEvidenceTests {
    @Test("render picker overlay + a light-theme applied shell") func render() throws {
        guard let outDir = ProcessInfo.processInfo.environment["THEME_QA_DIR"] else { return }
        let out = URL(fileURLWithPath: outDir, isDirectory: true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tprobe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThemeSelectionStore(fileURL: dir.appendingPathComponent("state.json"))
        let controller = ApplicationController(
            configService: ConfigService(source: ConfigFileSource(url: dir.appendingPathComponent("missing.toml"))),
            sessionStore: ReaderSessionStore(), themeStore: store, terminationHandler: {})
        defer { controller.mainWindowController.close() }
        _ = controller.mainWindowController
        let w = controller.mainWindowController.window!
        w.setContentSize(NSSize(width: 900, height: 640)); w.orderFrontRegardless()
        func pump() { w.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        // Open a raster PDF so the shell shows non-uniform page content behind
        // the overlay (evidence must be a real, non-blank frame).
        let pdf = try PDFFixtureFactory.makePerformancePDF(.F, in: dir)
        #expect(controller.openDocument(at: pdf))
        (controller.coordinator.activeSession as? ReaderSession)?.fitWidth()
        for _ in 0..<12 { pump() }
        // open picker, move selection to catppuccin-latte (live preview -> light shell), capture
        controller.mainWindowController.presentThemePicker()
        let overlay = controller.mainWindowController.rootView.themePickerOverlay
        for _ in 0..<4 { _ = overlay.handleKeyDown(try #require(makeKeyEvent(characters: "", keyCode: 125))) }
        pump()
        let root = controller.mainWindowController.rootView
        root.needsLayout = true; root.layoutSubtreeIfNeeded(); w.displayIfNeeded()
        // The evidence must show the picker open with the light preset live-
        // previewed, not an arbitrary frame.
        #expect(!overlay.isHidden)
        #expect(controller.currentThemeID == .catppuccinLatte)
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(png.count > 20_000)
        try png.write(to: out.appendingPathComponent("picker-latte-preview.png"))
    }
}
