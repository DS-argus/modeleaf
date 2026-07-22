import Foundation

public enum InputContext: String, CaseIterable, Codable, Hashable, Sendable {
    case navigation
    case pagePrompt
    case searchPrompt
    case searchResults

    public static let promptContexts: Set<InputContext> = [.pagePrompt, .searchPrompt]
}
