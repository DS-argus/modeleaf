import Foundation

/// A dotted numeric app version such as `0.2.0`, tolerant of a leading `v` (so a
/// Git tag like `v0.2.0` and an `Info.plist` `0.2.0` compare cleanly).
public struct AppVersion: Comparable, Equatable, CustomStringConvertible, Sendable {
    public let components: [Int]

    /// Parses a dotted version. Returns nil when no numeric component is found.
    /// Leading `v`/`V` is dropped; each dotted field contributes its leading
    /// digits (so `2-beta` reads as `2`).
    public init?(_ raw: String) {
        var string = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = string.first, first == "v" || first == "V" { string.removeFirst() }
        guard !string.isEmpty else { return nil }
        var parsed: [Int] = []
        for field in string.split(separator: ".", omittingEmptySubsequences: false) {
            let digits = field.prefix { $0.isNumber }
            guard let value = Int(digits) else { return nil }
            parsed.append(value)
        }
        guard !parsed.isEmpty else { return nil }
        components = parsed
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    private static func component(_ list: [Int], _ index: Int) -> Int {
        index < list.count ? list[index] : 0
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width {
            let left = component(lhs.components, index)
            let right = component(rhs.components, index)
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width where component(lhs.components, index) != component(rhs.components, index) {
            return false
        }
        return true
    }
}

private enum TrustedReleaseURL {
    private static let releasePathPrefix = "/DS-argus/modeleaf/releases/tag/"

    static func validate(_ url: URL?) -> URL? {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.hasPrefix(releasePathPrefix),
              !url.path.dropFirst(releasePathPrefix.count).isEmpty
        else { return nil }
        return url
    }
}

/// Pure update-notice policy: no networking, AppKit, or presentation text.
public struct AvailableUpdate: Equatable, Sendable {
    public let version: AppVersion
    public let highlights: String?
    public let releaseURL: URL?

    public init(version: AppVersion, highlights: String? = nil, releaseURL: URL? = nil) {
        self.version = version
        self.highlights = highlights
        self.releaseURL = TrustedReleaseURL.validate(releaseURL)
    }
}

public enum UpdateNotice {
    public static func availableUpdate(
        current: String,
        latest: String,
        body: String? = nil,
        releaseURL: String? = nil
    ) -> AvailableUpdate? {
        guard let installed = AppVersion(current),
              let available = AppVersion(latest),
              available > installed
        else { return nil }

        let parsedReleaseURL = releaseURL.flatMap { URL(string: $0) }
        return AvailableUpdate(
            version: available,
            highlights: extractHighlights(from: body),
            releaseURL: parsedReleaseURL
        )
    }

    private static func extractHighlights(from body: String?) -> String? {
        guard let body else { return nil }

        let normalizedBody = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedBody.components(separatedBy: "\n")
        var collecting = false
        var fence: Fence?
        var content: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if let activeFence = fence {
                if closesFence(line, matching: activeFence) {
                    fence = nil
                }
                if collecting { content.append(line) }
                continue
            }

            if let openingFence = openingFence(in: line) {
                fence = openingFence
                if collecting { content.append(line) }
                continue
            }

            if !collecting {
                if trimmed == "## Highlights" {
                    collecting = true
                }
                continue
            }

            if isLevelOneOrTwoHeading(line) {
                break
            }
            content.append(line)
        }

        guard collecting else { return nil }
        let highlights = content.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return highlights.isEmpty ? nil : highlights
    }

    private struct Fence {
        let character: Character
        let length: Int
    }

    private static func openingFence(in line: String) -> Fence? {
        let candidate = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let character = candidate.first, character == "`" || character == "~" else { return nil }
        let length = candidate.prefix(while: { $0 == character }).count
        guard length >= 3 else { return nil }
        if character == "`", candidate.dropFirst(length).contains("`") { return nil }
        return Fence(character: character, length: length)
    }

    private static func closesFence(_ line: String, matching fence: Fence) -> Bool {
        let candidate = line.drop(while: { $0 == " " || $0 == "\t" })
        let length = candidate.prefix(while: { $0 == fence.character }).count
        guard length >= fence.length else { return false }
        return candidate.dropFirst(length).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func isLevelOneOrTwoHeading(_ line: String) -> Bool {
        let candidate = line.drop(while: { $0 == " " || $0 == "\t" })
        let hashCount = candidate.prefix(while: { $0 == "#" }).count
        guard hashCount == 1 || hashCount == 2 else { return false }
        let remainder = candidate.dropFirst(hashCount)
        return remainder.isEmpty || remainder.first == " " || remainder.first == "\t"
    }
}
