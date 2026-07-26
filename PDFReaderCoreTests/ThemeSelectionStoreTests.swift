import Foundation
import PDFReaderCore
import Testing

@Suite("Theme selection state persistence")
struct ThemeSelectionStoreTests {
    @Test("Persisting a theme round-trips through the state file")
    func persistThenLoadRoundTrip() throws {
        try withTemporaryStore { store in
            #expect(store.persist(.nord) == .persisted)

            #expect(store.load() == .selected(.nord))
            #expect(store.loadSelectedTheme() == .nord)
        }
    }

    @Test("A missing state file is classified absent and resolves to the default theme")
    func missingFileReturnsAbsentAndDefault() throws {
        try withTemporaryStore { store in
            #expect(store.load() == .absent)
            #expect(store.loadSelectedTheme() == nil)
            #expect(store.resolvedTheme() == .catppuccinMocha)
        }
    }

    @Test("Malformed state JSON is classified invalid and resolves to the default theme")
    func corruptFileReturnsInvalidAndDefault() throws {
        try withTemporaryStore { store in
            try FileManager.default.createDirectory(
                at: store.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("not json".utf8).write(to: store.fileURL)

            #expect(store.load() == .invalid)
            #expect(store.resolvedTheme() == .catppuccinMocha)
        }
    }

    @Test("Unknown theme IDs in valid state JSON are classified invalid and resolve to the default theme")
    func unknownThemeReturnsInvalidAndDefault() throws {
        try withTemporaryStore { store in
            try FileManager.default.createDirectory(
                at: store.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("{\"selected_theme\":\"unknown-preset\"}".utf8).write(to: store.fileURL)

            #expect(store.load() == .invalid)
            #expect(store.resolvedTheme() == .catppuccinMocha)
        }
    }

    @Test("An operational read failure is NOT folded into the silent default")
    func operationalReadFailureIsSurfaced() throws {
        // A directory at the state-file path is an operational fault, not one
        // of the three intended silent cases; load() must report ioError.
        try withTemporaryStore { store in
            try FileManager.default.createDirectory(
                at: store.fileURL, withIntermediateDirectories: true
            )
            guard case .ioError = store.load() else {
                Issue.record("expected ioError for a directory at the state path, got \(store.load())")
                return
            }
            // The app must still launch, so resolvedTheme still defaults.
            #expect(store.resolvedTheme() == .catppuccinMocha)
        }
    }

    @Test("A failed durable write is reported, not treated as a committed selection")
    func persistFailureIsReported() throws {
        try withTemporaryStore { store in
            // Make the parent path a FILE so createDirectory/write cannot succeed.
            let parent = store.fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("blocker".utf8).write(to: parent)   // a file where a directory is needed
            guard case .failed = store.persist(.nord) else {
                Issue.record("expected persist to fail when the parent path is a file")
                return
            }
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
