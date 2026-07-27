import Foundation

/// One selectable row in the command palette: a registry action with its
/// human-readable title, the currently bound shortcut (if any), and whether it
/// is executable in the present context.
public struct PaletteCommand: Equatable, Sendable {
    public let id: ActionID
    public let title: String
    public let shortcut: String?
    public let isEnabled: Bool
    public let disabledReason: String?

    public init(
        id: ActionID,
        title: String,
        shortcut: String? = nil,
        isEnabled: Bool = true,
        disabledReason: String? = nil
    ) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
    }
}

/// Runtime state the palette consults to decide which commands can actually run
/// right now. Disabled commands are still shown (greyed) rather than hidden.
public struct PaletteContextState: Equatable, Sendable {
    public let hasActiveDocument: Bool
    public let paneCount: Int
    public let tabCount: Int
    public let inSearchResults: Bool

    public init(
        hasActiveDocument: Bool,
        paneCount: Int,
        tabCount: Int,
        inSearchResults: Bool
    ) {
        self.hasActiveDocument = hasActiveDocument
        self.paneCount = paneCount
        self.tabCount = tabCount
        self.inSearchResults = inSearchResults
    }
}

/// Pure rules for whether a command is executable in a given context/state.
public enum PaletteAvailability {
    public static let maximumPanes = 4

    public static func evaluate(
        _ id: ActionID,
        state: PaletteContextState
    ) -> (enabled: Bool, reason: String?) {
        // Global lifecycle commands never depend on an open document.
        switch id {
        case .documentOpen, .appNew, .appQuit:
            return (true, nil)
        default:
            break
        }

        guard state.hasActiveDocument else {
            return (false, "Open a PDF first")
        }

        switch id {
        case .tabNext, .tabPrevious:
            return state.tabCount > 1 ? (true, nil) : (false, "Only one tab is open")
        case .tabSelect1, .tabSelect2, .tabSelect3, .tabSelect4, .tabSelect5,
             .tabSelect6, .tabSelect7, .tabSelect8, .tabSelect9:
            let ordinal = tabOrdinal(id)
            return ordinal <= state.tabCount ? (true, nil) : (false, "No tab \(ordinal)")
        case .paneFocusLeft, .paneFocusRight, .paneFocusUp, .paneFocusDown, .paneUnsplit:
            return state.paneCount > 1 ? (true, nil) : (false, "Only one pane is open")
        case .paneSplitRight, .paneSplitDown:
            return state.paneCount < maximumPanes ? (true, nil) : (false, "Maximum panes open")
        case .searchCancel:
            return state.inSearchResults ? (true, nil) : (false, "No active search")
        default:
            return (true, nil)
        }
    }

    private static func tabOrdinal(_ id: ActionID) -> Int {
        switch id {
        case .tabSelect1: 1
        case .tabSelect2: 2
        case .tabSelect3: 3
        case .tabSelect4: 4
        case .tabSelect5: 5
        case .tabSelect6: 6
        case .tabSelect7: 7
        case .tabSelect8: 8
        case .tabSelect9: 9
        default: 0
        }
    }
}

/// Deterministic fuzzy filter/ranker over palette commands. An empty query
/// keeps every command in its original order; a non-empty query keeps only
/// commands whose title contains the query as a case-insensitive subsequence,
/// ranked by match quality (word-boundary and consecutive matches score higher,
/// shorter titles win ties), with original order breaking equal scores.
public enum CommandPaletteFilter {
    public static func rank(_ commands: [PaletteCommand], query: String) -> [PaletteCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return commands }

        let scored: [(command: PaletteCommand, score: Int, index: Int)] = commands.enumerated().compactMap { index, command in
            guard let score = fuzzyScore(query: trimmed, candidate: command.title) else { return nil }
            return (command, score, index)
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.index < rhs.index
            }
            .map(\.command)
    }

    /// Returns a match score, or `nil` when `query` is not a subsequence of
    /// `candidate` (case-insensitive).
    public static func fuzzyScore(query: String, candidate: String) -> Int? {
        let queryChars = Array(query.lowercased())
        guard !queryChars.isEmpty else { return 0 }
        let candidateChars = Array(candidate.lowercased())

        var score = 0
        var queryIndex = 0
        var previousMatch = -2
        for (position, character) in candidateChars.enumerated() {
            guard queryIndex < queryChars.count, character == queryChars[queryIndex] else { continue }
            score += 5
            if position == previousMatch + 1 { score += 15 }        // consecutive run
            if position == 0 {
                score += 20                                         // title start
            } else if isBoundary(candidateChars[position - 1]) {
                score += 15                                         // word boundary
            }
            previousMatch = position
            queryIndex += 1
        }
        guard queryIndex == queryChars.count else { return nil }
        score -= max(0, candidateChars.count - queryChars.count)    // favour tighter titles
        return score
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character == " " || character == "." || character == "-" || character == "_" || character == "/"
    }
}
