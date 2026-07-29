import Foundation

public enum LinkHintFilterResult: Equatable, Sendable {
    case none
    case ambiguous
    case unique(Int)
}

/// Pure query resolution over a set of hint labels.
public enum LinkHintFilter {
    /// Indices of every label that begins with `typed` (case-insensitive).
    public static func candidates(_ labels: [String], typed: String) -> [Int] {
        let query = typed.lowercased()
        guard !query.isEmpty else { return Array(labels.indices) }
        return labels.indices.filter { labels[$0].lowercased().hasPrefix(query) }
    }

    /// The single label exactly equal to `typed`, if any (case-insensitive).
    public static func exactMatch(_ labels: [String], typed: String) -> Int? {
        let query = typed.lowercased()
        return labels.firstIndex { $0.lowercased() == query }
    }

    /// Classifies a typed prefix for hint-overlay input handling.
    public static func filter(_ labels: [String], typed: String) -> LinkHintFilterResult {
        let matches = candidates(labels, typed: typed)
        switch matches.count {
        case 0: return .none
        case 1: return .unique(matches[0])
        default: return .ambiguous
        }
    }
}
