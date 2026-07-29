import Foundation
import PDFReaderCore

enum ConfigActivationOrigin: String, Equatable {
    case builtInMissingFile
    case userFile
    case builtInFallback
}

struct ConfigLoadResult {
    let activeConfig: ValidatedAppConfig
    let diagnostics: [ConfigDiagnostic]
    let origin: ConfigActivationOrigin

    var usedFallback: Bool { origin == .builtInFallback }
}

enum ConfigReloadResult {
    case applied(ValidatedAppConfig, warnings: [ConfigDiagnostic])
    case rejected(diagnostics: [ConfigDiagnostic])
    case missing
}

struct ConfigService {
    let source: ConfigFileSource
    let decoder: any ConfigDecoding
    let fileManager: FileManager

    init(
        source: ConfigFileSource = ConfigFileSource(url: ConfigFileSource.defaultURL()),
        decoder: any ConfigDecoding = TOMLConfigDecoder(),
        fileManager: FileManager = .default
    ) {
        self.source = source
        self.decoder = decoder
        self.fileManager = fileManager
    }

    func load() -> ConfigLoadResult {
        switch source.read(fileManager: fileManager) {
        case .missing:
            return ConfigLoadResult(
                activeConfig: builtInConfig(),
                diagnostics: [],
                origin: .builtInMissingFile
            )
        case let .failed(diagnostic):
            return ConfigLoadResult(
                activeConfig: builtInConfig(),
                diagnostics: [diagnostic],
                origin: .builtInFallback
            )
        case let .loaded(data):
            let decoded = decoder.decode(data, sourcePath: source.url.path)
            guard let document = decoded.document else {
                return ConfigLoadResult(
                    activeConfig: builtInConfig(),
                    diagnostics: decoded.diagnostics,
                    origin: .builtInFallback
                )
            }
            let validation = ConfigValidator.validate(
                document.sparseConfig,
                source: document.source
            )
            let diagnostics = decoded.diagnostics + validation.diagnostics
            guard !diagnostics.contains(where: { $0.severity == .error }),
                  validation.isValid,
                  let active = validation.validatedConfig
            else {
                return ConfigLoadResult(
                    activeConfig: builtInConfig(),
                    diagnostics: diagnostics,
                    origin: .builtInFallback
                )
            }
            return ConfigLoadResult(
                activeConfig: active,
                diagnostics: diagnostics,
                origin: .userFile
            )
        }
    }

    /// Strict reload path for the runtime Reload Config command. Unlike
    /// launch-time `load()`, a broken or unreadable file never falls back to
    /// built-ins: `.rejected` carries diagnostics and no config, so the
    /// caller keeps the last good generation running.
    func reload() -> ConfigReloadResult {
        switch source.read(fileManager: fileManager) {
        case .missing:
            return .missing
        case let .failed(diagnostic):
            return .rejected(diagnostics: [diagnostic])
        case let .loaded(data):
            let decoded = decoder.decode(data, sourcePath: source.url.path)
            guard let document = decoded.document else {
                return .rejected(diagnostics: decoded.diagnostics)
            }
            let validation = ConfigValidator.validate(
                document.sparseConfig,
                source: document.source
            )
            let diagnostics = decoded.diagnostics + validation.diagnostics
            guard !diagnostics.contains(where: { $0.severity == .error }),
                  validation.isValid,
                  let active = validation.validatedConfig
            else {
                return .rejected(diagnostics: diagnostics)
            }
            return .applied(active, warnings: diagnostics.filter { $0.severity == .warning })
        }
    }

    private func builtInConfig() -> ValidatedAppConfig {
        let report = ConfigValidator.validate(SparseAppConfig())
        guard report.isValid, let config = report.validatedConfig else {
            preconditionFailure("BuiltInDefaults failed ConfigValidator: \(report.diagnostics)")
        }
        return config
    }
}
