import Foundation
import TOMLDecoder

public enum BoundedTOMLDecoder {
    public static let maximumBytes = 256 * 1024

    public static func parse(_ data: Data) throws -> TOMLTable {
        guard data.count <= maximumBytes else {
            throw ProbeFailure.invariant("config exceeds 256 KiB")
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw ProbeFailure.invariant("config is not valid UTF-8")
        }
        if let duplicate = firstDuplicateAssignment(in: source) {
            throw ProbeFailure.invariant(
                "duplicate key \(duplicate.path) at line \(duplicate.line); first defined at line \(duplicate.firstLine)"
            )
        }
        return try TOMLTable(source: data)
    }

    private static func firstDuplicateAssignment(in source: String) -> (path: String, line: Int, firstLine: Int)? {
        var tablePath = ""
        var seen: [String: Int] = [:]

        for (offset, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                tablePath = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let rawKey = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            guard !rawKey.isEmpty else { continue }
            let key = rawKey.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let fullPath = tablePath.isEmpty ? key : "\(tablePath).\(key)"
            if let firstLine = seen[fullPath] {
                return (fullPath, lineNumber, firstLine)
            }
            seen[fullPath] = lineNumber
        }
        return nil
    }
}

private struct SparseProbeConfig: Decodable, Equatable {
    struct Appearance: Decodable, Equatable {
        let theme: String?
    }

    struct Values: Decodable, Equatable {
        let smallScrollPoints: Double?
        let largeScrollViewportFraction: Double?
        let zoomFactor: Double?

        enum CodingKeys: String, CodingKey {
            case smallScrollPoints = "small_scroll_points"
            case largeScrollViewportFraction = "large_scroll_viewport_fraction"
            case zoomFactor = "zoom_factor"
        }
    }

    struct Input: Decodable, Equatable {
        let prefixTimeoutMilliseconds: Int?

        enum CodingKeys: String, CodingKey {
            case prefixTimeoutMilliseconds = "prefix_timeout_ms"
        }
    }

    struct Keybindings: Decodable, Equatable {
        let navigation: [String: String]?
        let pagePrompt: [String: String]?
        let searchPrompt: [String: String]?
        let searchResults: [String: String]?

        enum CodingKeys: String, CodingKey {
            case navigation
            case pagePrompt = "page_prompt"
            case searchPrompt = "search_prompt"
            case searchResults = "search_results"
        }
    }

    let appearance: Appearance?
    let values: Values?
    let input: Input?
    let keybindings: Keybindings?
}

private enum ProbeSchema {
    static func isAllowedLeaf(_ path: String) -> Bool {
        let exact: Set<String> = [
            "appearance.theme",
            "values.small_scroll_points",
            "values.large_scroll_viewport_fraction",
            "values.zoom_factor",
            "input.prefix_timeout_ms",
        ]
        if exact.contains(path) { return true }

        let dynamicPrefixes = [
            "keybindings.navigation.",
            "keybindings.page_prompt.",
            "keybindings.search_prompt.",
            "keybindings.search_results.",
        ]
        for prefix in dynamicPrefixes where path.hasPrefix(prefix) {
            let remainder = path.dropFirst(prefix.count)
            return !remainder.isEmpty && !remainder.contains(".") && !remainder.contains("[")
        }
        return false
    }
}

