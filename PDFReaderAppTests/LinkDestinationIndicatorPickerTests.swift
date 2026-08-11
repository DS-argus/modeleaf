import AppKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("Link destination indicator picker")
@MainActor
struct LinkDestinationIndicatorPickerTests {
    @Test("style, color, size, and duration changes preview and commit one validated value")
    func interactiveCommit() throws {
        let picker = LinkDestinationIndicatorPickerOverlayView()
        var previews: [LinkDestinationIndicatorSettings] = []
        var commits: [LinkDestinationIndicatorSettings] = []
        picker.onPreview = { previews.append($0) }
        picker.onCommit = { commits.append($0) }
        picker.present(settings: .standard)

        picker.selectStyleForTesting(.target)
        picker.selectColorForTesting(.preset(.cyan))
        picker.setSizeForTesting(36)
        picker.setDurationForTesting(2_200)

        let expected = LinkDestinationIndicatorSettings(
            style: .target,
            color: .preset(.cyan),
            size: 36,
            durationMilliseconds: 2_200
        )
        #expect(picker.selectedSettingsForTesting == expected)
        #expect(previews.last == expected)
        #expect(picker.applyEnabledForTesting)
        picker.pressApplyForTesting()
        #expect(commits == [expected])
    }

    @Test("four visible columns are fully operable with Tab, h/l, j/k, Enter, and Escape")
    func keyboardOnlyTUI() throws {
        let picker = LinkDestinationIndicatorPickerOverlayView()
        var commits: [LinkDestinationIndicatorSettings] = []
        var cancellations = 0
        picker.onCommit = { commits.append($0) }
        picker.onCancel = { cancellations += 1 }
        picker.present(settings: .standard)

        #expect(picker.visibleStylesForTesting == ["Pulse Ring", "Target", "Beacon", "Static Ring", "Diamond Pulse"])
        #expect(picker.visibleColorsForTesting == ["Red", "Amber", "Cyan", "Green", "Purple"])
        #expect(picker.selectedColumnForTesting == "STYLE")

        #expect(picker.handleKeyDown(try #require(makeKeyEvent(characters: "\t", keyCode: 48))))
        #expect(picker.selectedColumnForTesting == "COLOR")
        #expect(picker.handleKeyDown(try #require(makeKeyEvent(characters: "j"))))
        #expect(picker.selectedSettingsForTesting.color == .preset(.amber))

        #expect(picker.handleKeyDown(try #require(makeKeyEvent(characters: "l"))))
        #expect(picker.selectedColumnForTesting == "SIZE")
        #expect(picker.handleKeyDown(try #require(makeKeyEvent(characters: "j"))))
        #expect(picker.selectedSettingsForTesting.size == 27)
        #expect(picker.handleKeyDown(try #require(makeKeyEvent(characters: "k"))))
        #expect(picker.selectedSettingsForTesting.size == 28)

        #expect(picker.handleKeyDown(try #require(makeKeyEvent(characters: "\t", keyCode: 48))))
        #expect(picker.selectedColumnForTesting == "DURATION")
        #expect(picker.handleKeyDown(try #require(makeKeyEvent(characters: "k"))))
        #expect(picker.selectedSettingsForTesting.durationMilliseconds == 1_600)
        #expect(picker.handleKeyDown(try #require(makeKeyEvent(characters: "\t", modifiers: [.shift], keyCode: 48))))
        #expect(picker.selectedColumnForTesting == "SIZE")

        #expect(picker.handleKeyDown(try #require(makeKeyEvent(characters: "\r", keyCode: 36))))
        #expect(commits == [picker.selectedSettingsForTesting])
        #expect(cancellations == 0)

        picker.present(settings: .standard)
        #expect(picker.handleKeyDown(try #require(makeKeyEvent(characters: "", keyCode: 53))))
        #expect(cancellations == 1)
    }

