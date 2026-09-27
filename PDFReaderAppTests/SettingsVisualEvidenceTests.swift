import AppKit
import PDFReaderCore
import XCTest
@testable import PDFReaderApp

/// Opt-in native raster evidence for the official two-section Settings shell.
/// No synthetic transcript or diagnostic output is emitted.
@MainActor
final class SettingsVisualEvidenceTests: XCTestCase {
    func testSettingsShellStatesProduceNativePNGEvidence() throws {
        guard let path = ProcessInfo.processInfo.environment["SETTINGS_QA_DIR"] else {
            throw XCTSkip("SETTINGS_QA_DIR is not set")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WindowVisualMetrics.initialSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings visual evidence"
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(origin: .zero, size: WindowVisualMetrics.initialSize))
        let overlay = SettingsOverlayView(frame: .zero)
        window.contentView = host
        host.addSubview(overlay)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            overlay.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 16),
            overlay.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -16),
            overlay.topAnchor.constraint(greaterThanOrEqualTo: host.topAnchor, constant: 12),
            overlay.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -12),
        ])
        window.orderFrontRegardless()
        defer {
            overlay.dismiss()
            window.orderOut(nil)
            window.close()
        }

        overlay.shortcuts.render(rows: rows, status: nil, canApply: false, isDirty: false)
        for themeID in ThemeID.allCases {
            let theme = AppKitTheme(themeID: themeID)
            overlay.apply(theme: theme)
            overlay.render(values: SettingsFormValues(), status: nil, canApply: false, isDirty: false)
            overlay.present()
            try capture(overlay, named: "theme-\(themeID.rawValue)-general", in: output)

            overlay.selectSection(.keyboardShortcuts)
            try capture(overlay, named: "theme-\(themeID.rawValue)-keyboard", in: output)
        }

        window.setContentSize(WindowVisualMetrics.minimumSize)
        host.setFrameSize(window.contentView?.bounds.size ?? WindowVisualMetrics.minimumSize)
        overlay.updatePreferredSize()
        overlay.apply(theme: AppKitTheme(themeID: .tokyoNight))
        overlay.render(values: SettingsFormValues(), status: "Settings applied.", canApply: false, isDirty: false)
        overlay.present()
        try capture(overlay, named: "minimum-size-general", in: output)
        overlay.selectSection(.keyboardShortcuts)
        try capture(overlay, named: "minimum-size-keyboard", in: output)
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
