import Foundation

/// Outcome of reading the persisted theme selection. Distinguishes the three
/// product-intended silent-default cases (file absent, unreadable/corrupt JSON,
/// unknown preset name) from genuine operational I/O failures, so the composition
/// root can default silently for the former but surface the latter.
public enum ThemeSelectionLoad: Equatable, Sendable {
    case selected(ThemeID)
    case absent
    case invalid
    case ioError(message: String)
}

/// Result of persisting the theme selection. `.failed` means the durable write
/// did not happen even though the theme is applied for this session.
public enum ThemeSelectionPersist: Equatable, Sendable {
    case persisted
    case failed(message: String)
}

public struct ThemeSelectionStore: Sendable {
    public static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config", isDirectory: true)
        .appendingPathComponent("modeleaf", isDirectory: true)
        .appendingPathComponent("state.json", isDirectory: false)

    public static let productDefault: ThemeID = .tokyoNight

    public let fileURL: URL

    public init(fileURL: URL = ThemeSelectionStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// Reads only the theme field. A malformed recent-files sibling is ignored
    /// by StateFileStore's field-isolated decoding.
    public func load() -> ThemeSelectionLoad {
        switch StateFileStore(fileURL: fileURL).load() {
        case let .loaded(state):
            guard let selectedTheme = state.selectedTheme,
                  let id = ThemeID(rawValue: selectedTheme)
            else { return .invalid }
            return .selected(id)
        case .absent:
            return .absent
        case .invalid:
            return .invalid
        case let .ioError(message):
            return .ioError(message: message)
        }
    }

    public func loadSelectedTheme() -> ThemeID? {
        if case let .selected(id) = load() { return id }
        return nil
    }

    /// Updates only `selected_theme`, preserving recent_files and unowned keys.
    @discardableResult
    public func persist(_ id: ThemeID) -> ThemeSelectionPersist {
        switch StateFileStore(fileURL: fileURL).update(mutate: { state in
            state.selectedTheme = id.rawValue
        }) {
        case .persisted:
            return .persisted
        case let .failed(message):
            return .failed(message: message)
        }
    }

    public func resolvedTheme() -> ThemeID {
        if case let .selected(id) = load() { return id }
        return Self.productDefault
    }
}
