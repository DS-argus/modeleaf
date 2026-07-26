import Foundation

/// Outcome of reading the persisted theme selection. Distinguishes the three
/// product-intended silent-default cases (file absent, unreadable/corrupt JSON,
/// unknown preset name) from genuine operational I/O failures, so the composition
/// root can default silently for the former but surface the latter.
public enum ThemeSelectionLoad: Equatable, Sendable {
    /// A valid, known preset was read.
    case selected(ThemeID)
    /// No state file yet — first run. Use the product default silently.
    case absent
    /// File exists but the contents are unusable (malformed JSON or an unknown
    /// preset name). Use the product default silently.
    case invalid
    /// The file could not be read for an operational reason (permissions, a
    /// directory at the path, other I/O). NOT an intended default case.
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

    /// The single hardcoded product default used when no valid selection exists.
    public static let productDefault: ThemeID = .catppuccinMocha

    public let fileURL: URL

    public init(fileURL: URL = ThemeSelectionStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// Reads the persisted selection, classifying the outcome so operational
    /// failures are not silently folded into the default.
    public func load() -> ThemeSelectionLoad {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return .absent
        } catch {
            return .ioError(message: String(describing: error))
        }
        guard let state = try? JSONDecoder().decode(State.self, from: data) else { return .invalid }
        guard let id = ThemeID(rawValue: state.selectedTheme) else { return .invalid }
        return .selected(id)
    }

    /// The selected theme when one was read, else nil for any non-selected
    /// outcome. Retained for callers that only need the optional.
    public func loadSelectedTheme() -> ThemeID? {
        if case let .selected(id) = load() { return id }
        return nil
    }

    /// Atomically persists the selection. Returns a result so the caller can
    /// surface a failure instead of treating a lost write as a durable commit.
    @discardableResult
    public func persist(_ id: ThemeID) -> ThemeSelectionPersist {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(State(selectedTheme: id.rawValue))
            try data.write(to: fileURL, options: .atomic)
            return .persisted
        } catch {
            return .failed(message: String(describing: error))
        }
    }

    /// The theme to use at startup: the persisted selection, else the product
    /// default. Operational read errors also fall back to the default (the app
    /// must still launch) but are exposed via `load()` for diagnostics.
    public func resolvedTheme() -> ThemeID {
        if case let .selected(id) = load() { return id }
        return Self.productDefault
    }

    private struct State: Codable {
        let selectedTheme: String

        enum CodingKeys: String, CodingKey {
            case selectedTheme = "selected_theme"
        }
    }
}
