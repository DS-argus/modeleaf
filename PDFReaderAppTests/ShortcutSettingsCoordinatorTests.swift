import AppKit
import Foundation
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("Settings coordinator", .serialized)
@MainActor
struct SettingsCoordinatorTests {
    @Test("General and Keyboard drafts remain shared while switching sections")
    func sharedDraftAcrossSections() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("settings.json")
            let service = SettingsService(store: SettingsStore(fileURL: url))
            try write(
                SparseAppConfig(
                    keymap: [ActionID.helpShow.rawValue: ["x", "v"]],
                    navigation: SparseNavigationConfiguration(smallScrollPoints: 48)
                ),
                using: service
            )
            let state = CoordinatorState(active: service.load().activeConfig)
            let (window, view, editor) = makeEditor(service: service, state: state)
            defer { window.close() }
            editor.open()

            #expect(view.selectedSectionForTesting == .general)
            #expect(view.general.valuesForTesting.smallScrollPoints == "48.0")
            let smallScroll = view.general.smallScrollPointsFieldForTesting
            smallScroll.stringValue = "64"
            view.general.controlTextDidChange(Notification(
                name: NSControl.textDidChangeNotification,
                object: smallScroll
            ))

            view.selectSection(.keyboardShortcuts)
            editor.acceptRecordedSource("z", for: ActionID.helpShow.rawValue)
            #expect(view.shortcuts.currentTextForTesting(rowID: ActionID.helpShow.rawValue) == "z")
            view.selectSection(.general)
            #expect(view.general.valuesForTesting.smallScrollPoints == "64")
            #expect(editor.isDirty)

