import AppKit
import Testing
@testable import PDFReaderApp

@Suite("Settings shell", .serialized)
@MainActor
struct SettingsOverlayTests {
    private let values = SettingsFormValues(
        smallScrollPoints: "32",
        largeScrollPercent: "80",
        zoomFactor: "1.10",
        prefixTimeoutMilliseconds: "400",
        confirmExternalLinks: false
    )

    private var keyboardRows: [ShortcutSettingsRow] {
        [
            ShortcutSettingsRow(
                id: "input.prefix",
                title: "Common Prefix",
                group: "",
                current: "<C-b>",
                defaultBinding: "<C-b>"
            ),
            ShortcutSettingsRow(
                id: "scroll.down",
                title: "Scroll Down",
                group: "Navigation",
                current: "j",
                defaultBinding: "j"
            ),
        ]
    }

    @Test("sidebar changes section without losing the general draft")
    func sidebarRetainsDraft() {
        let overlay = SettingsOverlayView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        overlay.render(values: values, canApply: false, isDirty: true)
        overlay.general.smallScrollPointsFieldForTesting.stringValue = "draft"
        overlay.general.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: overlay.general.smallScrollPointsFieldForTesting))
        overlay.keyboardButtonForTesting.performClick(nil)
        #expect(overlay.selectedSectionForTesting == .keyboardShortcuts)
        overlay.generalButtonForTesting.performClick(nil)
        #expect(overlay.selectedSectionForTesting == .general)
        #expect(overlay.general.smallScrollPointsFieldForTesting.stringValue == "draft")
        #expect(overlay.timeoutFieldForTesting.stringValue == "400")
    }

    @Test("shared footer controls expose callbacks and blocked reload recovery")
    func footerCallbacks() {
        let overlay = SettingsOverlayView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        var applied = 0
        var discarded = 0
        var restored = 0
        var reloaded = 0
        overlay.onApply = { applied += 1 }
        overlay.onDiscard = { discarded += 1 }
        overlay.onRestoreDefaults = { restored += 1 }
        overlay.onReload = { reloaded += 1 }
        overlay.render(values: values, canApply: true, isDirty: true)
        #expect(overlay.applyButtonForTesting.isEnabled)
        #expect(overlay.discardButtonForTesting.isEnabled)
        overlay.applyButtonForTesting.performClick(nil)
        overlay.discardButtonForTesting.performClick(nil)
        overlay.restoreDefaultsButtonForTesting.performClick(nil)
        #expect(applied == 1)
        #expect(discarded == 1)
        #expect(restored == 1)
        overlay.render(values: values, status: "Saved settings need review", canApply: true, isDirty: true, blocked: true)
        #expect(overlay.reloadButtonForTesting.title == "Reload saved settings")
        #expect(overlay.reloadButtonForTesting.isEnabled)
        overlay.reloadButtonForTesting.performClick(nil)
        #expect(reloaded == 1)
        #expect(overlay.footerStatusForTesting.stringValue == "Saved settings need review")
    }

    @Test("embedded keyboard child keeps search but has no duplicate title, hint, or actions")
    func embeddedKeyboardSurface() {
        let overlay = SettingsOverlayView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        let child = overlay.shortcuts
        #expect(child.isEmbeddedForTesting)
        #expect(child.headerTitleForTesting.isHidden)
        #expect(child.applyButtonForTesting.isHidden)
        #expect(child.discardButtonForTesting.isHidden)
        #expect(child.reloadButtonForTesting.isHidden)
        #expect(descendant(in: child, identifier: "shortcutSettings.search") != nil)
        #expect(descendant(in: child, identifier: "shortcutSettings.hint") == nil)
    }

    @Test("compact and large hosts constrain the shell without fixed overflow")
    func geometry() {
        for size in [NSSize(width: 480, height: 360), NSSize(width: 1_040, height: 760)] {
            let host = NSView(frame: NSRect(origin: .zero, size: size))
            let overlay = SettingsOverlayView(frame: .zero)
            overlay.render(values: values, canApply: false, isDirty: false)
            overlay.prepareForAutoLayout()
            host.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                overlay.centerYAnchor.constraint(equalTo: host.centerYAnchor),
                overlay.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 16),
                overlay.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -16),
                overlay.topAnchor.constraint(greaterThanOrEqualTo: host.topAnchor, constant: 12),
                overlay.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -12),
            ])
            overlay.isHidden = false
            overlay.updatePreferredSize()
            host.layoutSubtreeIfNeeded()
            #expect(overlay.frame.width <= size.width - 32 + 1)
            #expect(overlay.frame.height <= size.height - 24 + 1)
        }
    }

    @Test("shell navigation keeps LEFT and RIGHT ownership explicit")
    func shellNavigation() throws {
        let overlay = SettingsOverlayView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        overlay.shortcuts.render(rows: keyboardRows, status: nil, canApply: false, isDirty: false)
        overlay.render(values: values, canApply: false, isDirty: false)
        var closes = 0
        overlay.onClose = { closes += 1 }
        overlay.present()

        let down = try #require(makeKeyEvent(characters: "j", keyCode: 125))
        let up = try #require(makeKeyEvent(characters: "k", keyCode: 126))
        let right = try #require(makeKeyEvent(characters: "l"))
        let left = try #require(makeKeyEvent(characters: "h"))
        let escape = try #require(makeKeyEvent(characters: "", keyCode: 53))

        #expect(overlay.handleNavigation(down))
        #expect(overlay.selectedSectionForTesting == .keyboardShortcuts)
        #expect(overlay.handleNavigation(up))
        #expect(overlay.selectedSectionForTesting == .general)
        #expect(overlay.handleNavigation(down))
        #expect(overlay.selectedSectionForTesting == .keyboardShortcuts)
        #expect(overlay.handleNavigation(right))
        #expect(!overlay.shortcuts.panelModeForTesting)
        #expect(overlay.shortcuts.selectedRowIDForTesting == "input.prefixTimeout")
        #expect(!overlay.shortcuts.isHidden)

        #expect(overlay.handleNavigation(left))
        #expect(overlay.shortcuts.selectedRowIDForTesting == nil)
        #expect(overlay.shortcuts.panelModeForTesting)
        #expect(!overlay.shortcuts.isHidden)
        #expect(overlay.handleNavigation(escape))
        #expect(closes == 1)
    }

    @Test("shell focus leaves only the active page row selected")
    func onlyOneFocus() throws {
        let overlay = SettingsOverlayView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        overlay.shortcuts.render(rows: keyboardRows, status: nil, canApply: false, isDirty: false)
        overlay.render(values: values, canApply: false, isDirty: false)
        overlay.present()

        let right = try #require(makeKeyEvent(characters: "l"))
        let left = try #require(makeKeyEvent(characters: "h"))
        let down = try #require(makeKeyEvent(characters: "j", keyCode: 125))
        let enter = try #require(makeKeyEvent(characters: "", keyCode: 36))
        #expect(overlay.handleNavigation(right))
        #expect(overlay.general.selectedRowForNavigation != nil)
        #expect(overlay.shortcuts.selectedRowIDForTesting == nil)
        #expect(overlay.handleNavigation(left))
        #expect(overlay.general.selectedRowForNavigation == nil)
        #expect(overlay.handleNavigation(down))
        #expect(overlay.handleNavigation(enter))
        #expect(overlay.general.selectedRowForNavigation == nil)
        #expect(overlay.shortcuts.selectedRowIDForTesting == "input.prefixTimeout")
        #expect(overlay.shortcuts.selectedRowIDForTesting != nil)
        #expect([overlay.general.selectedRowForNavigation != nil, overlay.shortcuts.selectedRowIDForTesting != nil].filter { $0 }.count == 1)
    }

    @Test("general and keyboard pages keep a stable shell width")
    func widthStableAcrossSections() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1_040, height: 760))
        let overlay = SettingsOverlayView(frame: .zero)
        overlay.render(values: values, canApply: false, isDirty: false)
        overlay.prepareForAutoLayout()
        host.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            overlay.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 16),
            overlay.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -16),
            overlay.topAnchor.constraint(greaterThanOrEqualTo: host.topAnchor, constant: 12),
            overlay.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -12),
        ])
        overlay.present()
        host.layoutSubtreeIfNeeded()
        let generalWidth = overlay.frame.width
        overlay.selectSection(.keyboardShortcuts)
        host.layoutSubtreeIfNeeded()
        let keyboardWidth = overlay.frame.width
        overlay.selectSection(.general)
        host.layoutSubtreeIfNeeded()
        #expect(abs(generalWidth - keyboardWidth) < 0.5)
        #expect(abs(generalWidth - overlay.frame.width) < 0.5)
    }

    @Test("keyboard hint formatting distinguishes key tokens from words")
    func hintFormatting() {
        let theme = AppKitTheme(themeID: .tokyoNight)
        let attributed = SettingsKeyboardHint.make(
            text: "h / l  Select    ↩  Choose    Esc  Continue",
            keys: ["h / l", "↩", "Esc"],
            theme: theme
        )
        let keyRange = (attributed.string as NSString).range(of: "h / l")
        let wordRange = (attributed.string as NSString).range(of: "Select")
        let keyFont = attributed.attribute(.font, at: keyRange.location, effectiveRange: nil) as? NSFont
        let wordFont = attributed.attribute(.font, at: wordRange.location, effectiveRange: nil) as? NSFont
        let keyColor = attributed.attribute(.foregroundColor, at: keyRange.location, effectiveRange: nil) as? NSColor
        let wordColor = attributed.attribute(.foregroundColor, at: wordRange.location, effectiveRange: nil) as? NSColor
        #expect(keyFont?.familyName == NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold).familyName)
        #expect(wordFont?.familyName != keyFont?.familyName)
        #expect(keyColor?.usingColorSpace(.sRGB)?.redComponent == theme[.accent].usingColorSpace(.sRGB)?.redComponent)
        #expect(wordColor?.usingColorSpace(.sRGB)?.redComponent == theme[.mutedText].usingColorSpace(.sRGB)?.redComponent)
    }

    private func descendant(in view: NSView, identifier: String) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        for child in view.subviews {
            if let match = descendant(in: child, identifier: identifier) { return match }
        }
        return nil
    }
}
