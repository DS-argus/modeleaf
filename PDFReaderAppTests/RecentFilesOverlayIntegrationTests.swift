import AppKit
import Foundation
import PDFReaderCore
import PDFReaderTestSupport
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
    private func makeMutableController(
        provider: @escaping () -> [RecentFileEntry],
        prune: @escaping (String) -> RecentFilesPersist = { _ in .persisted },
        clear: @escaping () -> RecentFilesPersist = { .persisted },
        open: @escaping (String) -> Void = { _ in }
    ) -> MainWindowController {
        MainWindowController(
            coordinator: PaneCoordinator(initialStore: ReaderSessionStore()),
            theme: AppKitTheme(themeID: .tokyoNight),
            actionHandler: { _ in },
            browseHandler: {},
            recentFilesProvider: provider,
            recentOpenHandler: open,
            recentPruneHandler: prune,
            recentClearHandler: clear
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
        try withTemporaryDirectory { directory in
            let alpha = directory.appendingPathComponent("alpha.pdf")
            let beta = directory.appendingPathComponent("beta.pdf")
            try Data().write(to: alpha)
            try Data().write(to: beta)
            let entries = [
                RecentFileEntry(absolutePath: alpha.path, lastOpenedAt: .now),
                RecentFileEntry(absolutePath: beta.path, lastOpenedAt: .now),
            ]
            var opened: [String] = []
            let controller = makeController(entries: entries, open: { opened.append($0) })
            defer { controller.close() }

            controller.presentRecentFilesOverlay()
            let overlay = controller.rootView.recentFilesOverlay
            #expect(overlay.visibleRowsForTesting == ["Browse\u{2026}", alpha.path, beta.path])
            try type("bet", into: controller)
            #expect(overlay.selectedIndexForTesting == 1)
            #expect(overlay.visibleRowsForTesting == ["Browse\u{2026}", beta.path])
            _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36)))
            #expect(opened == [beta.path])
            #expect(overlay.isHidden)
        }
    }

    @Test("the fifteenth recent row remains reachable and commits its path")
    func fifteenthRecentRowCommits() throws {
        try withTemporaryDirectory { directory in
            let urls: [URL] = try (0..<RecentFilesStore.maximumEntries).map { index in
                let url = directory.appendingPathComponent("\(index).pdf")
                try Data().write(to: url)
                return url
            }
            let entries = urls.map { RecentFileEntry(absolutePath: $0.path, lastOpenedAt: .now) }
            var opened: [String] = []
            let controller = makeController(entries: entries, open: { opened.append($0) })
            defer { controller.close() }

            controller.presentRecentFilesOverlay()
            for _ in 0..<RecentFilesStore.maximumEntries {
                _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "j", modifiers: [.control])))
            }
            #expect(controller.rootView.recentFilesOverlay.selectedIndexForTesting == RecentFilesStore.maximumEntries)
            _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36)))
            #expect(opened == [urls[RecentFilesStore.maximumEntries - 1].path])
        }
    }

    @Test("control navigation, Browse, escape, and palette replacement")
    func modalKeysAndReplacement() throws {
        try withTemporaryDirectory { directory in
            let alpha = directory.appendingPathComponent("alpha.pdf")
            try Data().write(to: alpha)
            let entries = [RecentFileEntry(absolutePath: alpha.path, lastOpenedAt: .now)]
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

    @Test("a missing recent file shows an inline error, prunes, and keeps the overlay open")
    func missingFilePrunesWithInlineError() throws {
        try withTemporaryDirectory { directory in
            let real = directory.appendingPathComponent("real.pdf")
            try Data().write(to: real)
            let missing = directory.appendingPathComponent("gone.pdf")
            var entries = [
                RecentFileEntry(absolutePath: missing.path, lastOpenedAt: .now),
                RecentFileEntry(absolutePath: real.path, lastOpenedAt: .now),
            ]
            var opened: [String] = []
            let controller = makeMutableController(
                provider: { entries },
                prune: { path in
                    entries.removeAll { $0.absolutePath == path }
                    return .persisted
                },
                open: { opened.append($0) }
            )
            defer { controller.close() }

            controller.presentRecentFilesOverlay()
            let overlay = controller.rootView.recentFilesOverlay
            _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "j", modifiers: [.control])))
            _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36)))
            #expect(overlay.inlineErrorForTesting?.contains("gone.pdf") == true)
            #expect(!overlay.isHidden)
            #expect(opened.isEmpty)
            #expect(overlay.visibleRowsForTesting == ["Browse\u{2026}", real.path])
        }
    }

    @Test("a directory entry is retained with an inline reason")
    func directoryEntryRetained() throws {
        try withTemporaryDirectory { directory in
            let folder = directory.appendingPathComponent("folder.pdf", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var pruned: [String] = []
            let entries = [RecentFileEntry(absolutePath: folder.path, lastOpenedAt: .now)]
            let controller = makeMutableController(
                provider: { entries },
                prune: { path in
                    pruned.append(path)
                    return .persisted
                }
            )
            defer { controller.close() }

            controller.presentRecentFilesOverlay()
            let overlay = controller.rootView.recentFilesOverlay
            _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "j", modifiers: [.control])))
            _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36)))
            #expect(overlay.inlineErrorForTesting != nil)
            #expect(pruned.isEmpty)
            #expect(overlay.visibleRowsForTesting == ["Browse\u{2026}", folder.path])
            #expect(!overlay.isHidden)
        }
    }

    @Test("Ctrl+c clears the list immediately and keeps only Browse")
    func ctrlCClears() throws {
        var entries = [RecentFileEntry(absolutePath: "/tmp/a.pdf", lastOpenedAt: .now)]
        let controller = makeMutableController(
            provider: { entries },
            clear: {
                entries = []
                return .persisted
            }
        )
        defer { controller.close() }

        controller.presentRecentFilesOverlay()
        let overlay = controller.rootView.recentFilesOverlay
        #expect(overlay.visibleRowsForTesting.count == 2)
        _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "c", modifiers: [.control])))
        #expect(overlay.visibleRowsForTesting == ["Browse\u{2026}"])
        #expect(!overlay.isHidden)
    }

    @Test("the key hint is always visible and duplicate filenames stay distinguishable by path")
    func hintAndDuplicateNames() throws {
        try withTemporaryDirectory { directory in
            let first = directory.appendingPathComponent("one", isDirectory: true).appendingPathComponent("report.pdf")
            let second = directory.appendingPathComponent("two", isDirectory: true).appendingPathComponent("report.pdf")
            for url in [first, second] {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: url)
            }
            let entries = [
                RecentFileEntry(absolutePath: first.path, lastOpenedAt: .now),
                RecentFileEntry(absolutePath: second.path, lastOpenedAt: .now),
            ]
            let controller = makeController(entries: entries)
            defer { controller.close() }

            controller.presentRecentFilesOverlay()
            let overlay = controller.rootView.recentFilesOverlay
            #expect(overlay.keyHintForTesting.contains("Ctrl+j/k"))
            #expect(overlay.keyHintForTesting.contains("Ctrl+c"))
            #expect(overlay.visibleRowsForTesting == ["Browse\u{2026}", first.path, second.path])
        }
    }

    @Test("empty recents show only Browse plus the key hint")
    func emptyRecents() throws {
        let controller = makeController(entries: [])
        defer { controller.close() }
        controller.presentRecentFilesOverlay()
        let overlay = controller.rootView.recentFilesOverlay
        #expect(overlay.visibleRowsForTesting == ["Browse\u{2026}"])
        #expect(!overlay.keyHintForTesting.isEmpty)
    }

    @Test("directory-backed state stores surface prune and clear write failures")
    func persistFailuresSurfaceInline() throws {
        try withTemporaryDirectory { directory in
            let missing = directory.appendingPathComponent("gone.pdf")
            let entries = [RecentFileEntry(absolutePath: missing.path, lastOpenedAt: .now)]
            let controller = makeMutableController(
                provider: { entries },
                prune: { _ in .failed(message: "lock timeout") },
                clear: { .failed(message: "lock timeout") }
            )
            defer { controller.close() }

            controller.presentRecentFilesOverlay()
            let overlay = controller.rootView.recentFilesOverlay
            _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "j", modifiers: [.control])))
            _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36)))
            #expect(overlay.inlineErrorForTesting?.contains("목록 저장 실패") == true)
            // A failed prune must not silently drop the row from the provider-backed list.
            #expect(overlay.visibleRowsForTesting == ["Browse\u{2026}", missing.path])
            _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "c", modifiers: [.control])))
            #expect(overlay.inlineErrorForTesting?.contains("목록 저장 실패") == true)
            #expect(!overlay.isHidden)
        }
    }

    @Test("small windows bound the recent list while keeping selected rows and hint visible")
    func boundedScrollListInSmallWindow() throws {
        let entries = (0..<RecentFilesStore.maximumEntries).map {
            RecentFileEntry(absolutePath: "/tmp/\($0).pdf", lastOpenedAt: .now)
        }
        let controller = makeController(entries: entries)
        defer { controller.close() }
        controller.window?.setContentSize(NSSize(width: 480, height: 360))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.presentRecentFilesOverlay()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<RecentFilesStore.maximumEntries {
            _ = controller.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "j", modifiers: [.control])))
        }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let overlay = controller.rootView.recentFilesOverlay
        #expect(controller.rootView.recentFilesOverlayIsWithinContentBoundsForTesting)
        #expect(overlay.selectedRowIsVisibleForTesting)
        #expect(overlay.keyHintIsWithinBoundsForTesting)
    }
}
