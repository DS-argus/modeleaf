import AppKit
import Foundation
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("Config write and reset integration")
@MainActor
struct ConfigWriteResetIntegrationTests {
    @Test("write creates the default file and reset installs the prepared default generation with a backup")
    func writeThenReset() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("config.toml")
            let controller = makeController(configURL: url, stateDirectory: directory)
            controller.start()
            defer { controller.mainWindowController.close() }

            controller.writeDefaultConfig()
            #expect(try String(contentsOf: url, encoding: .utf8) == BuiltInDefaults.defaultConfigTOML)
            #expect(controller.mainWindowController.rootView.statusBar.presentation.detail == "Default config written")

            try customConfig.write(to: url, atomically: true, encoding: .utf8)
            let customController = makeController(configURL: url, stateDirectory: directory)
            customController.start()
            defer { customController.mainWindowController.close() }
            #expect(customController.mainWindowController.resolvedConfig.keymap.bindings(for: .viewZoomIn).map(\.description) == ["z"])

            customController.resetConfig()
            #expect(try String(contentsOf: url, encoding: .utf8) == BuiltInDefaults.defaultConfigTOML)
            #expect(try String(contentsOf: url.appendingPathExtension("bak"), encoding: .utf8) == customConfig)
            #expect(customController.mainWindowController.resolvedConfig.keymap.bindings(for: .viewZoomIn) == BuiltInDefaults.keymap[.viewZoomIn])
            #expect(customController.mainWindowController.rootView.statusBar.presentation.detail == "Config reset to defaults")

            let installsBeforeNoOp = customController.configInstallGenerationCountForTesting
            customController.resetConfig()
            #expect(customController.configInstallGenerationCountForTesting == installsBeforeNoOp)
            #expect(customController.mainWindowController.rootView.statusBar.presentation.detail == "Config already matches defaults")
        }
    }

    @Test("unchanged reset installs defaults and clears a pinned stale runtime generation")
    func unchangedResetRepairsPinnedRuntime() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("config.toml")
            try customConfig.write(to: url, atomically: true, encoding: .utf8)
            let controller = makeController(configURL: url, stateDirectory: directory)
            controller.start()
            defer { controller.mainWindowController.close() }

            try "[keymap\n".write(to: url, atomically: true, encoding: .utf8)
            controller.reloadConfig()
            #expect(controller.mainWindowController.hasPinnedDiagnostic)
            #expect(controller.mainWindowController.resolvedConfig.keymap.bindings(for: .viewZoomIn).map(\.description) == ["z"])

            try BuiltInDefaults.defaultConfigTOML.write(to: url, atomically: true, encoding: .utf8)
            let installsBeforeReset = controller.configInstallGenerationCountForTesting
            controller.resetConfig()

            #expect(controller.configInstallGenerationCountForTesting == installsBeforeReset + 1)
            #expect(!controller.mainWindowController.hasPinnedDiagnostic)
            #expect(controller.mainWindowController.resolvedConfig.keymap.bindings(for: .viewZoomIn) == BuiltInDefaults.keymap[.viewZoomIn])
            #expect(controller.mainWindowController.rootView.statusBar.presentation.detail == "Config already matches defaults")
        }
    }

    private var customConfig: String {
        """
        [keymap]
        "view.zoomIn" = ["z"]
        """
    }

    private func makeController(configURL: URL, stateDirectory: URL) -> ApplicationController {
        ApplicationController(
            application: NSApplication.shared,
            configService: ConfigService(source: ConfigFileSource(url: configURL)),
            themeStore: ThemeSelectionStore(fileURL: stateDirectory.appendingPathComponent("theme-state.json")),
            recentFilesStore: RecentFilesStore(fileURL: stateDirectory.appendingPathComponent("recent-state.json")),
            terminationHandler: {}
        )
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-write-reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}
