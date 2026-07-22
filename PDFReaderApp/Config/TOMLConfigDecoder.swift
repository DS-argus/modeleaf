import Foundation
import PDFReaderCore
import TOMLDecoder

struct TOMLConfigDecoder: ConfigDecoding {
    func decode(_ data: Data, sourcePath: String) -> ConfigDecodeReport {
        guard data.count <= ConfigLimits.maximumBytes else {
            return ConfigDecodeReport(
                document: nil,
                diagnostics: [
                    ConfigDiagnostic(
                        severity: .error,
                        code: .inputTooLarge,
                        message: "Configuration is \(data.count) bytes; the maximum is \(ConfigLimits.maximumBytes) bytes.",
                        semanticPath: "$",
                        sourcePath: sourcePath
                    ),
                ]
            )
        }
        guard let source = String(data: data, encoding: .utf8) else {
            return ConfigDecodeReport(
                document: nil,
                diagnostics: [
                    ConfigDiagnostic(
                        severity: .error,
                        code: .invalidUTF8,
                        message: "Configuration must be valid UTF-8.",
                        semanticPath: "$",
                        sourcePath: sourcePath
                    ),
                ]
            )
        }

        let sourceIndex = TOMLSourceIndex(source: source)
        if !sourceIndex.duplicates.isEmpty {
            return ConfigDecodeReport(
                document: nil,
                diagnostics: sourceIndex.duplicates.map { duplicate in
                    ConfigDiagnostic(
                        severity: .error,
                        code: .duplicateKey,
                        message: "Duplicate key; first defined at line \(duplicate.firstLine).",
                        semanticPath: duplicate.path,
                        sourcePath: sourcePath,
                        line: duplicate.line
                    )
                }
            )
        }

        let dictionary: [String: Any]
        do {
            dictionary = try [String: Any](TOMLTable(source: data))
        } catch {
            return ConfigDecodeReport(
                document: nil,
                diagnostics: [syntaxDiagnostic(error, sourcePath: sourcePath)]
            )
        }

        let schemaDiagnostics = ConfigTOMLSchema.validate(
            dictionary,
            sourcePath: sourcePath,
            sourceIndex: sourceIndex
        )
        do {
            let sparse = try TOMLDecoder().decode(SparseAppConfig.self, from: data)
            let metadata = ConfigSourceMetadata(
                sourcePath: sourcePath,
                lineBySemanticPath: sourceIndex.lineBySemanticPath
            )
            return ConfigDecodeReport(
                document: DecodedConfigDocument(sparseConfig: sparse, source: metadata),
                diagnostics: schemaDiagnostics
            )
        } catch {
            let description = String(describing: error)
            let path = decodingPath(from: error) ?? "$"
            return ConfigDecodeReport(
                document: nil,
                diagnostics: schemaDiagnostics + [
                    ConfigDiagnostic(
                        severity: .error,
                        code: .decodeFailed,
                        message: description,
                        semanticPath: path,
                        sourcePath: sourcePath,
                        line: sourceIndex.line(for: path) ?? extractLine(from: description)
                    ),
                ]
            )
        }
    }

    private func syntaxDiagnostic(_ error: Error, sourcePath: String) -> ConfigDiagnostic {
        let description = String(describing: error)
        return ConfigDiagnostic(
            severity: .error,
            code: .invalidSyntax,
            message: description,
            semanticPath: "$",
            sourcePath: sourcePath,
            line: extractLine(from: description)
        )
    }

    private func decodingPath(from error: Error) -> String? {
        let codingPath: [any CodingKey]
        switch error {
        case let DecodingError.typeMismatch(_, context): codingPath = context.codingPath
        case let DecodingError.valueNotFound(_, context): codingPath = context.codingPath
        case let DecodingError.keyNotFound(key, context): codingPath = context.codingPath + [key]
        case let DecodingError.dataCorrupted(context): codingPath = context.codingPath
        default: return nil
        }
        guard !codingPath.isEmpty else { return nil }
        return codingPath.map(\.stringValue).joined(separator: ".")
    }
}