    @Test("mouse selection covers style, color, size, and duration")
    func pointerControls() {
        let picker = LinkDestinationIndicatorPickerOverlayView()
        picker.present(settings: .standard)

        picker.pointerSelectStyleForTesting(at: 4)
        #expect(picker.selectedSettingsForTesting.style == .diamondPulse)
        #expect(picker.selectedColumnForTesting == "STYLE")

        picker.pointerSelectColorForTesting(at: 4)
        #expect(picker.selectedSettingsForTesting.color == .preset(.purple))
        #expect(picker.selectedColumnForTesting == "COLOR")

        picker.pointerSetSizeForTesting(normalized: 0.75)
        #expect(picker.selectedSettingsForTesting.size == 40)
        #expect(picker.selectedColumnForTesting == "SIZE")

        picker.pointerSetDurationForTesting(normalized: 0.8)
        #expect(picker.selectedSettingsForTesting.durationMilliseconds == 2_500)
        #expect(picker.selectedColumnForTesting == "DURATION")
    }

    @Test("columns use simple dividers, centered blocks, larger headers, and fixed representative colors")
    func simplifiedColumnPresentation() {
        let picker = LinkDestinationIndicatorPickerOverlayView()
        picker.present(settings: LinkDestinationIndicatorSettings(
            style: .beacon,
            color: .customHex("#336699"),
            size: 40,
            durationMilliseconds: 2_500
        ))

        #expect(picker.dividerCountForTesting == 3)
        #expect(picker.columnHeaderFontSizeForTesting >= 12)
        #expect(picker.styleRowsAreCenteredForTesting)
        #expect(picker.visibleColorsForTesting == ["Red", "Amber", "Cyan", "Green", "Purple"])
        #expect(picker.selectedSettingsForTesting.color == .preset(.red))
        picker.layoutSubtreeIfNeeded()
        #expect(picker.previewStyleForTesting == .beacon)
        #expect(picker.previewHostSizeForTesting.width == picker.previewHostSizeForTesting.height)
        #expect(picker.previewHostSizeForTesting.width == 34)
        picker.selectStyleForTesting(.diamondPulse)
        #expect(picker.previewStyleForTesting == .diamondPulse)
    }

