import Foundation

public enum ConfigLimits {
    public static let maximumBytes = 256 * 1_024
}

public struct DecodedConfigDocument: Equatable, Sendable {
    public let sparseConfig: SparseAppConfig
    public let source: ConfigSourceMetadata

    public init(sparseConfig: SparseAppConfig, source: ConfigSourceMetadata) {
        self.sparseConfig = sparseConfig
        self.source = source
    }
}

public struct ConfigDecodeReport: Equatable, Sendable {
    public let document: DecodedConfigDocument?
    public let diagnostics: [ConfigDiagnostic]

    public init(document: DecodedConfigDocument?, diagnostics: [ConfigDiagnostic]) {
        self.document = document
        self.diagnostics = diagnostics
    }

    public var isValid: Bool {
        document != nil && !diagnostics.contains { $0.severity == .error }
    }
}

public protocol ConfigDecoding: Sendable {
    func decode(_ data: Data, sourcePath: String) -> ConfigDecodeReport
}
