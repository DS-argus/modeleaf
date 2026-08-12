import Foundation

public enum LinkDestinationIndicatorSettingsLoad: Equatable, Sendable {
    case selected(LinkDestinationIndicatorSettings)
    case absent
    case invalid
    case ioError(message: String)
}

public enum LinkDestinationIndicatorSettingsPersist: Equatable, Sendable {
    case persisted
    case failed(message: String)
}

public struct LinkDestinationIndicatorSettingsStore: Sendable {
    public static let defaultFileURL = ThemeSelectionStore.defaultFileURL
    public static let productDefault = LinkDestinationIndicatorSettings.standard

    public let fileURL: URL

    public init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    public func load() -> LinkDestinationIndicatorSettingsLoad {
        switch StateFileStore(fileURL: fileURL).load() {
        case let .loaded(state):
            guard let dto = state.linkDestinationIndicator else {
                return state.hasLinkDestinationIndicatorField ? .invalid : .absent
            }
            guard let style = LinkDestinationIndicatorStyle(rawValue: dto.style),
                  let color = LinkDestinationIndicatorColor(configurationValue: dto.color),
                  LinkDestinationIndicatorSettings.sizeRange.contains(dto.size),
                  LinkDestinationIndicatorSettings.durationMillisecondsRange.contains(dto.durationMilliseconds)
            else { return .invalid }
            return .selected(LinkDestinationIndicatorSettings(
                style: style,
                color: color,
                size: dto.size,
                durationMilliseconds: dto.durationMilliseconds
            ))
        case .absent:
            return .absent
        case .invalid:
            return .invalid
        case let .ioError(message):
            return .ioError(message: message)
        }
    }

    @discardableResult
    public func persist(_ settings: LinkDestinationIndicatorSettings) -> LinkDestinationIndicatorSettingsPersist {
        let dto = LinkDestinationIndicatorStateDTO(
            style: settings.style.rawValue,
            color: settings.color.configurationValue,
            size: settings.size,
            durationMilliseconds: settings.durationMilliseconds
        )
        switch StateFileStore(fileURL: fileURL).update(mutate: { state in
            state.linkDestinationIndicator = dto
        }) {
        case .persisted:
            return .persisted
        case let .failed(message):
            return .failed(message: message)
        }
    }
}
