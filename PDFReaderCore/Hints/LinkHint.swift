import Foundation

/// Generates and matches Vimium-style hint labels for on-screen PDF links.
/// Pure and AppKit-free: the app layer supplies the link count and drives the
/// typed query; this decides the label strings and which link a query selects.
public enum LinkHintLabels {
    /// Home-row-first alphabet: the earliest, easiest keys are used first so the
    /// common case (few links) needs the least finger travel.
    public static let defaultAlphabet = Array("fjdkslaghrueiwoncmpvtbyzxq")

    /// Returns `count` unique, equal-length (therefore prefix-free) labels drawn
    /// from `alphabet`. Equal length means a completed label is unambiguous — no
    /// label is a prefix of another, so typing never needs a terminator.
    public static func generate(count: Int, alphabet: [Character] = defaultAlphabet) -> [String] {
        guard count > 0 else { return [] }
        let base = alphabet.count
        precondition(base >= 2, "hint alphabet needs at least two characters")

        var length = 1
        var capacity = base
        while capacity < count {
            capacity *= base
            length += 1
        }

        return (0..<count).map { index in
            var value = index
            var characters: [Character] = []
            for _ in 0..<length {
                characters.append(alphabet[value % base])
                value /= base
            }
            return String(characters.reversed())
        }
    }
}

/// Pure query resolution over a set of hint labels.
public enum LinkHintFilter {
    /// Indices of every label that begins with `typed` (case-insensitive).
    public static func candidates(_ labels: [String], typed: String) -> [Int] {
        let query = typed.lowercased()
        guard !query.isEmpty else { return Array(labels.indices) }
        return labels.indices.filter { labels[$0].hasPrefix(query) }
    }

    /// The single label exactly equal to `typed`, if any (case-insensitive).
    public static func exactMatch(_ labels: [String], typed: String) -> Int? {
        let query = typed.lowercased()
        return labels.firstIndex(of: query)
    }
}
