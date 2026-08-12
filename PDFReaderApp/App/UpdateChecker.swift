import AppKit
import PDFReaderCore

/// Decides whether the running copy is a Homebrew cask or a manual download, so
/// the update banner shows the right instruction.
enum InstallSourceDetector {
    static let caskroomPaths = ["/opt/homebrew/Caskroom/modeleaf", "/usr/local/Caskroom/modeleaf"]

    static func detect(bundleURL: URL = Bundle.main.bundleURL) -> InstallSource {
        let bundlePath = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        return caskroomPaths.contains { root in
            bundlePath == root || bundlePath.hasPrefix(root + "/")
        } ? .homebrew : .manual
    }
}

/// Fetches the latest published release and returns structured availability
/// when it is newer than the running build. Every failure path (offline,
/// rate-limited, malformed) resolves to `nil` — an update check must never
/// interrupt a read-only viewer.
@MainActor
final class UpdateChecker {
    static let releasesPage = URL(string: "https://github.com/DS-argus/modeleaf/releases/latest")!

    private let currentVersion: String
    private let endpoint: URL
    private let session: URLSession
    private let source: InstallSource

    init(
        currentVersion: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0",
        endpoint: URL = URL(string: "https://api.github.com/repos/DS-argus/modeleaf/releases/latest")!,
        session: URLSession = .shared,
        source: InstallSource = InstallSourceDetector.detect()
    ) {
        self.currentVersion = currentVersion
        self.endpoint = endpoint
        self.session = session
        self.source = source
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
        return UpdateNotice.availableUpdate(current: currentVersion, latest: tag, source: source)
    }
}
