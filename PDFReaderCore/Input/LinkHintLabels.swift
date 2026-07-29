import Foundation

/// Generates Vimium-style, prefix-free labels for on-screen PDF links.
public enum LinkHintLabels {
    /// Home-row-first alphabet so common hints use the easiest keys.
    public static let defaultAlphabet = Array("fjdkslaghrueiwoncmpvtbyzxq")

    /// Returns unique labels of one shared length. Equal lengths make the labels
    /// prefix-free and ensure a completed label is unambiguous.
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