public enum TOMLQualificationProbe {
    public static func run() -> ProbeSection {
        let representative = """
        [appearance]
        theme = "nord"

        [keybindings.navigation]
        j = "scroll.down"
        k = "scroll.up"
        """

        var parsedTable: TOMLTable?
        var parsedSparse: SparseProbeConfig?
        var parseError: Error?
        do {
            let data = Data(representative.utf8)
            parsedTable = try BoundedTOMLDecoder.parse(data)
            parsedSparse = try TOMLDecoder().decode(SparseProbeConfig.self, from: data)
        } catch {
            parseError = error
        }

        let sparseWorked = parsedSparse?.appearance?.theme == "nord"
            && parsedSparse?.values == nil
            && parsedSparse?.keybindings?.navigation?["j"] == "scroll.down"

        var recursivePaths: [String] = []
        if let parsedTable, let dictionary = try? [String: Any](parsedTable) {
            recursivePaths = collectLeafPaths(dictionary).sorted()
        }
        let expectedPaths = [
            "appearance.theme",
            "keybindings.navigation.j",
            "keybindings.navigation.k",
        ]

        let unknownSource = """
        [appearance]
        theme = "nord"
        typo = "must fail"

        [keybindings.navigation.j]
        nested = "must also fail"
        """
        let unknownPaths: [String] = (try? BoundedTOMLDecoder.parse(Data(unknownSource.utf8)))
            .flatMap { try? [String: Any]($0) }
            .map { collectLeafPaths($0).filter { !ProbeSchema.isAllowedLeaf($0) }.sorted() }
            ?? []

        let duplicateSource = """
        [appearance]
        theme = "nord"
        theme = "tokyo-night"
        """
        let duplicateError = capturedError {
            _ = try BoundedTOMLDecoder.parse(Data(duplicateSource.utf8))
        }

        let syntaxSource = """
        title = "ok"
        [appearance
        theme = "nord"
        """
        let syntaxError = capturedError {
            _ = try BoundedTOMLDecoder.parse(Data(syntaxSource.utf8))
        }

        let oversized = Data(repeating: 0x20, count: BoundedTOMLDecoder.maximumBytes + 1)
        let sizeError = capturedError {
            _ = try BoundedTOMLDecoder.parse(oversized)
        }

        let conflictSource = """
        [keybindings.navigation]
        j = "scroll.down"
        k = "scroll.down"
        """
        let conflicts = semanticBindingConflicts(source: conflictSource)

        let exactPin = exactResolvedPin()

        return ProbeSection(
            id: "toml-qualification",
            title: "TOMLDecoder 0.4.5 strict adapter qualification",
            checks: [
                checked("representative-parse", parseError == nil && parsedTable != nil, detail: "representative TOML parses through the bounded table adapter"),
                checked("recursive-leaf-walk", recursivePaths == expectedPaths, detail: "all nested leaves are discoverable for recursive schema consumption"),
                checked("unknown-leaf-diagnostic", unknownPaths == ["appearance.typo", "keybindings.navigation.j.nested"], detail: "unknown leaves are reported by their complete recursive paths"),
                checked("sparse-decode", sparseWorked, detail: "TOMLDecoder decodes present values while preserving absent sections as nil"),
                checked("duplicate-diagnostic", duplicateError == "duplicate key appearance.theme at line 3; first defined at line 2", detail: "adapter diagnostic: \(duplicateError ?? "missing")"),
                checked("syntax-diagnostic", syntaxError?.contains("Line 2") == true && syntaxError?.localizedCaseInsensitiveContains("syntax") == true, detail: "syntax failure reports the representative source line"),
                checked("bounded-input", sizeError == "config exceeds 256 KiB", detail: "the 256 KiB gate runs before parser allocation"),
                checked("semantic-conflict", conflicts == ["navigation:j,k->scroll.down"], detail: "the adapter output supports deterministic same-context conflict diagnostics"),
                checked("exact-version", exactPin, detail: "Package.resolved records TOMLDecoder exactly at 0.4.5"),
            ]
        )
    }

    private static func collectLeafPaths(_ value: Any, prefix: String = "") -> [String] {
        if let dictionary = value as? [String: Any] {
            return dictionary.keys.sorted().flatMap { key in
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                return collectLeafPaths(dictionary[key] as Any, prefix: path)
            }
        }
        if let array = value as? [Any] {
            return array.enumerated().flatMap { index, element in
                collectLeafPaths(element, prefix: "\(prefix)[\(index)]")
            }
        }
        return [prefix]
    }

    private static func capturedError(_ operation: () throws -> Void) -> String? {
        do {
            try operation()
            return nil
        } catch {
            return String(describing: error)
        }
    }

    private static func semanticBindingConflicts(source: String) -> [String] {
        guard let decoded = try? TOMLDecoder().decode(SparseProbeConfig.self, from: source),
              let navigation = decoded.keybindings?.navigation
        else { return [] }

        return Dictionary(grouping: navigation, by: \.value)
            .compactMap { action, entries -> String? in
                let keys = entries.map(\.key).sorted()
                guard keys.count > 1 else { return nil }
                return "navigation:\(keys.joined(separator: ","))->\(action)"
            }
            .sorted()
    }

    private static func exactResolvedPin() -> Bool {
        guard let data = FileManager.default.contents(atPath: "Package.resolved"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pins = object["pins"] as? [[String: Any]]
        else { return false }

        return pins.contains { pin in
            guard (pin["identity"] as? String) == "tomldecoder",
                  let state = pin["state"] as? [String: Any]
            else { return false }
            return state["version"] as? String == "0.4.5"
        }
    }
}
