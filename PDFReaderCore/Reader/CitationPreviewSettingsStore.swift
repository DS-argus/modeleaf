import Foundation

public enum CitationPreviewSettingsLoad: Equatable, Sendable {
    case selected(Bool)
    case absent
    case invalid
    case ioError(message: String)
}

public enum CitationPreviewSettingsPersist: Equatable, Sendable {
    case persisted
    case failed(message: String)
}

public struct CitationPreviewSettingsStore: Sendable {
    public static let defaultFileURL = ThemeSelectionStore.defaultFileURL
    public static let productDefault = false

    public let fileURL: URL

    public init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    public func load() -> CitationPreviewSettingsLoad {
        switch StateFileStore(fileURL: fileURL).load() {
        case let .loaded(state):
            guard let enabled = state.citationPreviewEnabled else {
                return state.hasCitationPreviewEnabledField ? .invalid : .absent
            }
            return .selected(enabled)
        case .absent:
            return .absent
        case .invalid:
            return .invalid
        case let .ioError(message):
            return .ioError(message: message)
        }
    }

    @discardableResult
    public func persist(_ enabled: Bool) -> CitationPreviewSettingsPersist {
        switch StateFileStore(fileURL: fileURL).update(mutate: { state in
            state.citationPreviewEnabled = enabled
        }) {
        case .persisted:
            return .persisted
        case let .failed(message):
            return .failed(message: message)
        }
    }
}
