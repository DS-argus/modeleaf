import Foundation

public struct RecentFileMatch: Equatable, Sendable {
    public let entry: RecentFileEntry
    public let matchedIndices: [Int]

    public init(entry: RecentFileEntry, matchedIndices: [Int]) {
        self.entry = entry
        self.matchedIndices = matchedIndices
    }
}

public enum RecentFileFilter {
    public static func rank(_ entries: [RecentFileEntry], query: String) -> [RecentFileMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return entries.map { RecentFileMatch(entry: $0, matchedIndices: []) }
        }

        let scored: [(match: RecentFileMatch, score: Int, index: Int)] = entries.enumerated().compactMap { index, entry in
            let filename = URL(fileURLWithPath: entry.absolutePath).lastPathComponent
            guard let score = CommandPaletteFilter.fuzzyScore(query: trimmed, candidate: filename),
                  let matchedIndices = subsequenceIndices(query: trimmed, candidate: filename)
            else { return nil }
            return (RecentFileMatch(entry: entry, matchedIndices: matchedIndices), score, index)
        }
        return scored.sorted {
            $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score
        }.map(\.match)
    }

    private static func subsequenceIndices(query: String, candidate: String) -> [Int]? {
        let queryCharacters = Array(query.lowercased())
        let candidateCharacters = Array(candidate.lowercased())
        var queryIndex = 0
        var indices: [Int] = []
        for (index, character) in candidateCharacters.enumerated() where queryIndex < queryCharacters.count {
            if character == queryCharacters[queryIndex] {
                indices.append(index)
                queryIndex += 1
            }
        }
        return queryIndex == queryCharacters.count ? indices : nil
    }
}
