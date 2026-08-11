import Foundation
import PDFReaderCore
import Testing

@Suite("Link destination indicator settings persistence")
struct LinkDestinationIndicatorSettingsStoreTests {
    @Test("absent state uses the product default without writing")
    func absentState() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("state.json")
            let store = LinkDestinationIndicatorSettingsStore(fileURL: url)
            #expect(store.load() == .absent)
            #expect(LinkDestinationIndicatorSettingsStore.productDefault == .standard)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("settings round-trip while preserving theme, recents, and unknown fields")
    func roundTripPreservesSiblingState() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("state.json")
            try Data(
                """
                {
                  "selected_theme": "dracula",
                  "recent_files": [],
                  "future_field": { "enabled": true }
                }
                """.utf8
            ).write(to: url)
            let settings = LinkDestinationIndicatorSettings(
                style: .beacon,
                color: .customHex("#336699"),
                size: 36,
                durationMilliseconds: 2_200
            )
            let store = LinkDestinationIndicatorSettingsStore(fileURL: url)

            #expect(store.persist(settings) == .persisted)
            #expect(store.load() == .selected(settings))

            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect(object["selected_theme"] as? String == "dracula")
            #expect(object["recent_files"] != nil)
            #expect((object["future_field"] as? [String: Any])?["enabled"] as? Bool == true)
            let indicator = try #require(object["link_destination_indicator"] as? [String: Any])
            #expect(indicator["style"] as? String == "beacon")
            #expect(indicator["color"] as? String == "#336699")
            #expect(indicator["size"] as? Double == 36)
            #expect(indicator["duration_ms"] as? Int == 2_200)
        }
    }

    @Test("malformed and out-of-range indicator fields fail closed without masking siblings")
    func invalidState() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("state.json")
            let invalidDocuments = [
                #"{"selected_theme":"dracula","link_destination_indicator":"bad"}"#,
                #"{"link_destination_indicator":{"style":"sparkle","color":"red","size":28,"duration_ms":1500}}"#,
                #"{"link_destination_indicator":{"style":"target","color":"red","size":49,"duration_ms":1500}}"#,
                #"{"link_destination_indicator":{"style":"target","color":"oops","size":28,"duration_ms":1500}}"#,
            ]
            for document in invalidDocuments {
                try Data(document.utf8).write(to: url)
                #expect(LinkDestinationIndicatorSettingsStore(fileURL: url).load() == .invalid)
            }
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("modeleaf-indicator-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
