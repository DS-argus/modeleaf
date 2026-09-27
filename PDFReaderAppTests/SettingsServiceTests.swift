import Foundation
import PDFReaderCore
import PDFReaderTestSupport
@testable import PDFReaderApp
import Testing

@Suite("Settings service")
struct SettingsServiceTests {
    @Test("missing settings use defaults and do not create a file")
    func missingLoad() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("settings.json")
            let result = SettingsService(store: SettingsStore(fileURL: url)).load()
            #expect(result.activeConfig.config == BuiltInDefaults.config)
            #expect(result.sparse == SparseAppConfig())
            #expect(result.snapshot?.exists == false)
            #expect(result.diagnostics.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("legacy TOML is ignored by the JSON service")
    func oldTOMLIgnored() throws {
        try withTemporaryDirectory { directory in
            try Data("not valid TOML or JSON".utf8)
                .write(to: directory.appendingPathComponent("config.toml"))
            let url = directory.appendingPathComponent("settings.json")
            let result = SettingsService(store: SettingsStore(fileURL: url)).load()
            #expect(result.activeConfig.config == BuiltInDefaults.config)
            #expect(result.diagnostics.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("zero-default encoding contains only the version wrapper")
    func zeroDefaultSerialization() throws {
        try withTemporaryDirectory { directory in
            let service = SettingsService(store: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")))
            let data = try service.encode(SparseAppConfig())
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["version"] as? Int == 1)
            let settings = try #require(object["settings"] as? [String: Any])
            #expect(settings.isEmpty)
        }
    }

    @Test("explicit empty aliases survive delta serialization")
    func explicitEmptyAliases() throws {
        try withTemporaryDirectory { directory in
            let service = SettingsService(store: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")))
            let source = SparseAppConfig(keymap: [ActionID.scrollDown.rawValue: []])
            let data = try service.encode(source)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let settings = try #require(object["settings"] as? [String: Any])
            let keymap = try #require(settings["keymap"] as? [String: Any])
            #expect((keymap[ActionID.scrollDown.rawValue] as? [String]) == [])
        }
    }

    @Test("foundation aliases are omitted when the editable template is unchanged")
    func foundationAliasesAreRemoved() throws {
        try withTemporaryDirectory { directory in
            let service = SettingsService(store: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")))
            let source = SparseAppConfig(keymap: [ActionID.scrollDown.rawValue: ["<Down>", "j"]])
            let data = try service.encode(source)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let settings = try #require(object["settings"] as? [String: Any])
            #expect(settings["keymap"] == nil)
        }
    }

    @Test("general fields and key aliases round-trip through the schema")
    func generalRoundTrip() throws {
        try withTemporaryDirectory { directory in
            let service = SettingsService(store: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")))
            let source = SparseAppConfig(
                keymap: [ActionID.documentOpen.rawValue: ["<D-F12>"]],
                navigation: SparseNavigationConfiguration(
                    smallScrollPoints: 48,
                    largeScrollViewportFraction: 0.9,
                    zoomFactor: 1.25
                ),
                input: SparseInputConfiguration(prefixTimeoutMilliseconds: 750, prefix: "<C-x>"),
                links: SparseLinksConfiguration(skipExternalLinkHintConfirmation: true)
            )
            let data = try service.encode(source)
            let report = service.validate(data: data)
            #expect(report.isValid)
            let sparse = try #require(report.sparse)
            #expect(sparse == source)
            #expect(report.validatedConfig?.config.navigation.smallScrollPoints == 48)
            #expect(report.validatedConfig?.config.input.prefix == "<C-x>")
            #expect(report.validatedConfig?.config.links.skipExternalLinkHintConfirmation == true)
            #expect(report.validatedConfig?.config.keymap[.documentOpen]?.count == 1)
        }
    }

    @Test("unknown fields, corrupt JSON, and truncated JSON are blocked")
    func malformedInputs() throws {
        try withTemporaryDirectory { directory in
            let service = SettingsService(store: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")))
            let unknown = Data(#"{"version":1,"settings":{"unknown":true}}"#.utf8)
            let unknownReport = service.validate(data: unknown)
            #expect(!unknownReport.isValid)
            #expect(unknownReport.errors.contains { $0.code == .unknownKey })

            let corruptReport = service.validate(data: Data("{not-json}".utf8))
            #expect(!corruptReport.isValid)
            let truncatedReport = service.validate(data: Data(#"{"version":1,"settings":{"input":}"#.utf8))
            #expect(!truncatedReport.isValid)
        }
    }

    @Test("invalid UTF-8, unsupported versions, and oversized input are rejected")
    func schemaBoundaries() throws {
        try withTemporaryDirectory { directory in
            let service = SettingsService(store: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")))
            let invalidUTF8 = service.validate(data: Data([0xFF, 0xFE]))
            #expect(invalidUTF8.errors.contains { $0.code == .invalidUTF8 })

            let unsupported = service.validate(data: Data(#"{"version":2,"settings":{}}"#.utf8))
            #expect(!unsupported.isValid)
            #expect(unsupported.errors.contains { $0.semanticPath == "version" })

            let oversized = service.validate(data: Data(repeating: 0x20, count: ConfigLimits.maximumBytes + 1))
            #expect(oversized.errors.contains { $0.code == .inputTooLarge })
        }
    }

    @Test("a corrupt file remains untouched and activates built-in defaults")
    func corruptLoadDoesNotRewrite() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("settings.json")
            let bytes = Data(#"{"version":1,"settings":{"navigation":{"zoom_factor":"bad"}}}"#.utf8)
            try bytes.write(to: url)
            let result = SettingsService(store: SettingsStore(fileURL: url)).load()
            #expect(result.activeConfig.config == BuiltInDefaults.config)
            #expect(!result.diagnostics.isEmpty)
            #expect(result.snapshot?.exists == true)
            #expect(try Data(contentsOf: url) == bytes)
        }
    }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}
