import AppKit
import Testing
@testable import PDFReaderApp

@Suite("Shortcut settings overlay", .serialized)
@MainActor
struct ShortcutSettingsOverlayTests {
    private let rows = [
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
            defaultBinding: "j",
            additionalBindingCount: 2
        ),
        ShortcutSettingsRow(
            id: "document.open",
            title: "Open Document",
            group: "Files",
            current: nil,
            defaultBinding: "<D-o>"
        ),
        ShortcutSettingsRow(
            id: "document.save",
            title: "Save Document",
            group: "Files",
            current: "<D-s>",
            defaultBinding: "<D-s>"
        ),
    ]

    private func makeOverlay(canApply: Bool = false, isDirty: Bool = false) -> ShortcutSettingsOverlayView {
        let overlay = ShortcutSettingsOverlayView(frame: NSRect(x: 0, y: 0, width: 680, height: 560))
        overlay.render(rows: rows, status: nil, canApply: canApply, isDirty: isDirty)
        overlay.layoutSubtreeIfNeeded()
        return overlay
    }

    @Test("initial presentation is panel mode with prefix sequence rows and grouped cards")
    func panelPresentationAndGrouping() {
        let overlay = makeOverlay()
        overlay.present()
        #expect(overlay.panelModeForTesting)
        #expect(overlay.selectedRowIDForTesting == nil)
        #expect(overlay.visibleRowIDsForTesting == ["input.prefixTimeout", "input.prefix", "scroll.down", "document.open", "document.save"])
        #expect(overlay.groupCardIDsForTesting == ["shortcutSettings.group.Prefix & Sequences", "shortcutSettings.group.Navigation", "shortcutSettings.group.Files"])
        #expect(descendant(in: overlay, identifier: "shortcutSettings.group.Prefix & Sequences") != nil)
        #expect(descendant(in: overlay, identifier: "shortcutSettings.row.input.prefix") != nil)
        #expect(descendant(in: overlay, identifier: "shortcutSettings.row.input.prefixTimeout") != nil)
        #expect(descendant(in: overlay, identifier: "shortcutSettings.group.Navigation.header") != nil)
        #expect(descendant(in: overlay, identifier: "shortcutSettings.group.Files.header") != nil)
        let navigationHeader = descendant(in: overlay, identifier: "shortcutSettings.group.Navigation.header") as? NSTextField
        #expect(navigationHeader?.stringValue == "NAVIGATION")
        #expect((navigationHeader?.font?.pointSize ?? 0) >= 12)

        let navigation = descendant(in: overlay, identifier: "shortcutSettings.group.Navigation")
        let row = descendant(in: overlay, identifier: "shortcutSettings.row.scroll.down")
        #expect(navigation?.layer?.borderWidth == 1)
        #expect(row?.frame.height == 32)
        #expect(navigation.map { row?.superview?.superview === $0 } == true)
    }
    @Test("Modified slash never enters name search")
    func modifiedSlash() throws {
        let overlay = makeOverlay()
        overlay.present()
        for flags: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "/", charactersIgnoringModifiers: "/", isARepeat: false, keyCode: 44))
            #expect(!overlay.handleNavigation(event))
            #expect(!overlay.searchIsEditingForTesting)
        }
    }

    @Test("Refining a query removes stale rows within the same group")
    func refineSameGroup() {
        let overlay = makeOverlay()
        overlay.searchFieldForTesting.stringValue = "document"
        overlay.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: overlay.searchFieldForTesting))
        #expect(overlay.rowViewsForTesting["document.open"] != nil)
        #expect(overlay.rowViewsForTesting["document.save"] != nil)
        overlay.searchFieldForTesting.stringValue = "open"
        overlay.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: overlay.searchFieldForTesting))
        #expect(overlay.visibleRowIDsForTesting == ["document.open"])
        #expect(overlay.rowViewsForTesting["document.save"] == nil)
        #expect(descendant(in: overlay, identifier: "shortcutSettings.row.document.save.record") == nil)
    }
    @Test("title-only search keeps the query and focuses the match on Enter/Escape")
    func search() throws {
        let overlay = makeOverlay()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = overlay
        defer { window.close() }
        overlay.present()

        let slash = try #require(makeKeyEvent(characters: "/", charactersIgnoringModifiers: "/", keyCode: 44))
        let enter = try #require(makeKeyEvent(characters: "\r", keyCode: 36))
        #expect(overlay.handleNavigation(slash))
        overlay.searchFieldForTesting.stringValue = "open"
        overlay.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: overlay.searchFieldForTesting))
        #expect(overlay.visibleRowIDsForTesting == ["document.open"])
        #expect(overlay.handleNavigation(enter))
        #expect(!overlay.searchIsEditingForTesting)
        #expect(overlay.selectedRowIDForTesting == "document.open")
        #expect(window.firstResponder === descendant(in: overlay, identifier: "shortcutSettings.row.document.open.title"))
        #expect(overlay.searchFieldForTesting.stringValue == "open")

        #expect(overlay.handleNavigation(slash))
        let escape = try #require(makeKeyEvent(characters: "\u{1b}", keyCode: 53))
        #expect(overlay.handleNavigation(escape))
        #expect(!overlay.searchIsEditingForTesting)
        #expect(overlay.selectedRowIDForTesting == "document.open")
    }

    @Test("no-result search exits to panel mode and focuses the panel")
    func emptySearch() throws {
        let overlay = makeOverlay()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = overlay
        defer { window.close() }
        overlay.present()
        let slash = try #require(makeKeyEvent(characters: "/", keyCode: 44))
        let escape = try #require(makeKeyEvent(characters: "\u{1b}", keyCode: 53))
        #expect(overlay.handleNavigation(slash))
        overlay.searchFieldForTesting.stringValue = "no such action"
        overlay.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: overlay.searchFieldForTesting))
        #expect(overlay.visibleRowIDsForTesting.isEmpty)
        #expect(overlay.handleNavigation(escape))
        #expect(overlay.panelModeForTesting)
        #expect(overlay.selectedRowIDForTesting == nil)
        #expect(window.firstResponder === overlay)
        #expect(overlay.searchFieldForTesting.stringValue == "no such action")
    }

    @Test("panel Enter applies only when enabled and panel Escape closes")
    func panelMode() throws {
        let overlay = makeOverlay(canApply: true, isDirty: true)
        var applyCount = 0
        var closeCount = 0
        overlay.onApply = { applyCount += 1 }
        overlay.onClose = { closeCount += 1 }
        overlay.present()
        let enter = try #require(makeKeyEvent(characters: "\r", keyCode: 36))
        let escape = try #require(makeKeyEvent(characters: "\u{1b}", keyCode: 53))
        #expect(overlay.handleNavigation(enter))
        #expect(applyCount == 1)
        #expect(overlay.handleNavigation(escape))
        #expect(closeCount == 1)

        overlay.render(rows: rows, status: nil, canApply: false, isDirty: true)
        overlay.present()
        #expect(overlay.handleNavigation(enter))
        #expect(applyCount == 1)
        #expect(overlay.handleNavigation(escape))
        #expect(closeCount == 2)
    }

    @Test("selected-row Escape enters panel mode, while selected-row Enter records")
    func rowMode() throws {
        let overlay = makeOverlay()
        var recorded: [String] = []
        var closed = 0
        overlay.onRecord = { recorded.append($0) }
        overlay.onClose = { closed += 1 }
        let down = try #require(makeKeyEvent(characters: "", keyCode: 125))
        let enter = try #require(makeKeyEvent(characters: "\r", keyCode: 36))
        let escape = try #require(makeKeyEvent(characters: "\u{1b}", keyCode: 53))
        #expect(overlay.handleNavigation(down))
        #expect(overlay.selectedRowIDForTesting == "input.prefixTimeout")
        #expect(overlay.handleNavigation(down))
        #expect(overlay.selectedRowIDForTesting == "input.prefix")
        #expect(overlay.handleNavigation(down))
        #expect(overlay.selectedRowIDForTesting == "scroll.down")
        #expect(overlay.handleNavigation(enter))
        overlay.endRecording()
        #expect(recorded == ["scroll.down"])
        #expect(overlay.selectedRowIDForTesting == "scroll.down")
        #expect(overlay.handleNavigation(escape))
        #expect(overlay.selectedRowIDForTesting == nil)
        #expect(overlay.panelModeForTesting)
        #expect(closed == 0)
        #expect(overlay.handleNavigation(escape))
        #expect(closed == 1)
    }

    @Test("recording displays inline Current progress, owns all navigation input, and restores selection")
    func recording() {
        let overlay = makeOverlay()
        overlay.setRecording(rowID: "document.open", text: "<D-o>")
        #expect(overlay.selectedRowIDForTesting == "document.open")
        #expect(!overlay.handleNavigation(makeKeyEvent(characters: "j", charactersIgnoringModifiers: "j")!))
        #expect(!overlay.handleNavigation(makeKeyEvent(characters: "\r", keyCode: 36)!))
        #expect(!overlay.handleNavigation(makeKeyEvent(characters: "\u{1b}", keyCode: 53)!))
        #expect(overlay.currentTextForTesting(rowID: "document.open") == "<D-o>")
        overlay.endRecording()
        #expect(overlay.selectedRowIDForTesting == "document.open")
        #expect(overlay.currentTextForTesting(rowID: "document.open") == "Unassigned")
    }

    @Test("Record and Reset callbacks are row-scoped")
    func callbacks() {
        let overlay = makeOverlay()
        var recorded: [String] = []
        var reset: [String] = []
        overlay.onRecord = { recorded.append($0) }
        overlay.onReset = { reset.append($0) }
        (descendant(in: overlay, identifier: "shortcutSettings.row.document.open.record") as? NSButton)?.performClick(nil)
        (descendant(in: overlay, identifier: "shortcutSettings.row.document.open.reset") as? NSButton)?.performClick(nil)
        #expect(recorded == ["document.open"])
        #expect(reset == ["document.open"])
    }

    @Test("Selected rows use visible accent fill and clear it on panel focus")
    func selectionContrast() throws {
        let overlay = makeOverlay()
        overlay.present()
        let row = try #require(overlay.rowViewsForTesting["input.prefixTimeout"])
        #expect(row.layer?.backgroundColor?.alpha == 0)
        let down = try #require(makeKeyEvent(characters: "", keyCode: 125))
        #expect(overlay.handleNavigation(down))
        #expect(row.layer?.backgroundColor == AppKitTheme(themeID: .tokyoNight)[.accent].withAlphaComponent(0.30).cgColor)
        #expect(row.layer?.borderWidth == 0)
        let escape = try #require(makeKeyEvent(characters: "\u{1b}", keyCode: 53))
        #expect(overlay.handleNavigation(escape))
        #expect(row.layer?.backgroundColor?.alpha == 0)
    }
    @Test("flashError highlights one row and persists the footer message")
    func errors() {
        let overlay = makeOverlay()
        let row = overlay.rowViewsForTesting["document.open"]
        overlay.setRecording(rowID: "document.open", text: "<D-o>")
        let focusFill = row?.layer?.backgroundColor
        #expect(row?.layer?.borderWidth == 0)
        overlay.endRecording()
        overlay.flashError(rowID: "document.open", message: "Conflicts with Scroll Down")
        #expect(overlay.isFlashingForTesting(rowID: "document.open"))
        #expect(row?.layer?.borderWidth == 0)
        #expect(row?.layer?.backgroundColor != nil)
        #expect(row?.layer?.backgroundColor != focusFill)
        #expect(overlay.footerStatusForTesting.stringValue == "Conflicts with Scroll Down")
        #expect(overlay.footerStatusForTesting.textColor?.usingColorSpace(.sRGB)?.redComponent == AppKitTheme(themeID: .tokyoNight)[.error].usingColorSpace(.sRGB)?.redComponent)
    }

    @Test("footer uses Discard/Apply and conditional Reload without a Close button")
    func footer() {
        let overlay = makeOverlay(canApply: true, isDirty: true)
        var discardCount = 0
        var applyCount = 0
        var reloadCount = 0
        overlay.onDiscard = { discardCount += 1 }
        overlay.onApply = { applyCount += 1 }
        overlay.onReload = { reloadCount += 1 }
        #expect(descendant(in: overlay, identifier: "shortcutSettings.close") == nil)
        #expect(overlay.orderedKeyViews.contains { $0 === overlay.discardButtonForTesting })
        #expect(overlay.orderedKeyViews.contains { $0 === overlay.applyButtonForTesting })
        overlay.discardButtonForTesting.performClick(nil)
        overlay.applyButtonForTesting.performClick(nil)
        #expect(discardCount == 1)
        #expect(applyCount == 1)
        overlay.setNeedsReconciliation(true)
        #expect(overlay.reloadButtonForTesting.isEnabled)
        #expect(!overlay.applyButtonForTesting.isEnabled)
        overlay.reloadButtonForTesting.performClick(nil)
        #expect(reloadCount == 1)
        overlay.setNeedsReconciliation(false)
        #expect(overlay.reloadButtonForTesting.isHidden)
    }

    @Test("keyboard hints use accent monospace keys and muted descriptions")
    func hints() {
        let overlay = makeOverlay()
        overlay.present()
        let attributed = overlay.footerHintForTesting.attributedStringValue
        let keyRange = (attributed.string as NSString).range(of: "j / k")
        let descriptionRange = (attributed.string as NSString).range(of: "Select row")
        let keyColor = attributed.attribute(.foregroundColor, at: keyRange.location, effectiveRange: nil) as? NSColor
        let descriptionColor = attributed.attribute(.foregroundColor, at: descriptionRange.location, effectiveRange: nil) as? NSColor
        #expect(keyColor?.usingColorSpace(.sRGB)?.redComponent == AppKitTheme(themeID: .tokyoNight)[.accent].usingColorSpace(.sRGB)?.redComponent)
        #expect(descriptionColor?.usingColorSpace(.sRGB)?.redComponent == AppKitTheme(themeID: .tokyoNight)[.mutedText].usingColorSpace(.sRGB)?.redComponent)
    }

    @Test("hidden compact and normal hosts have reachable, non-ambiguous grouped layout")
    func layout() {
        for size in [NSSize(width: 480, height: 360), NSSize(width: 1_040, height: 760)] {
            let host = NSView(frame: NSRect(origin: .zero, size: size))
            let overlay = ShortcutSettingsOverlayView(frame: .zero)
            overlay.render(rows: rows, status: nil, canApply: false, isDirty: false)
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
            overlay.isHidden = true
            host.layoutSubtreeIfNeeded()
            assertNoAmbiguousLayout(in: host)
            #expect(overlay.frame.width <= size.width - 32 + 0.5)
            #expect(overlay.frame.height <= size.height - 24 + 0.5)
            if size.width >= 1_000 {
                overlay.isHidden = false
                overlay.updatePreferredSize()
                host.layoutSubtreeIfNeeded()
                #expect(abs(overlay.frame.width - 680) < 1)
                #expect(abs(overlay.frame.height - 610) < 1)
                overlay.searchFieldForTesting.stringValue = "open"
                overlay.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: overlay.searchFieldForTesting))
                host.layoutSubtreeIfNeeded()
                #expect(abs(overlay.frame.width - 680) < 1)
                #expect(abs(overlay.frame.height - 610) < 1)
            }
        }
    }

    @Test("Tab order is deterministic and theme changes grouped primitives")
    func focusAndTheme() {
        let overlay = makeOverlay(canApply: true, isDirty: true)
        #expect(overlay.orderedKeyViews.first === overlay.searchFieldForTesting)
        #expect(overlay.orderedKeyViews.contains { $0 === overlay.applyButtonForTesting })
        #expect(overlay.orderedKeyViews.contains { $0 === overlay.discardButtonForTesting })
        #expect(overlay.orderedKeyViews.allSatisfy { $0.acceptsFirstResponder })
        overlay.setRecording(rowID: "scroll.down", text: "j")
        overlay.apply(theme: AppKitTheme(themeID: .tokyoNight))
        let first = overlay.rowViewsForTesting["scroll.down"]?.layer?.backgroundColor
        overlay.apply(theme: AppKitTheme(themeID: .gruvboxDark))
        let second = overlay.rowViewsForTesting["scroll.down"]?.layer?.backgroundColor
        #expect(first != second)
    }

    @Test("compact rows reserve a narrow Current box and keep action text styling stable")
    func compactRowGeometryAndStableText() {
        let longTitle = "A Very Long Action Name That Fits Wide"
        let compact = ShortcutSettingsOverlayView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        compact.render(rows: [
            ShortcutSettingsRow(
                id: "long.action",
                title: longTitle,
                group: "Application",
                current: "<D-S-p>",
                defaultBinding: "<D-S-p>"
            )
        ], status: nil, canApply: false, isDirty: false)
        compact.layoutSubtreeIfNeeded()

        let title = descendant(in: compact, identifier: "shortcutSettings.row.long.action.title") as? NSButton
        let keycap = descendant(in: compact, identifier: "shortcutSettings.row.long.action.current")
        let initialFont = title?.font
        #expect(keycap.map { (90...104).contains(Int($0.frame.width.rounded())) } == true)
        let record = descendant(in: compact, identifier: "shortcutSettings.row.long.action.record") as? NSButton
        let reset = descendant(in: compact, identifier: "shortcutSettings.row.long.action.reset") as? NSButton
        #expect(record?.frame.width == 42)
        #expect(reset?.frame.width == 36)
        #expect(record?.font?.pointSize == 10)
        #expect(record?.isBordered == false)
        #expect((title?.frame.width ?? 0) >= 230)
        #expect(title?.toolTip == longTitle)

        compact.setRecording(rowID: "long.action", text: "<D-S-p>")
        #expect(title?.font?.pointSize == initialFont?.pointSize)
        #expect(title?.font?.fontName == initialFont?.fontName)
    }

    private func assertNoAmbiguousLayout(in view: NSView) {
        #expect(!view.hasAmbiguousLayout, "ambiguous \(type(of: view)) id=\(view.accessibilityIdentifier())")
        for child in view.subviews where !(child is NSScroller) && !(child is NSClipView) {
            assertNoAmbiguousLayout(in: child)
        }
    }

    private func descendant(in view: NSView, identifier: String) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        for child in view.subviews {
            if let found = descendant(in: child, identifier: identifier) { return found }
        }
        return nil
    }
}
