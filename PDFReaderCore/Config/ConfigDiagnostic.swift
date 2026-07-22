import Foundation

public enum ConfigDiagnosticSeverity: String, Codable, Equatable, Sendable {
    case warning
    case error
}

public enum ConfigDiagnosticCode: String, Codable, Equatable, Sendable {
    case fileReadFailed
    case inputTooLarge
    case invalidUTF8
    case duplicateKey
    case invalidSyntax
    case unknownKey
    case invalidType
    case decodeFailed
    case unknownAction
    case invalidKeySequence
    case valueOutOfRange
    case invalidTheme
    case invalidThemeToken
    case invalidColor
    case missingAction
    case duplicateBinding
    case conflictingBinding
    case promptUnsafeBinding
    case invalidExactPrefix
    case promptLifecycleUnbound
    case menuEquivalentOmitted
    case internalInvariant
}

public struct ConfigDiagnostic: Equatable, Sendable, CustomStringConvertible {
    public let severity: ConfigDiagnosticSeverity
    public let code: ConfigDiagnosticCode
    public let message: String
    public let semanticPath: String
    public let sourcePath: String?
    public let line: Int?
    public let actions: [String]
    public let contexts: [InputContext]

    public init(
        severity: ConfigDiagnosticSeverity,
        code: ConfigDiagnosticCode,
        message: String,
        semanticPath: String,
        sourcePath: String? = nil,
        line: Int? = nil,
        actions: [String] = [],
        contexts: [InputContext] = []
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.semanticPath = semanticPath
        self.sourcePath = sourcePath
        self.line = line
        self.actions = actions
        self.contexts = contexts
    }

    public var description: String {
        let location = [
            sourcePath,
            line.map { "line \($0)" },
            semanticPath.isEmpty ? nil : semanticPath,
        ].compactMap { $0 }.joined(separator: ":")
        return "\(severity.rawValue): \(location.isEmpty ? "config" : location): \(message)"
    }
}

public struct ConfigSourceMetadata: Equatable, Sendable {
    public static let none = ConfigSourceMetadata(sourcePath: nil, lineBySemanticPath: [:])

    public let sourcePath: String?
    public let lineBySemanticPath: [String: Int]

    public init(sourcePath: String?, lineBySemanticPath: [String: Int]) {
        self.sourcePath = sourcePath
        self.lineBySemanticPath = lineBySemanticPath
    }

    public func line(for semanticPath: String) -> Int? {
        if let exact = lineBySemanticPath[semanticPath] { return exact }
        var candidate = semanticPath
        while candidate.last == "]", let open = candidate.lastIndex(of: "[") {
            let contents = candidate[candidate.index(after: open)..<candidate.index(before: candidate.endIndex)]
            guard Int(contents) != nil else { break }
            candidate.removeSubrange(open...candidate.index(before: candidate.endIndex))
            if let line = lineBySemanticPath[candidate] { return line }
        }
        return nil
    }
}

public enum ConfigSemanticPath {
    public static func keymap(action: String, bindingIndex: Int? = nil) -> String {
        let base = "keymap[\(quoted(action))]"
        return bindingIndex.map { "\(base)[\($0)]" } ?? base
    }

    public static func themeOverride(token: String) -> String {
        "theme.overrides[\(quoted(token))]"
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
