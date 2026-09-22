import Foundation
import PDFReaderCore
import Testing

@Suite("Citation preview experimental setting")
struct CitationPreviewSettingsStoreTests {
    @Test("missing and malformed settings default without erasing sibling state")
    func loadBoundaries() throws {
        try withFileURL { fileURL in
            let store = CitationPreviewSettingsStore(fileURL: fileURL)
            #expect(CitationPreviewSettingsStore.productDefault == false)
            #expect(store.load() == .absent)

            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(#"{"citation_preview_enabled":"yes","selected_theme":"dracula"}"#.utf8)
                .write(to: fileURL)
            #expect(store.load() == .invalid)
            #expect(ThemeSelectionStore(fileURL: fileURL).load() == .selected(.dracula))
        }
    }

    @Test("enabled and disabled states persist in the shared state document")
    func roundTrip() throws {
        try withFileURL { fileURL in
            let store = CitationPreviewSettingsStore(fileURL: fileURL)
            #expect(ThemeSelectionStore(fileURL: fileURL).persist(.nord) == .persisted)
            #expect(store.persist(true) == .persisted)
            #expect(store.load() == .selected(true))
            #expect(ThemeSelectionStore(fileURL: fileURL).load() == .selected(.nord))

            #expect(store.persist(false) == .persisted)
            #expect(store.load() == .selected(false))
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
            )
            #expect(object["citation_preview_enabled"] as? Bool == false)
        }
    }

    private func withFileURL(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CitationPreviewSettingsStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("state.json"))
    }
}
