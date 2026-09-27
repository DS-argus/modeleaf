import AppKit
import PDFReaderCore
import XCTest
@testable import PDFReaderApp

/// Opt-in native raster evidence for the compact shortcut editor. The test is
/// skipped unless SHORTCUT_SETTINGS_QA_DIR is supplied; no synthetic transcript
/// or diagnostic output is emitted.
@MainActor
final class ShortcutSettingsVisualEvidenceTests: XCTestCase {
    func testCompactShortcutSettingsStatesProduceNativePNGEvidence() throws {
        guard let path = ProcessInfo.processInfo.environment["SHORTCUT_SETTINGS_QA_DIR"] else {
            throw XCTSkip("SHORTCUT_SETTINGS_QA_DIR is not set")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Shortcut settings visual evidence"
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let overlay = ShortcutSettingsOverlayView(frame: NSRect(x: 110, y: 70, width: 680, height: 560))
        window.contentView = host
        host.addSubview(overlay)
        window.orderFrontRegardless()
        defer {
            overlay.dismiss()
            window.orderOut(nil)
            window.close()
        }

        for themeID in ThemeID.allCases {
            overlay.apply(theme: AppKitTheme(themeID: themeID))
            overlay.render(rows: rows, status: nil, canApply: false, isDirty: false)
            overlay.present()
            try capture(overlay, named: "theme-\(themeID.rawValue)-grouped", in: output)
        }

        overlay.apply(theme: AppKitTheme(themeID: .tokyoNight))
        overlay.render(rows: rows, status: nil, canApply: false, isDirty: false)
        overlay.present()
        try capture(overlay, named: "state-default-current", in: output)

        overlay.setRecording(rowID: "view.zoomReset", text: "Cmd+Shift+P → …")
        try capture(overlay, named: "state-inline-recording", in: output)
        overlay.flashError(rowID: "view.zoomReset", message: "Conflicts with another action")
        try capture(overlay, named: "state-error", in: output)
        overlay.endRecording()
        overlay.setNeedsReconciliation(true)
        try capture(overlay, named: "state-reconciliation", in: output)
        overlay.setNeedsReconciliation(false)
        overlay.render(rows: rows, status: "Unsaved changes", canApply: true, isDirty: true)
        try capture(overlay, named: "state-dirty", in: output)
        overlay.render(rows: rows, status: nil, canApply: false, isDirty: false)
        overlay.searchFieldForTesting.stringValue = "Actual Size"
        overlay.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: overlay.searchFieldForTesting))
        try capture(overlay, named: "state-search", in: output)

        overlay.searchFieldForTesting.stringValue = "No such shortcut action"
        overlay.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: overlay.searchFieldForTesting))
        try capture(overlay, named: "state-no-results", in: output)

        overlay.searchFieldForTesting.stringValue = ""
        overlay.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: overlay.searchFieldForTesting))
        overlay.setRecording(rowID: "view.zoomReset", text: String(repeating: "Cmd+Shift+P ", count: 8))
        try capture(overlay, named: "state-long-recording-input", in: output)
    }

    private var rows: [ShortcutSettingsRow] {
        [
            ShortcutSettingsRow(
                id: "input.prefix",
                title: "Common Prefix",
                group: "",
                current: "<C-b>",
                defaultBinding: "<C-b>"
            ),
            ShortcutSettingsRow(
                id: "view.zoomReset",
                title: "Actual Size",
                group: "View",
                current: "yy",
                defaultBinding: nil,
                additionalBindingCount: 2
            ),
            ShortcutSettingsRow(
                id: "scroll.down",
                title: "Scroll Down",
                group: "Navigation",
                current: nil,
                defaultBinding: "j"
            ),
            ShortcutSettingsRow(
                id: "document.open",
                title: "Open PDF…",
                group: "Files",
                current: "<D-o>",
                defaultBinding: "<D-o>"
            ),
        ]
    }

    private func capture(_ view: NSView, named name: String, in directory: URL) throws {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.window?.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("Could not create a bitmap for \(name)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode a PNG for \(name)")
            return
        }
        XCTAssertGreaterThan(png.count, 1_000, "Native screenshot for \(name) is unexpectedly empty")
        try png.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
