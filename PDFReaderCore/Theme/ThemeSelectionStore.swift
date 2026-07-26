import Foundation

public struct ThemeSelectionStore: Sendable {
    public static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config", isDirectory: true)
        .appendingPathComponent("modeleaf", isDirectory: true)
        .appendingPathComponent("state.json", isDirectory: false)

    public let fileURL: URL

    public init(fileURL: URL = ThemeSelectionStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public func loadSelectedTheme() -> ThemeID? {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else {
            return nil
        }
        return ThemeID(rawValue: state.selectedTheme)
    }

    public func persist(_ id: ThemeID) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(State(selectedTheme: id.rawValue))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence is best-effort; the selected theme remains usable for this session.
        }
    }

    public func resolvedTheme(default fallback: ThemeID = .catppuccinMocha) -> ThemeID {
        loadSelectedTheme() ?? fallback
    }

    private struct State: Codable {
        let selectedTheme: String

        enum CodingKeys: String, CodingKey {
            case selectedTheme = "selected_theme"
        }
    }
}