    @Test("size and duration volume markers move with keyboard adjustments and hints distinguish keys")
    func volumeBarsAndKeyHints() throws {
        let picker = LinkDestinationIndicatorPickerOverlayView()
        picker.present(settings: .standard)
        let initialSizePosition = picker.sizeBarPositionForTesting
        let initialDurationPosition = picker.durationBarPositionForTesting

        _ = picker.handleKeyDown(try #require(makeKeyEvent(characters: "l")))
        _ = picker.handleKeyDown(try #require(makeKeyEvent(characters: "l")))
        _ = picker.handleKeyDown(try #require(makeKeyEvent(characters: "k")))
        #expect(picker.sizeBarPositionForTesting > initialSizePosition)

        _ = picker.handleKeyDown(try #require(makeKeyEvent(characters: "l")))
        _ = picker.handleKeyDown(try #require(makeKeyEvent(characters: "k")))
        #expect(picker.durationBarPositionForTesting > initialDurationPosition)

        let hint = picker.keyHintAttributedForTesting
        let keyFont = try #require(hint.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let descriptionIndex = (hint.string as NSString).range(of: "Next").location
        let descriptionFont = try #require(hint.attribute(.font, at: descriptionIndex, effectiveRange: nil) as? NSFont)
        #expect(keyFont.fontName != descriptionFont.fontName || keyFont.pointSize != descriptionFont.pointSize)
        let keyColor = try #require(hint.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        #expect(keyColor == AppKitTheme(themeID: .tokyoNight)[.accent])
    }

    @Test("cancel restores the exact pre-open value and replacement cleanup is idempotent")
    func cancelRestoresBaseline() {
        let store = ReaderSessionStore()
        let coordinator = PaneCoordinator(initialStore: store)
        let baseline = LinkDestinationIndicatorSettings(
            style: .staticRing,
            color: .preset(.amber),
            size: 30,
            durationMilliseconds: 1_800
        )
        var active = baseline
        var cancellations: [LinkDestinationIndicatorSettings] = []
        let controller = MainWindowController(
            coordinator: coordinator,
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { _ in },
            currentIndicatorSettings: { active },
            indicatorPreviewHandler: { active = $0 },
            indicatorCommitHandler: { active = $0 },
            indicatorCancelHandler: { settings in active = settings; cancellations.append(settings) }
        )
        defer { controller.close() }

        controller.presentLinkIndicatorPicker()
        controller.rootView.linkIndicatorPickerOverlay.selectStyleForTesting(.diamondPulse)
        #expect(active.style == .diamondPulse)
        controller.rootView.linkIndicatorPickerOverlay.pressCancelForTesting()
        #expect(active == baseline)
        #expect(cancellations == [baseline])
        controller.dismissAllTransientOverlays()
        #expect(cancellations == [baseline])
    }


    @Test("indicator.picker is navigation-scoped, discoverable, and bound to I")
    func actionSurface() throws {
        let descriptor = try #require(ActionRegistry.v1.descriptor(for: .indicatorPicker))
        #expect(descriptor.isActive(in: .navigation))
        #expect(descriptor.isActive(in: .searchResults))
        #expect(!descriptor.isActive(in: .pagePrompt))
        #expect(!descriptor.isActive(in: .searchPrompt))
        #expect(BuiltInDefaults.keymap[.indicatorPicker]?.map(\.description) == ["I"])
        #expect(MenuItemRegistry.v1.contains { $0.actionID == .indicatorPicker && $0.placement == .view })
        #expect(ActionSurfaceRegistry.validate().isEmpty)
    }

    @Test("picker remains contained at the minimum window size")
    func minimumWindowContainment() {
        let root = ReaderRootView(frame: NSRect(origin: .zero, size: WindowVisualMetrics.minimumSize))
        root.apply(theme: AppKitTheme(themeID: .tokyoNight))
        root.linkIndicatorPickerOverlay.present(settings: .standard)
        root.layoutSubtreeIfNeeded()
        let frame = root.convert(root.linkIndicatorPickerOverlay.bounds, from: root.linkIndicatorPickerOverlay)
        #expect(root.bounds.contains(frame))
    }
    @Test("application state is the sole persisted authority")
    func applicationStatePersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("modeleaf-indicator-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("state.json")
        let settingsStore = LinkDestinationIndicatorSettingsStore(fileURL: stateURL)
        let initial = LinkDestinationIndicatorSettings(
            style: .diamondPulse,
            color: .preset(.highContrast),
            size: 34,
            durationMilliseconds: 2_000
        )
        #expect(settingsStore.persist(initial) == .persisted)
        let sessionStore = ReaderSessionStore()
        let first = IndicatorRecordingSession(title: "first.pdf")
        let second = IndicatorRecordingSession(title: "second.pdf")
        #expect(sessionStore.insert(first))
        #expect(sessionStore.insert(second))
        let controller = ApplicationController(
            configService: ConfigService(source: ConfigFileSource(url: directory.appendingPathComponent("config.toml"))),
            sessionStore: sessionStore,
            themeStore: ThemeSelectionStore(fileURL: stateURL),
            indicatorSettingsStore: settingsStore,
            recentFilesStore: RecentFilesStore(fileURL: stateURL),
            terminationHandler: {}
        )
        #expect(controller.currentIndicatorSettings == initial)
        #expect(first.appliedSettings.last == initial)
        #expect(second.appliedSettings.last == initial)

        let replacement = LinkDestinationIndicatorSettings(
            style: .target,
            color: .customHex("#abcdef"),
            size: 32,
            durationMilliseconds: 1_700
        )
        controller.applyIndicatorSettings(replacement, persist: true)
        #expect(settingsStore.load() == .selected(replacement))
        #expect(first.appliedSettings.last == replacement)
        #expect(second.appliedSettings.last == replacement)
    }
}

@MainActor
private final class IndicatorRecordingSession: HistoryNeutralTestSessionPresenting {
    let id = TabID()
    let title: String
    let contentView = NSView()
    private(set) var appliedSettings: [LinkDestinationIndicatorSettings] = []

    init(title: String) { self.title = title }

    var statusSnapshot: ReaderStatusSnapshot {
        ReaderStatusSnapshot(context: "NORMAL", page: "1 / 1", zoom: "100%", detail: title)
    }

    func applyTheme(_ theme: AppKitTheme) {}
    func applyLinkDestinationIndicatorSettings(_ settings: LinkDestinationIndicatorSettings) {
        appliedSettings.append(settings)
    }
    func prepareForClose() {}
}