private struct ConfigTOMLSchema {
    static func validate(
        _ dictionary: [String: Any],
        sourcePath: String,
        sourceIndex: TOMLSourceIndex
    ) -> [ConfigDiagnostic] {
        var issues: [SchemaIssue] = []
        for key in dictionary.keys.sorted() {
            let value = dictionary[key] as Any
            let path: [TOMLPathComponent] = [.key(key)]
            switch key {
            case "keymap":
                validateKeymap(value, path: path, issues: &issues)
            case "navigation":
                validateNavigation(value, path: path, issues: &issues)
            case "input":
                validateInput(value, path: path, issues: &issues)
            case "theme":
                validateTheme(value, path: path, issues: &issues)
            default:
                collectUnknownLeaves(value, path: path, issues: &issues)
            }
        }
        return issues.map { issue in
            let path = semanticPath(issue.path)
            return ConfigDiagnostic(
                severity: .error,
                code: issue.code,
                message: issue.message,
                semanticPath: path,
                sourcePath: sourcePath,
                line: sourceIndex.line(for: path)
            )
        }
    }

    private static func validateKeymap(
        _ value: Any,
        path: [TOMLPathComponent],
        issues: inout [SchemaIssue]
    ) {
        guard let table = value as? [String: Any] else {
            issues.append(typeIssue(path, expected: "table"))
            return
        }
        for action in table.keys.sorted() {
            let actionPath = path + [.key(action)]
            guard let values = table[action] as? [Any] else {
                issues.append(typeIssue(actionPath, expected: "array of strings"))
                collectNestedUnknowns(table[action] as Any, path: actionPath, issues: &issues)
                continue
            }
            for (index, element) in values.enumerated() where !(element is String) {
                issues.append(typeIssue(actionPath + [.index(index)], expected: "string"))
                collectNestedUnknowns(element, path: actionPath + [.index(index)], issues: &issues)
            }
        }
    }

    private static func validateNavigation(
        _ value: Any,
        path: [TOMLPathComponent],
        issues: inout [SchemaIssue]
    ) {
        validateFixedTable(
            value,
            path: path,
            fields: [
                "small_scroll_points": isNumber,
                "large_scroll_viewport_fraction": isNumber,
                "zoom_factor": isNumber,
            ],
            issues: &issues
        )
    }

    private static func validateInput(
        _ value: Any,
        path: [TOMLPathComponent],
        issues: inout [SchemaIssue]
    ) {
        validateFixedTable(
            value,
            path: path,
            fields: ["prefix_timeout_ms": { $0 is Int64 }],
            issues: &issues
        )
    }

    private static func validateTheme(
        _ value: Any,
        path: [TOMLPathComponent],
        issues: inout [SchemaIssue]
    ) {
        guard let table = value as? [String: Any] else {
            issues.append(typeIssue(path, expected: "table"))
            return
        }
        for key in table.keys.sorted() {
            let fieldPath = path + [.key(key)]
            switch key {
            case "built_in":
                if !(table[key] is String) { issues.append(typeIssue(fieldPath, expected: "string")) }
            case "overrides":
                guard let overrides = table[key] as? [String: Any] else {
                    issues.append(typeIssue(fieldPath, expected: "table"))
                    collectNestedUnknowns(table[key] as Any, path: fieldPath, issues: &issues)
                    continue
                }
                for token in overrides.keys.sorted() {
                    let tokenPath = fieldPath + [.key(token)]
                    if !(overrides[token] is String) {
                        issues.append(typeIssue(tokenPath, expected: "string"))
                        collectNestedUnknowns(overrides[token] as Any, path: tokenPath, issues: &issues)
                    }
                }
            default:
                collectUnknownLeaves(table[key] as Any, path: fieldPath, issues: &issues)
            }
        }
    }

