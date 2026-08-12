import AppKit
import PDFReaderCore

/// Fetches the latest published release and returns structured availability
/// when it is newer than the running build. Every failure path (offline,
/// rate-limited, malformed) resolves to `nil` — an update check must never
/// interrupt a read-only viewer.
@MainActor
final class UpdateChecker {
    private let currentVersion: String
    private let endpoint: URL
    private let session: URLSession

    init(
        currentVersion: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0",
        endpoint: URL = URL(string: "https://api.github.com/repos/DS-argus/modeleaf/releases/latest")!,
        session: URLSession = .shared
    ) {
        self.currentVersion = currentVersion
        self.endpoint = endpoint
        self.session = session
    }

    func fetchUpdate() async -> AvailableUpdate? {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String
        else { return nil }
        return UpdateNotice.availableUpdate(current: currentVersion, latest: tag)
    }
}
