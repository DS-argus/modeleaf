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


/// Pure update-notice policy: no networking, AppKit, or presentation text.
public struct AvailableUpdate: Equatable, Sendable {
    public let version: AppVersion

    public init(version: AppVersion) {
        self.version = version
    }
}

public enum UpdateNotice {
    public static func availableUpdate(current: String, latest: String) -> AvailableUpdate? {
        guard let installed = AppVersion(current),
              let available = AppVersion(latest),
              available > installed
        else { return nil }
        return AvailableUpdate(version: available)
    }
}
