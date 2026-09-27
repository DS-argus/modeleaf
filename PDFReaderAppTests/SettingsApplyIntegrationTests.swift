import AppKit
import Foundation
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("Settings Apply integration", .serialized)
@MainActor
struct SettingsApplyIntegrationTests {
    @Test("Apply installs one prepared settings generation across navigation, menu, help, and key routing")
    func applyInstallsPreparedGeneration() throws {
        try withTemporaryDirectory { directory in
            let settingsURL = directory.appendingPathComponent("settings.json")
            let service = SettingsService(store: SettingsStore(fileURL: settingsURL))
            try service.encode(SparseAppConfig(
                keymap: [ActionID.viewZoomIn.rawValue: ["z"]]
            )).write(to: settingsURL)

            let store = ReaderSessionStore()
            let session = SettingsApplyRecordingSession(title: "settings.pdf")
            #expect(store.insert(session))
            let controller = makeController(service: service, store: store, directory: directory)
            controller.start()
            defer { controller.mainWindowController.close() }

            let before = controller.coordinator.snapshot
            #expect(controller.mainWindowController.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "z"))))
            #expect(session.zoomFactors == [1.1])

            controller.presentSettings()
            let overlay = controller.mainWindowController.rootView.settingsOverlay
            #expect(!overlay.isHidden)
            #expect(overlay.shortcuts.currentTextForTesting(rowID: ActionID.viewZoomIn.rawValue) == "z")

            let smallScroll = overlay.general.smallScrollPointsFieldForTesting
            smallScroll.stringValue = "64"
            overlay.general.controlTextDidChange(Notification(
                name: NSControl.textDidChangeNotification,
                object: smallScroll
            ))
            overlay.selectSection(.keyboardShortcuts)
            overlay.shortcuts.onReset?(ActionID.viewZoomIn.rawValue)
            #expect(overlay.shortcuts.currentTextForTesting(rowID: ActionID.viewZoomIn.rawValue) == "=")
            overlay.selectSection(.general)
            #expect(overlay.general.valuesForTesting.smallScrollPoints == "64")
            #expect(overlay.isDirtyForTesting)

            overlay.onApply?()

            #expect(controller.configInstallGenerationCountForTesting == 1)
            #expect(controller.configInstallStepsForTesting == [
                .dismissTransientOverlays,
                .applyWindowConfig,
                .updateNavigation,
                .installMenu,
                .activateConfig,
            ])
            #expect(!overlay.isDirtyForTesting)
            #expect(controller.coordinator.snapshot.layout == before.layout)
            #expect(controller.coordinator.snapshot.tabs == before.tabs)
            #expect(controller.coordinator.snapshot.activeID == before.activeID)
            #expect(controller.mainWindowController.resolvedConfig.config.navigation.smallScrollPoints == 64)
            #expect(service.load().sparse.keymap == nil)
            #expect(service.load().sparse.navigation == SparseNavigationConfiguration(smallScrollPoints: 64))

            controller.mainWindowController.dismissSettingsPanel()
            #expect(controller.mainWindowController.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "="))))
            #expect(session.zoomFactors == [1.1, 1.1])
            controller.dispatch(.scrollDown)
            #expect(session.verticalPointScrolls == [64])

            #expect(menuItem(identifier: "menu.view.zoom-in", in: NSApp.mainMenu)?.keyEquivalent == "")
            controller.mainWindowController.presentHelp()
            #expect(controller.mainWindowController.rootView.helpOverlay.visibleEntriesForTesting.contains {
                $0.0 == "=" && $0.1 == "Zoom In"
            })
            controller.mainWindowController.dismissAllTransientOverlays()
        }
    }

    private func makeController(
        service: SettingsService,
        store: ReaderSessionStore,
        directory: URL
    ) -> ApplicationController {
        ApplicationController(
            settingsService: service,
            sessionStore: store,
            themeStore: ThemeSelectionStore(fileURL: directory.appendingPathComponent("theme-state.json")),
            recentFilesStore: RecentFilesStore(fileURL: directory.appendingPathComponent("recent-state.json")),
            terminationHandler: {}
        )
    }

    private func menuItem(identifier: String, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.accessibilityIdentifier() == identifier { return item }
            if let found = menuItem(identifier: identifier, in: item.submenu) { return found }
        }
        return nil
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-apply-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

@MainActor
private final class SettingsApplyRecordingSession: HistoryNeutralTestSessionPresenting {
    let id = TabID()
    let title: String
    let contentView = NSView()
    private(set) var verticalPointScrolls: [Double] = []
    private(set) var zoomFactors: [Double] = []

    init(title: String) { self.title = title }

    var statusSnapshot: ReaderStatusSnapshot {
        ReaderStatusSnapshot(context: "NORMAL", page: "1 / 1", zoom: "100%", detail: title)
    }

    func applyTheme(_ theme: AppKitTheme) {}
    func moveVertically(byPoints points: Double) { verticalPointScrolls.append(points) }
    func moveVertically(byViewportFraction fraction: Double) {}
    func prepareForClose() {}
    func zoom(by factor: Double) { zoomFactors.append(factor) }
}
