import AppKit
import Foundation
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("Recent files open overlay integration")
@MainActor
struct RecentFilesOverlayIntegrationTests {
    private func makeController(
        entries: [RecentFileEntry],
        browse: @escaping () -> Void = {},
        open: @escaping (String) -> Void = { _ in }
    ) -> MainWindowController {
        MainWindowController(
            coordinator: PaneCoordinator(initialStore: ReaderSessionStore()),
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { _ in },
            browseHandler: browse,
            recentFilesProvider: { entries },
            recentOpenHandler: open
        )
    }
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-overlay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }


    private func type(_ text: String, into controller: MainWindowController) throws {
        for character in text {
            _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: String(character))))
        }
    }

    @Test("shows Browse first, filters recent filenames, and commits selection")
    func filtersAndCommits() throws {
        let entries = [
            RecentFileEntry(absolutePath: "/documents/alpha.pdf", lastOpenedAt: .now),
            RecentFileEntry(absolutePath: "/documents/beta.pdf", lastOpenedAt: .now),
        ]
        var opened: [String] = []
        let controller = makeController(entries: entries, open: { opened.append($0) })
        defer { controller.close() }

        controller.presentRecentFilesOverlay()
        let overlay = controller.rootView.recentFilesOverlay
        #expect(overlay.visibleRowsForTesting == ["Browse…", "/documents/alpha.pdf", "/documents/beta.pdf"])
        try type("bet", into: controller)
        #expect(overlay.selectedIndexForTesting == 1)
        #expect(overlay.visibleRowsForTesting == ["Browse…", "/documents/beta.pdf"])
        _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36)))
        #expect(opened == ["/documents/beta.pdf"])
        #expect(overlay.isHidden)
    }

    @Test("the fifteenth recent row remains reachable and commits its path")
    func fifteenthRecentRowCommits() throws {
        let entries = (0..<RecentFilesStore.maximumEntries).map {
            RecentFileEntry(absolutePath: "/documents/\($0).pdf", lastOpenedAt: .now)
        }
        var opened: [String] = []
        let controller = makeController(entries: entries, open: { opened.append($0) })
        defer { controller.close() }

        controller.presentRecentFilesOverlay()
        for _ in 0..<RecentFilesStore.maximumEntries {
            _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "j", modifiers: [.control])))
        }
        #expect(controller.rootView.recentFilesOverlay.selectedIndexForTesting == RecentFilesStore.maximumEntries)
        _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36)))
        #expect(opened == ["/documents/14.pdf"])
    }

    @Test("control navigation, Browse, escape, and palette replacement")
    func modalKeysAndReplacement() throws {
        let entries = [RecentFileEntry(absolutePath: "/documents/alpha.pdf", lastOpenedAt: .now)]
        var browseCount = 0
        let controller = makeController(entries: entries, browse: { browseCount += 1 })
        defer { controller.close() }

        controller.presentRecentFilesOverlay()
        _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "j", modifiers: [.control])))
        #expect(controller.rootView.recentFilesOverlay.selectedIndexForTesting == 1)
        _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "k", modifiers: [.control])))
        #expect(controller.rootView.recentFilesOverlay.selectedIndexForTesting == 0)
        _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36)))
        #expect(browseCount == 1)

        controller.presentCommandPalette()
        controller.presentRecentFilesOverlay()
        #expect(controller.rootView.commandPaletteOverlay.isHidden)
        _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "", keyCode: 53)))
        #expect(controller.rootView.recentFilesOverlay.isHidden)
    }
}
