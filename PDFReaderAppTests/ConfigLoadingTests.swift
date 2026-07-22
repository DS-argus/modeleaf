import Foundation
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("Strict TOML adapter and atomic activation")
struct ConfigLoadingTests {
    @Test("U-CFG-01 missing deterministic path activates embedded defaults without creating a file")
    func missingFileUsesEmbeddedDefaults() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url = ConfigFileSource.defaultURL(homeDirectory: temporary)

        #expect(url.path == temporary.appendingPathComponent(".config/pdf-reader/config.toml").path)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let result = ConfigService(
            source: ConfigFileSource(url: url),
            decoder: UnexpectedDecoder()
        ).load()

        #expect(result.origin == .builtInMissingFile)
        #expect(!result.usedFallback)
        #expect(result.diagnostics.isEmpty)
        #expect(result.activeConfig.config == BuiltInDefaults.config)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    @Test("U-CFG-02 recursive schema walk rejects unknown leaves, arrays, and empty nodes")
    func recursiveUnknownLeavesAreRejected() {
        let source = """
        [extensions]
        empty = []
        nested = [{ name = "one", children = [{ shell = "echo no" }] }]

        [orphan]
        """
        let report = decode(source)
        let paths = Set(report.diagnostics.filter { $0.code == .unknownKey }.map(\.semanticPath))

        #expect(report.document != nil, "Unknown keys should not prevent sparse decoding of known data")
        #expect(!report.isValid)
        #expect(
            paths
                == [
                    "extensions.empty",
                    "extensions.nested[0].name",
                    "extensions.nested[0].children[0].shell",
                    "orphan",
                ]
        )
    }

    @Test("U-CFG-02 valid TOML arrays-of-tables are walked by occurrence rather than misdiagnosed as duplicates")
    func arrayTablesAreRecursivelyIndexed() {
        let source = """
        [[plugins]]
        name = "one"

        [[plugins]]
        name = "two"
        """
        let report = decode(source)

        #expect(!report.diagnostics.contains { $0.code == .duplicateKey })
        #expect(
            Set(report.diagnostics.map(\.semanticPath))
                == ["plugins[0].name", "plugins[1].name"]
        )
    }

    @Test("U-CFG-04 malformed TOML and duplicate keys preserve source diagnostics")
    func syntaxAndDuplicateDiagnostics() {
        let malformed = decode(
            """
            [theme
            built_in = "nord"
            """,
            path: "/tmp/malformed.toml"
        )
        let syntax = malformed.diagnostics.first
        #expect(syntax?.code == .invalidSyntax)
        #expect(syntax?.semanticPath == "$")
        #expect(syntax?.sourcePath == "/tmp/malformed.toml")
        #expect(syntax?.line == 1)

        let duplicate = decode(
            """
            [navigation]
            zoom_factor = 1.1
            zoom_factor = 1.2
            """,
            path: "/tmp/duplicate.toml"
        )
        #expect(
            duplicate.diagnostics
                == [
                    ConfigDiagnostic(
                        severity: .error,
                        code: .duplicateKey,
                        message: "Duplicate key; first defined at line 2.",
                        semanticPath: "navigation.zoom_factor",
                        sourcePath: "/tmp/duplicate.toml",
                        line: 3
                    ),
                ]
        )
    }

    @Test("U-CFG-07 decoder rejects oversized, invalid UTF-8, and mistyped input before activation")
    func decoderBoundaryAndTypes() {
        let oversized = TOMLConfigDecoder().decode(
            Data(repeating: 0x20, count: ConfigLimits.maximumBytes + 1),
            sourcePath: "/tmp/large.toml"
        )
        #expect(oversized.diagnostics.map(\.code) == [.inputTooLarge])

        let invalidUTF8 = TOMLConfigDecoder().decode(
            Data([0xFF, 0xFE]),
            sourcePath: "/tmp/invalid.toml"
        )
        #expect(invalidUTF8.diagnostics.map(\.code) == [.invalidUTF8])

        let mistyped = decode(
            """
            [input]
            prefix_timeout_ms = "slow"
            """
        )
        #expect(!mistyped.isValid)
        #expect(mistyped.diagnostics.contains { diagnostic in
            diagnostic.code == .invalidType
                && diagnostic.semanticPath == "input.prefix_timeout_ms"
                && diagnostic.line == 2
        })
    }

    @Test("U-CFG-08 executable extension surfaces are data-only schema errors")
    func executableSurfacesAreAbsent() throws {
        let source = """
        [scripts]
        launch = "open"
        [shell]
        command = "rm -rf"
        [plugins.reader]
        hook = "on_open"
        [user_action]
        macro = ["j", "j"]
        """
        let report = decode(source)

        #expect(!report.isValid)
        #expect(Set(report.diagnostics.map(\.semanticPath)) == [
            "plugins.reader.hook",
            "scripts.launch",
            "shell.command",
            "user_action.macro[0]",
            "user_action.macro[1]",
        ])
        #expect(report.diagnostics.allSatisfy { diagnostic in
            diagnostic.code == .unknownKey
                && diagnostic.message.contains("data only")
        })

        let root = repositoryRoot()
        let productionConfigSources = [
            "PDFReaderCore/Config/ConfigDecoder.swift",
            "PDFReaderCore/Config/SparseAppConfig.swift",
            "PDFReaderCore/Config/ConfigValidator.swift",
            "PDFReaderApp/Config/TOMLConfigDecoder.swift",
            "PDFReaderApp/Config/ConfigService.swift",
        ]
        let forbiddenExecutionAPIs = ["Process(", "NSTask", "NSAppleScript", "popen(", "system(", "JavaScriptCore"]
        for relativePath in productionConfigSources {
            let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            for forbidden in forbiddenExecutionAPIs {
                #expect(!text.contains(forbidden), "\(relativePath) contains executable surface \(forbidden)")
            }
        }
    }

    @Test("U-CFG-09 any mixed decoder or semantic error falls back atomically with aggregated diagnostics")
    func invalidMixedFileFallsBackCompletely() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url = temporary.appendingPathComponent("config.toml")
        try Data(
            """
            [navigation]
            small_scroll_points = 96
            zoom_factor = 9

            [theme]
            built_in = "nord"

            [keymap]
            "scroll.down" = ["x"]
            "bookmark.toggle" = ["b"]

            [scripts]
            launch = "never"
            """.utf8
        ).write(to: url)

        let result = ConfigService(source: ConfigFileSource(url: url)).load()
        let codes = Set(result.diagnostics.map(\.code))

        #expect(result.origin == .builtInFallback)
        #expect(result.usedFallback)
        #expect(codes.isSuperset(of: [.unknownKey, .valueOutOfRange, .unknownAction]))
        #expect(result.activeConfig.config == BuiltInDefaults.config)
        #expect(result.activeConfig.keymap.bindings(for: .scrollDown) == BuiltInDefaults.keymap[.scrollDown])
        #expect(result.activeConfig.config.navigation.smallScrollPoints == 48)
        #expect(result.activeConfig.config.theme.builtIn == .catppuccinMocha)
    }

    @Test("U-CFG-03 valid partial user config activates only after complete validation")
    func validPartialFileActivates() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url = temporary.appendingPathComponent("config.toml")
        try Data(
            """
            [navigation]
            small_scroll_points = 64

            [keymap]
            "scroll.down" = ["x"]

            [theme]
            built_in = "tokyo-night"
            """.utf8
        ).write(to: url)

        let result = ConfigService(source: ConfigFileSource(url: url)).load()

        #expect(result.origin == .userFile)
        #expect(!result.usedFallback)
        #expect(result.diagnostics.isEmpty)
        #expect(result.activeConfig.config.navigation.smallScrollPoints == 64)
        #expect(
            result.activeConfig.config.navigation.largeScrollViewportFraction
                == BuiltInDefaults.config.navigation.largeScrollViewportFraction
        )
        #expect(result.activeConfig.config.theme.builtIn == .tokyoNight)
        #expect(result.activeConfig.keymap.bindings(for: .scrollDown).map(\.description) == ["x"])
    }

    @Test("U-CFG-10 generated default TOML round-trips to the sole runtime default")
    func generatedDefaultsRoundTrip() throws {
        let decoded = TOMLConfigDecoder().decode(
            Data(BuiltInDefaults.defaultConfigTOML.utf8),
            sourcePath: "DefaultConfig.toml"
        )
        let document = try #require(decoded.document)
        let validation = ConfigValidator.validate(document.sparseConfig, source: document.source)
        let active = try #require(validation.validatedConfig)

        #expect(decoded.isValid)
        #expect(validation.isValid)
        #expect(active.config == BuiltInDefaults.config)
        #expect(active.keymap.bindings == BuiltInDefaults.keymap)

        let serviceSource = try String(
            contentsOf: repositoryRoot().appendingPathComponent("PDFReaderApp/Config/ConfigService.swift"),
            encoding: .utf8
        )
        #expect(!serviceSource.contains("DefaultConfig.toml"))
        #expect(!serviceSource.contains("Bundle"))
    }

    @Test("U-CFG-11 production adapter preserves the qualified parser boundary")
    func productionParserQualification() throws {
        let representative = decode(
            """
            [navigation]
            small_scroll_points = 72.5
            large_scroll_viewport_fraction = 1
            zoom_factor = 1.25

            [input]
            prefix_timeout_ms = 750

            [theme]
            built_in = "gruvbox-dark"

            [theme.overrides]
            accent = "#AABBCC"

            [keymap]
            "page.first" = ["gg", "<D-F12>"]
            """
        )
        let document = try #require(representative.document)
        let validation = ConfigValidator.validate(document.sparseConfig, source: document.source)

        #expect(representative.isValid)
        #expect(validation.isValid)
        #expect(validation.validatedConfig?.config.input.prefixTimeoutMilliseconds == 750)
        #expect(validation.validatedConfig?.config.theme.builtIn == .gruvboxDark)
        #expect(validation.validatedConfig?.config.theme.overrides[.accent]?.rawValue == "#AABBCC")
    }

    @Test("U-CFG-12 SwiftPM and Xcode workspace lock TOMLDecoder exactly to 0.4.5")
    func dependencyPinIsExact() throws {
        let root = repositoryRoot()
        let resolvedPaths = [
            "Package.resolved",
            "PDFReader.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
        ]

        for path in resolvedPaths {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let pins = try #require(object["pins"] as? [[String: Any]])
            let pin = try #require(pins.first { ($0["identity"] as? String) == "tomldecoder" })
            let state = try #require(pin["state"] as? [String: Any])

            #expect(state["version"] as? String == "0.4.5")
            #expect(state["revision"] as? String == "a2bbd2796fe3064e107de18cb56031052c4fa899")
        }
    }

    @Test("file read errors and size failures also activate complete built-ins")
    func fileReadFailuresUseAtomicFallback() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }

        let directoryAtConfigPath = temporary.appendingPathComponent("directory.toml", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryAtConfigPath, withIntermediateDirectories: true)
        let directoryResult = ConfigService(source: ConfigFileSource(url: directoryAtConfigPath)).load()
        #expect(directoryResult.origin == .builtInFallback)
        #expect(directoryResult.diagnostics.map(\.code) == [.fileReadFailed])
        #expect(directoryResult.activeConfig.config == BuiltInDefaults.config)

        let oversizedURL = temporary.appendingPathComponent("large.toml")
        try Data(repeating: 0x20, count: ConfigLimits.maximumBytes + 1).write(to: oversizedURL)
        let oversizedResult = ConfigService(source: ConfigFileSource(url: oversizedURL)).load()
        #expect(oversizedResult.origin == .builtInFallback)
        #expect(oversizedResult.diagnostics.map(\.code) == [.inputTooLarge])
        #expect(oversizedResult.activeConfig.config == BuiltInDefaults.config)
    }

    private func decode(_ source: String, path: String = "/tmp/config.toml") -> ConfigDecodeReport {
        TOMLConfigDecoder().decode(Data(source.utf8), sourcePath: path)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-reader-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct UnexpectedDecoder: ConfigDecoding {
    func decode(_ data: Data, sourcePath: String) -> ConfigDecodeReport {
        ConfigDecodeReport(
            document: nil,
            diagnostics: [
                ConfigDiagnostic(
                    severity: .error,
                    code: .internalInvariant,
                    message: "Decoder must not run for a missing file.",
                    semanticPath: "$",
                    sourcePath: sourcePath
                ),
            ]
        )
    }
}