    private static func validateFixedTable(
        _ value: Any,
        path: [TOMLPathComponent],
        fields: [String: (Any) -> Bool],
        issues: inout [SchemaIssue]
    ) {
        guard let table = value as? [String: Any] else {
            issues.append(typeIssue(path, expected: "table"))
            return
        }
        for key in table.keys.sorted() {
            let fieldPath = path + [.key(key)]
            guard let predicate = fields[key] else {
                collectUnknownLeaves(table[key] as Any, path: fieldPath, issues: &issues)
                continue
            }
            if !predicate(table[key] as Any) {
                issues.append(typeIssue(fieldPath, expected: "number"))
                collectNestedUnknowns(table[key] as Any, path: fieldPath, issues: &issues)
            }
        }
    }

    private static func collectUnknownLeaves(
        _ value: Any,
        path: [TOMLPathComponent],
        issues: inout [SchemaIssue]
    ) {
        if let table = value as? [String: Any], !table.isEmpty {
            for key in table.keys.sorted() {
                collectUnknownLeaves(table[key] as Any, path: path + [.key(key)], issues: &issues)
            }
            return
        }
        if let array = value as? [Any], !array.isEmpty {
            for (index, element) in array.enumerated() {
                collectUnknownLeaves(element, path: path + [.index(index)], issues: &issues)
            }
            return
        }
        let executableTerms = ["macro", "script", "shell", "plugin", "hook", "command", "user_action", "user-action"]
        let keys = path.compactMap { component -> String? in
            if case let .key(value) = component { return value.lowercased() }
            return nil
        }
        let executable = keys.contains { key in executableTerms.contains { key.contains($0) } }
        issues.append(
            SchemaIssue(
                code: .unknownKey,
                path: path,
                message: executable
                    ? "Executable extension surfaces are not supported; configuration is data only."
                    : "Unknown configuration key."
            )
        )
    }

    private static func collectNestedUnknowns(
        _ value: Any,
        path: [TOMLPathComponent],
        issues: inout [SchemaIssue]
    ) {
        if value is [String: Any] || value is [Any] {
            collectUnknownLeaves(value, path: path, issues: &issues)
        }
    }

    private static func typeIssue(_ path: [TOMLPathComponent], expected: String) -> SchemaIssue {
        SchemaIssue(code: .invalidType, path: path, message: "Expected \(expected).")
    }

    private static func isNumber(_ value: Any) -> Bool {
        value is Int64 || value is Double
    }
}

private struct SchemaIssue {
    let code: ConfigDiagnosticCode
    let path: [TOMLPathComponent]
    let message: String
}

private enum TOMLPathComponent: Hashable {
    case key(String)
    case index(Int)
}

private struct TOMLSourceIndex {
    struct Duplicate {
        let path: String
        let line: Int
        let firstLine: Int
    }

    let lineBySemanticPath: [String: Int]
    let duplicates: [Duplicate]

    init(source: String) {
        var tablePath: [TOMLPathComponent] = []
        var arrayTableCounts: [String: Int] = [:]
        var lines: [String: Int] = [:]
        var firstDefinition: [String: Int] = [:]
        var duplicates: [Duplicate] = []

        for (offset, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if let header = tableHeader(in: line) {
                tablePath = splitDottedKey(header.path).map(TOMLPathComponent.key)
                if header.isArray {
                    let basePath = semanticPath(tablePath)
                    let index = arrayTableCounts[basePath, default: 0]
                    arrayTableCounts[basePath] = index + 1
                    tablePath.append(.index(index))
                }
                lines[semanticPath(tablePath)] = lineNumber
                continue
            }
            guard let equals = firstUnquotedEquals(in: line) else { continue }
            let rawKey = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let keyPath = splitDottedKey(rawKey).map(TOMLPathComponent.key)
            guard !keyPath.isEmpty else { continue }
            let fullPath = tablePath + keyPath
            let rendered = semanticPath(fullPath)
            if let firstLine = firstDefinition[rendered] {
                duplicates.append(Duplicate(path: rendered, line: lineNumber, firstLine: firstLine))
            } else {
                firstDefinition[rendered] = lineNumber
                lines[rendered] = lineNumber
            }
        }
        self.lineBySemanticPath = lines
        self.duplicates = duplicates
    }

