import Foundation
import PDFReaderCore

private let settingsSchemaVersion = 1

private struct SettingsEnvelope: Codable {
    let version: Int
    let settings: SparseAppConfig

    enum CodingKeys: String, CodingKey {
        case version
        case settings
    }
}

struct SettingsValidationResult: Sendable {
    let sparse: SparseAppConfig?
    let validatedConfig: ValidatedAppConfig?
    let diagnostics: [ConfigDiagnostic]

    var errors: [ConfigDiagnostic] {
        diagnostics.filter { $0.severity == .error }
    }

    var isValid: Bool {
        validatedConfig != nil && errors.isEmpty
    }
}

struct SettingsLoadResult: Sendable {
    let activeConfig: ValidatedAppConfig
    let sparse: SparseAppConfig
    let snapshot: SettingsSnapshot?
    let diagnostics: [ConfigDiagnostic]

    var isValid: Bool {
        !diagnostics.contains { $0.severity == .error }
    }
}

struct SettingsService {
    let store: SettingsStore

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
    }

    func load() -> SettingsLoadResult {
        let snapshot: SettingsSnapshot
        do {
            snapshot = try store.snapshot()
        } catch {
            let diagnostic: ConfigDiagnostic
            if let storeError = error as? SettingsStoreError,
               case let .tooLarge(_, bytes) = storeError {
                diagnostic = sizeDiagnostic(actualBytes: bytes)
            } else {
                diagnostic = fileDiagnostic(error.localizedDescription)
            }
            return SettingsLoadResult(
                activeConfig: builtInConfig(),
                sparse: SparseAppConfig(),
                snapshot: nil,
                diagnostics: [diagnostic]
            )
        }

        guard let data = snapshot.bytes else {
            return SettingsLoadResult(
                activeConfig: builtInConfig(),
                sparse: SparseAppConfig(),
                snapshot: .missing,
                diagnostics: []
            )
        }

        let report = validate(data: data)
        guard report.isValid, let activeConfig = report.validatedConfig else {
            return SettingsLoadResult(
                activeConfig: builtInConfig(),
                sparse: report.sparse ?? SparseAppConfig(),
                snapshot: snapshot,
                diagnostics: report.diagnostics
            )
        }
        return SettingsLoadResult(
            activeConfig: activeConfig,
            sparse: report.sparse ?? SparseAppConfig(),
            snapshot: snapshot,
            diagnostics: report.diagnostics
        )
    }

    func validate(data: Data) -> SettingsValidationResult {
        if data.count > ConfigLimits.maximumBytes {
            return invalid(
                sparse: nil,
                diagnostics: [ConfigDiagnostic(
                    severity: .error,
                    code: .inputTooLarge,
                    message: "Settings are \(data.count) bytes; the maximum is \(ConfigLimits.maximumBytes) bytes.",
                    semanticPath: "$",
                    sourcePath: store.fileURL.path
                )]
            )
        }

        guard String(data: data, encoding: .utf8) != nil else {
            return invalid(
                sparse: nil,
                diagnostics: [ConfigDiagnostic(
                    severity: .error,
                    code: .invalidUTF8,
                    message: "Settings must be UTF-8 JSON.",
                    semanticPath: "$",
                    sourcePath: store.fileURL.path
                )]
            )
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return invalid(
                sparse: nil,
                diagnostics: [decodeDiagnostic("Invalid JSON: \(error.localizedDescription)")]
            )
        }

        var diagnostics = unknownFieldDiagnostics(in: object)
        let envelope: SettingsEnvelope
        do {
            envelope = try JSONDecoder().decode(SettingsEnvelope.self, from: data)
        } catch {
            return invalid(
                sparse: nil,
                diagnostics: diagnostics + [decodeDiagnostic("Unable to decode settings schema: \(error.localizedDescription)")]
            )
        }

        if envelope.version != settingsSchemaVersion {
            diagnostics.append(
                ConfigDiagnostic(
                    severity: .error,
                    code: .invalidSyntax,
                    message: "Unsupported settings schema version \(envelope.version); expected \(settingsSchemaVersion).",
                    semanticPath: "version",
                    sourcePath: store.fileURL.path
                )
            )
        }

        let validation = ConfigValidator.validate(
            envelope.settings,
            source: ConfigSourceMetadata(sourcePath: store.fileURL.path, lineBySemanticPath: [:])
        )
        diagnostics += validation.diagnostics.map { diagnostic in
            guard diagnostic.code == .invalidPrefix else { return diagnostic }
            return ConfigDiagnostic(severity: .error, code: diagnostic.code, message: "Invalid common prefix in saved settings.", semanticPath: diagnostic.semanticPath, sourcePath: diagnostic.sourcePath, actions: diagnostic.actions, contexts: diagnostic.contexts)
        }
        let candidate = diagnostics.contains { $0.severity == .error }
            ? nil
            : validation.validatedConfig
        return SettingsValidationResult(
            sparse: envelope.settings,
            validatedConfig: candidate,
            diagnostics: diagnostics
        )
    }

    func encode(_ source: SparseAppConfig) throws -> Data {
        let original = try JSONEncoder().encode(SettingsEnvelope(version: settingsSchemaVersion, settings: source))
        let report = validate(data: original)
        guard report.isValid else {
            throw NSError(domain: "Modeleaf.Settings", code: 1, userInfo: [NSLocalizedDescriptionKey: report.diagnostics.map(\.message).joined(separator: "\n")])
        }
        let envelope = SettingsEnvelope(version: settingsSchemaVersion, settings: sparseDelta(from: source))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    private func sparseDelta(from source: SparseAppConfig) -> SparseAppConfig {
        SparseAppConfig(
            keymap: keymapDelta(source.keymap, prefix: source.input?.prefix ?? BuiltInDefaults.config.input.prefix),
            navigation: navigationDelta(source.navigation),
            input: inputDelta(source.input),
            links: linksDelta(source.links)
        )
    }

    private func keymapDelta(
        _ keymap: [String: [String]]?,
        prefix: String
    ) -> [String: [String]]? {
        guard let keymap else { return nil }
        var delta: [String: [String]] = [:]
        for rawAction in keymap.keys.sorted() {
            guard let values = keymap[rawAction] else { continue }
            let normalized = removingFoundations(values, actionName: rawAction, prefix: prefix)
            if let action = ActionID(rawValue: rawAction) {
                let defaults = removingFoundations(
                    BuiltInDefaults.templatedKeymap[action, default: []],
                    actionName: rawAction,
                    prefix: prefix
                )
                if normalized == defaults { continue }
            }
            delta[rawAction] = normalized
        }
        return delta.isEmpty ? nil : delta
    }

    private func navigationDelta(_ navigation: SparseNavigationConfiguration?) -> SparseNavigationConfiguration? {
        guard let navigation else { return nil }
        let defaults = BuiltInDefaults.config.navigation
        let value = SparseNavigationConfiguration(
            smallScrollPoints: navigation.smallScrollPoints == defaults.smallScrollPoints ? nil : navigation.smallScrollPoints,
            largeScrollViewportFraction: navigation.largeScrollViewportFraction == defaults.largeScrollViewportFraction ? nil : navigation.largeScrollViewportFraction,
            zoomFactor: navigation.zoomFactor == defaults.zoomFactor ? nil : navigation.zoomFactor
        )
        return value.smallScrollPoints == nil
            && value.largeScrollViewportFraction == nil
            && value.zoomFactor == nil ? nil : value
    }

    private func inputDelta(_ input: SparseInputConfiguration?) -> SparseInputConfiguration? {
        guard let input else { return nil }
        let defaults = BuiltInDefaults.config.input
        let value = SparseInputConfiguration(
            prefixTimeoutMilliseconds: input.prefixTimeoutMilliseconds == defaults.prefixTimeoutMilliseconds ? nil : input.prefixTimeoutMilliseconds,
            prefix: input.prefix == defaults.prefix ? nil : input.prefix
        )
        return value.prefixTimeoutMilliseconds == nil && value.prefix == nil ? nil : value
    }

    private func linksDelta(_ links: SparseLinksConfiguration?) -> SparseLinksConfiguration? {
        guard let links else { return nil }
        let defaults = BuiltInDefaults.config.links
        guard links.skipExternalLinkHintConfirmation != defaults.skipExternalLinkHintConfirmation else { return nil }
        return links
    }

    private func removingFoundations(_ values: [String], actionName: String, prefix: String) -> [String] {
        guard let action = ActionID(rawValue: actionName) else { return values }
        let foundations = Set(FoundationalBindings.sequences(for: action))
        guard !foundations.isEmpty else { return values }
        return values.filter { value in
            let expanded = value.replacingOccurrences(of: "<prefix>", with: prefix)
            guard let sequence = try? KeySequenceParser.parse(expanded) else { return true }
            return !foundations.contains(sequence)
        }
    }

    private func unknownFieldDiagnostics(in object: Any) -> [ConfigDiagnostic] {
        guard let root = object as? [String: Any] else {
            return [ConfigDiagnostic(
                severity: .error,
                code: .invalidType,
                message: "The settings document must be a JSON object.",
                semanticPath: "$",
                sourcePath: store.fileURL.path
            )]
        }

        var diagnostics: [ConfigDiagnostic] = []
        let knownRoot = Set(["version", "settings"])
        for key in root.keys.sorted() where !knownRoot.contains(key) {
            diagnostics.append(unknownFieldDiagnostic(path: key))
        }
        guard let settings = root["settings"] as? [String: Any] else { return diagnostics }

        let knownSettings = Set(["keymap", "navigation", "input", "links"])
        for key in settings.keys.sorted() where !knownSettings.contains(key) {
            diagnostics.append(unknownFieldDiagnostic(path: "settings.\(key)"))
        }
        checkKnownFields(
            in: settings["navigation"],
            allowed: ["small_scroll_points", "large_scroll_viewport_fraction", "zoom_factor"],
            path: "settings.navigation",
            diagnostics: &diagnostics
        )
        checkKnownFields(
            in: settings["input"],
            allowed: ["prefix_timeout_ms", "prefix"],
            path: "settings.input",
            diagnostics: &diagnostics
        )
        checkKnownFields(
            in: settings["links"],
            allowed: ["skip_external_link_hint_confirmation"],
            path: "settings.links",
            diagnostics: &diagnostics
        )
        return diagnostics
    }

    private func checkKnownFields(
        in value: Any?,
        allowed: Set<String>,
        path: String,
        diagnostics: inout [ConfigDiagnostic]
    ) {
        guard let object = value as? [String: Any] else { return }
        for key in object.keys.sorted() where !allowed.contains(key) {
            diagnostics.append(unknownFieldDiagnostic(path: "\(path).\(key)"))
        }
    }

    private func unknownFieldDiagnostic(path: String) -> ConfigDiagnostic {
        ConfigDiagnostic(
            severity: .error,
            code: .unknownKey,
            message: "Unknown settings field.",
            semanticPath: path,
            sourcePath: store.fileURL.path
        )
    }

    private func decodeDiagnostic(_ message: String) -> ConfigDiagnostic {
        ConfigDiagnostic(
            severity: .error,
            code: .decodeFailed,
            message: message,
            semanticPath: "$",
            sourcePath: store.fileURL.path
        )
    }

    private func fileDiagnostic(_ message: String) -> ConfigDiagnostic {
        ConfigDiagnostic(
            severity: .error,
            code: .fileReadFailed,
            message: message,
            semanticPath: "$",
            sourcePath: store.fileURL.path
        )
    }

    private func sizeDiagnostic(actualBytes: UInt64) -> ConfigDiagnostic {
        ConfigDiagnostic(
            severity: .error,
            code: .inputTooLarge,
            message: "Settings are \(actualBytes) bytes; the maximum is \(ConfigLimits.maximumBytes) bytes.",
            semanticPath: "$",
            sourcePath: store.fileURL.path
        )
    }

    private func invalid(sparse: SparseAppConfig?, diagnostics: [ConfigDiagnostic]) -> SettingsValidationResult {
        SettingsValidationResult(sparse: sparse, validatedConfig: nil, diagnostics: diagnostics)
    }

    private func builtInConfig() -> ValidatedAppConfig {
        let report = ConfigValidator.validate(SparseAppConfig())
        guard report.isValid, let config = report.validatedConfig else {
            preconditionFailure("Built-in configuration must validate")
        }
        return config
    }
}
