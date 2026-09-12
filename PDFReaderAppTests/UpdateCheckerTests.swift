import Foundation
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("Update checker")
@MainActor
struct UpdateCheckerTests {
    @Test("passes release metadata through and keeps updates without optional fields")
    func fetchesReleaseMetadata() async throws {
        let endpoint = URL(string: "https://api.github.com/repos/DS-argus/modeleaf/releases/latest")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateCheckerURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let checker = UpdateChecker(currentVersion: "0.2.0", endpoint: endpoint, session: session)
        defer { UpdateCheckerURLProtocol.setResponse(nil) }

        let releaseURL = "https://github.com/DS-argus/modeleaf/releases/tag/v0.3.0"
        let body = "## Highlights\n- Faster navigation\n\n## Notes\nDetails"
        UpdateCheckerURLProtocol.setResponse(json: [
            "tag_name": "v0.3.0",
            "body": body,
            "html_url": releaseURL
        ])
        let update = try #require(await checker.fetchUpdate())
        #expect(update.version == AppVersion("0.3.0"))
        #expect(update.highlights == "- Faster navigation")
        #expect(update.releaseURL == URL(string: releaseURL))

        UpdateCheckerURLProtocol.setResponse(json: ["tag_name": "v0.4.0"])
        let updateWithoutMetadata = try #require(await checker.fetchUpdate())
        #expect(updateWithoutMetadata.version == AppVersion("0.4.0"))
        #expect(updateWithoutMetadata.highlights == nil)
        #expect(updateWithoutMetadata.releaseURL == nil)

        UpdateCheckerURLProtocol.setResponse(json: [
            "tag_name": "v0.5.0",
            "html_url": "https://github.com/DS-argus/modeleaf/releases"
        ])
        let updateWithUnsafeURL = try #require(await checker.fetchUpdate())
        #expect(updateWithUnsafeURL.version == AppVersion("0.5.0"))
        #expect(updateWithUnsafeURL.releaseURL == nil)

        UpdateCheckerURLProtocol.setResponse(json: ["tag_name": "v0.6.0"], statusCode: 503)
        let nonOKResponse = await checker.fetchUpdate()
        #expect(nonOKResponse == nil)

        UpdateCheckerURLProtocol.setResponse(Data("not JSON".utf8))
        let malformedResponse = await checker.fetchUpdate()
        #expect(malformedResponse == nil)

        UpdateCheckerURLProtocol.setFailure(.notConnectedToInternet)
        let networkFailure = await checker.fetchUpdate()
        #expect(networkFailure == nil)

        UpdateCheckerURLProtocol.setResponse(json: ["tag_name": "v0.2.0"])
        let equalVersion = await checker.fetchUpdate()
        #expect(equalVersion == nil)

        UpdateCheckerURLProtocol.setResponse(json: ["tag_name": "v0.1.0"])
        let olderVersion = await checker.fetchUpdate()
        #expect(olderVersion == nil)
    }
}

private final class UpdateCheckerURLProtocol: URLProtocol {
    private struct StubResponse {
        let data: Data?
        let statusCode: Int
        let error: URLError?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var response: StubResponse?

    static func setResponse(json: [String: Any], statusCode: Int = 200) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else {
            setResponse(nil)
            return
        }
        setResponse(data, statusCode: statusCode)
    }

    static func setResponse(_ data: Data?, statusCode: Int = 200) {
        lock.lock()
        response = data.map { StubResponse(data: $0, statusCode: statusCode, error: nil) }
        lock.unlock()
    }

    static func setFailure(_ code: URLError.Code) {
        lock.lock()
        response = StubResponse(data: nil, statusCode: 0, error: URLError(code))
        lock.unlock()
    }

    private static func currentResponse() -> StubResponse? {
        lock.lock()
        defer { lock.unlock() }
        return response
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let client else { return }
        guard let url = request.url, let stub = Self.currentResponse() else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let error = stub.error {
            client.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let data = stub.data,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: stub.statusCode,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: data)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