    func line(for path: String) -> Int? {
        if let exact = lineBySemanticPath[path] { return exact }
        return ConfigSourceMetadata(sourcePath: nil, lineBySemanticPath: lineBySemanticPath).line(for: path)
    }
}

private func semanticPath(_ components: [TOMLPathComponent]) -> String {
    guard !components.isEmpty else { return "$" }
    var result = ""
    for (index, component) in components.enumerated() {
        switch component {
        case let .index(value):
            result += "[\(value)]"
        case let .key(value):
            let dynamicKey = (index == 1 && key(at: 0, in: components) == "keymap")
                || (index == 2 && key(at: 0, in: components) == "theme" && key(at: 1, in: components) == "overrides")
            if index == 0 {
                result = value
            } else if dynamicKey || !isBareKey(value) {
                result += "[\(quoted(value))]"
            } else {
                result += ".\(value)"
            }
        }
    }
    return result
}

private func key(at index: Int, in components: [TOMLPathComponent]) -> String? {
    guard components.indices.contains(index), case let .key(value) = components[index] else { return nil }
    return value
}

private func isBareKey(_ value: String) -> Bool {
    !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
        (48...57).contains(scalar.value)
            || (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
            || scalar.value == 95
            || scalar.value == 45
    }
}

private func quoted(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

private func stripComment(_ line: String) -> String {
    var quote: Character?
    var escaped = false
    for index in line.indices {
        let character = line[index]
        if escaped {
            escaped = false
            continue
        }
        if quote == "\"", character == "\\" {
            escaped = true
            continue
        }
        if character == "\"" || character == "'" {
            if quote == character { quote = nil } else if quote == nil { quote = character }
            continue
        }
        if character == "#", quote == nil {
            return String(line[..<index])
        }
    }
    return line
}

private func tableHeader(in line: String) -> (path: String, isArray: Bool)? {
    if line.hasPrefix("[["), line.hasSuffix("]]"), line.count >= 4 {
        return (
            String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces),
            true
        )
    }
    if line.hasPrefix("["), line.hasSuffix("]"), line.count >= 2 {
        return (
            String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces),
            false
        )
    }
    return nil
}

private func firstUnquotedEquals(in line: String) -> String.Index? {
    var quote: Character?
    var escaped = false
    for index in line.indices {
        let character = line[index]
        if escaped {
            escaped = false
            continue
        }
        if quote == "\"", character == "\\" {
            escaped = true
            continue
        }
        if character == "\"" || character == "'" {
            if quote == character { quote = nil } else if quote == nil { quote = character }
            continue
        }
        if character == "=", quote == nil { return index }
    }
    return nil
}

private func splitDottedKey(_ source: String) -> [String] {
    var components: [String] = []
    var buffer = ""
    var quote: Character?
    var escaped = false
    for character in source {
        if escaped {
            buffer.append(character)
            escaped = false
            continue
        }
        if quote == "\"", character == "\\" {
            escaped = true
            continue
        }
        if character == "\"" || character == "'" {
            if quote == character { quote = nil } else if quote == nil { quote = character }
            continue
        }
        if character == ".", quote == nil {
            let component = buffer.trimmingCharacters(in: .whitespaces)
            if !component.isEmpty { components.append(component) }
            buffer = ""
            continue
        }
        buffer.append(character)
    }
    let final = buffer.trimmingCharacters(in: .whitespaces)
    if !final.isEmpty { components.append(final) }
    return components
}

private func extractLine(from description: String) -> Int? {
    guard let range = description.range(of: #"\(Line [0-9]+\)"#, options: .regularExpression) else {
        return nil
    }
    let marker = description[range]
    return Int(marker.filter(\.isNumber))
}
