import AppKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

/// Env-gated (THEME_QA_DIR) visual-evidence generator: renders a real raster PDF,
/// waits for the page to draw, opens the theme picker, live-previews the light
/// preset, and writes a real cacheDisplay PNG. No-op in the normal suite.
@Suite("Theme picker visual evidence") @MainActor struct ThemePickerVisualEvidenceTests {
    @Test("render picker overlay + light-theme shell over rendered PDF content") func render() throws {
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
        let root = controller.mainWindowController.rootView

        let pdf = try PDFFixtureFactory.makePerformancePDF(.F, in: dir)
        #expect(controller.openDocument(at: pdf))
        let session = controller.coordinator.activeSession as? ReaderSession
        #expect(session?.goToPage(7) == true)
        session?.fitWidth()

        func capture() throws -> NSBitmapImageRep {
            root.needsLayout = true; root.layoutSubtreeIfNeeded()
            w.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.2)); root.needsDisplay = true
            let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            return rep
        }
        func regionColors(_ rep: NSBitmapImageRep) -> Int {
            guard let v = session?.contentView else { return 0 }
            let full = v.convert(v.bounds, to: root)
            let f = full.insetBy(dx: full.width / 4, dy: full.height / 4)
            let sxScale = CGFloat(rep.pixelsWide) / root.bounds.width
            let syScale = CGFloat(rep.pixelsHigh) / root.bounds.height
            let minX = max(0, Int(f.minX * sxScale)), maxX = min(rep.pixelsWide - 1, Int(f.maxX * sxScale))
            let minY = max(0, Int(f.minY * syScale)), maxY = min(rep.pixelsHigh - 1, Int(f.maxY * syScale))
            guard minX < maxX, minY < maxY else { return 0 }
            var seen = Set<UInt32>()
            for y in stride(from: minY, through: maxY, by: max(1, (maxY - minY) / 24)) {
                for x in stride(from: minX, through: maxX, by: max(1, (maxX - minX) / 24)) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    seen.insert(UInt32((c.redComponent * 15).rounded()) << 8
                        | UInt32((c.greenComponent * 15).rounded()) << 4
                        | UInt32((c.blueComponent * 15).rounded()))
                }
            }
            return seen.count
        }

        // 1. Wait until the raster page has drawn into the content region.
        var rendered = false
        for _ in 0..<40 where !rendered {
            if regionColors(try capture()) >= 12 { rendered = true }
        }
        #expect(rendered, "PDF raster did not render into the content region")

        // 2. Open the picker and live-preview the light Catppuccin Latte preset.
        controller.mainWindowController.presentThemePicker()
        let overlay = controller.mainWindowController.rootView.themePickerOverlay
        for _ in 0..<5 { _ = overlay.handleKeyDown(try #require(makeKeyEvent(characters: "", keyCode: 125))) }
        #expect(!overlay.isHidden)
        #expect(controller.currentThemeID == .catppuccinLatte)

        // 3. Capture: raster content + picker overlay on the light shell.
        var rep = try capture()
        for _ in 0..<10 where regionColors(rep) < 12 { rep = try capture() }
        #expect(regionColors(rep) >= 12)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(png.count > 20_000)
        try png.write(to: out.appendingPathComponent("picker-latte-preview.png"))
    }
}
