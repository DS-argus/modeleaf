import Foundation
import PDFReaderCore
import Testing

@Suite("Theme selection state persistence")
struct ThemeSelectionStoreTests {
    @Test("Persisting a theme round-trips through the state file")
    func persistThenLoadRoundTrip() throws {
        try withTemporaryStore { store in
            store.persist(.nord)

            #expect(store.loadSelectedTheme() == .nord)
        }
    }

    @Test("A missing state file resolves to the default theme")
    func missingFileReturnsNilAndDefault() throws {
        try withTemporaryStore { store in
            #expect(store.loadSelectedTheme() == nil)
            #expect(store.resolvedTheme() == .catppuccinMocha)
        }
    }

    @Test("Malformed state JSON resolves to the default theme")
    func corruptFileReturnsNilAndDefault() throws {
        try withTemporaryStore { store in
            try FileManager.default.createDirectory(
                at: store.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("not json".utf8).write(to: store.fileURL)

            #expect(store.loadSelectedTheme() == nil)
            #expect(store.resolvedTheme() == .catppuccinMocha)
        }
    }

    @Test("Unknown theme IDs in valid state JSON resolve to the default theme")
    func unknownThemeReturnsNilAndDefault() throws {
        try withTemporaryStore { store in
            try FileManager.default.createDirectory(
                at: store.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("{\"selected_theme\":\"unknown-preset\"}".utf8).write(to: store.fileURL)

            #expect(store.loadSelectedTheme() == nil)
            #expect(store.resolvedTheme() == .catppuccinMocha)
        }
    }

    @Test("Persisting creates a missing parent directory")
    func persistCreatesParentDirectory() throws {
        try withTemporaryStore { store in
            #expect(!FileManager.default.fileExists(atPath: store.fileURL.deletingLastPathComponent().path))

            store.persist(.tokyoNight)

            #expect(FileManager.default.fileExists(atPath: store.fileURL.deletingLastPathComponent().path))
            #expect(store.loadSelectedTheme() == .tokyoNight)
        }
    }

    @Test("Persisting atomically replaces an existing complete state file")
    func persistAtomicallyOverwritesCleanly() throws {
        try withTemporaryStore { store in
            store.persist(.nord)
            store.persist(.gruvboxDark)

            let data = try Data(contentsOf: store.fileURL)
            let state = try JSONDecoder().decode(PersistedState.self, from: data)
            #expect(state.selectedTheme == ThemeID.gruvboxDark.rawValue)
            #expect(store.loadSelectedTheme() == .gruvboxDark)
        }
    }

    private func withTemporaryStore(
        _ body: (ThemeSelectionStore) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThemeSelectionStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(ThemeSelectionStore(fileURL: directory.appendingPathComponent("state/theme.json")))
    }

    private struct PersistedState: Decodable {
        let selectedTheme: String

        enum CodingKeys: String, CodingKey {
            case selectedTheme = "selected_theme"
        }
    }
}