            view.onApply?()
            let saved = service.load()
            #expect(saved.sparse.keymap?[ActionID.helpShow.rawValue] == ["z", "v"])
            #expect(saved.sparse.navigation == SparseNavigationConfiguration(smallScrollPoints: 64))
            #expect(state.active.config == saved.activeConfig.config)
            #expect(state.generation == 1)
            #expect(!editor.isDirty)
        }
    }

    @Test("invalid numeric input is rejected without saving or activating a generation")
    func invalidNumericInputDoesNotSave() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("settings.json")
            let service = SettingsService(store: SettingsStore(fileURL: url))
            try write(SparseAppConfig(navigation: SparseNavigationConfiguration(smallScrollPoints: 48)), using: service)
            let original = try Data(contentsOf: url)
            let state = CoordinatorState(active: service.load().activeConfig)
            let (window, view, editor) = makeEditor(service: service, state: state)
            defer { window.close() }
            editor.open()

            let field = view.general.smallScrollPointsFieldForTesting
            field.stringValue = "not-a-number"
            view.general.controlTextDidChange(Notification(
                name: NSControl.textDidChangeNotification,
                object: field
            ))
            #expect(editor.isDirty)
            #expect(!view.applyButtonForTesting.isEnabled)
            view.onApply?()

            #expect(try Data(contentsOf: url) == original)
            #expect(state.generation == 0)
            #expect(view.footerStatusForTesting.stringValue.contains("Small scroll"))
            #expect(editor.isDirty)
        }
    }

    @Test("resetting aliases, sequence timeout, and general values to defaults publishes an empty sparse settings object")
    func defaultResetProducesSparseDefaults() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("settings.json")
            let service = SettingsService(store: SettingsStore(fileURL: url))
            try write(
                SparseAppConfig(
                    keymap: [ActionID.helpShow.rawValue: ["x"]],
                    navigation: SparseNavigationConfiguration(
                        smallScrollPoints: 48,
                        largeScrollViewportFraction: 0.9,
                        zoomFactor: 1.25
                    ),
                    input: SparseInputConfiguration(prefixTimeoutMilliseconds: 750, prefix: "<C-x>")
                ),
                using: service
            )
            let state = CoordinatorState(active: service.load().activeConfig)
            let (window, view, editor) = makeEditor(service: service, state: state)
            defer { window.close() }
            editor.open()

            view.shortcuts.onReset?(ActionID.helpShow.rawValue)
            editor.acceptRecordedSource(BuiltInDefaults.config.input.prefix, for: SettingsCoordinator.prefixRowID)
            setGeneral(
                view,
                smallScrollPoints: "32",
                largeScrollPercent: "80",
                zoomFactor: "1.10"
            )

            view.selectSection(.keyboardShortcuts)
            view.shortcuts.enterFirstRowModeForShell()
            let timeout = view.timeoutFieldForTesting
            #expect(view.shortcuts.selectedRowIDForTesting == "input.prefixTimeout")
            #expect(timeout.stringValue == "750")
            #expect(view.shortcuts.resetSelectedRowForShell())
            #expect(timeout.stringValue == String(BuiltInDefaults.config.input.prefixTimeoutMilliseconds))
            #expect(view.valuesForTesting.prefixTimeoutMilliseconds == String(BuiltInDefaults.config.input.prefixTimeoutMilliseconds))
            #expect(editor.isDirty)
            view.onApply?()
            #expect(service.load().sparse == SparseAppConfig())
            #expect(state.generation == 1)
            #expect(!editor.isDirty)
        }
    }

    @Test("legacy TOML is ignored; a missing settings file is not created until Apply")
    func legacyIgnoredAndMissingApplyCreatesJSON() throws {
        try withTemporaryDirectory { directory in
            let legacyURL = directory.appendingPathComponent("config.toml")
            try Data("[navigation]\nsmall_scroll_points = 99\n".utf8).write(to: legacyURL)
            let url = directory.appendingPathComponent("settings.json")
            let service = SettingsService(store: SettingsStore(fileURL: url))
            let loaded = service.load()
            #expect(loaded.activeConfig.config == BuiltInDefaults.config)
            #expect(loaded.diagnostics.isEmpty)
            #expect(loaded.snapshot?.exists == false)
            #expect(!FileManager.default.fileExists(atPath: url.path))

            let state = CoordinatorState(active: loaded.activeConfig)
            let (window, view, editor) = makeEditor(service: service, state: state)
            defer { window.close() }
            editor.open()
            #expect(!FileManager.default.fileExists(atPath: url.path))
            editor.acceptRecordedSource("z", for: ActionID.viewZoomIn.rawValue)
            #expect(editor.isDirty)
            #expect(!FileManager.default.fileExists(atPath: url.path))

            view.onApply?()
            #expect(FileManager.default.fileExists(atPath: url.path))
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect(object["version"] as? Int == 1)
            let settings = try #require(object["settings"] as? [String: Any])
            let keymap = try #require(settings["keymap"] as? [String: Any])
            #expect(keymap[ActionID.viewZoomIn.rawValue] as? [String] == ["z"])
            #expect(settings["navigation"] == nil)
            #expect(settings["input"] == nil)
            #expect(settings["links"] == nil)
            #expect(state.active.config == service.load().activeConfig.config)
            #expect(state.generation == 1)
        }
    }

    @Test("a stale external settings file is never overwritten")
    func staleConflictDoesNotOverwrite() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("settings.json")
            let service = SettingsService(store: SettingsStore(fileURL: url))
            try write(SparseAppConfig(keymap: [ActionID.helpShow.rawValue: ["x"]]), using: service)
            let state = CoordinatorState(active: service.load().activeConfig)
            let (window, view, editor) = makeEditor(service: service, state: state)
            defer { window.close() }
            editor.open()
            editor.acceptRecordedSource("z", for: ActionID.helpShow.rawValue)

            let external = try service.encode(SparseAppConfig(keymap: [ActionID.helpShow.rawValue: ["external"]]))
            try external.write(to: url, options: .atomic)
            view.onApply?()

            #expect(try Data(contentsOf: url) == external)
            #expect(state.generation == 0)
            #expect(view.footerStatusForTesting.stringValue.contains("nothing was overwritten"))
            #expect(view.reloadButtonForTesting.isEnabled)
            #expect(view.blockedForTesting)
        }
    }

    private func makeEditor(
        service: SettingsService,
        state: CoordinatorState
    ) -> (NSWindow, SettingsOverlayView, SettingsCoordinator) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = SettingsOverlayView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        window.isReleasedWhenClosed = false
        window.contentView = view
        let editor = SettingsCoordinator(
            service: service,
            view: view,
            window: window,
            currentConfig: { state.active },
            currentGeneration: { state.generation },
            install: { next in
                state.active = next
                state.generation += 1
            },
            closePanel: {}
        )
        return (window, view, editor)
    }

    private func setGeneral(
        _ view: SettingsOverlayView,
        smallScrollPoints: String,
        largeScrollPercent: String,
        zoomFactor: String
    ) {
        let fields = [
            (view.general.smallScrollPointsFieldForTesting, smallScrollPoints),
            (view.general.largeScrollPercentFieldForTesting, largeScrollPercent),
            (view.general.zoomFactorFieldForTesting, zoomFactor),
        ]
        for (field, value) in fields {
            field.stringValue = value
            view.general.controlTextDidChange(Notification(
                name: NSControl.textDidChangeNotification,
                object: field
            ))
        }
    }

    private func write(_ source: SparseAppConfig, using service: SettingsService) throws {
        try service.encode(source).write(to: service.store.fileURL)
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

@MainActor
private final class CoordinatorState {
    var active: ValidatedAppConfig
    var generation = 0

    init(active: ValidatedAppConfig) {
        self.active = active
    }
}
