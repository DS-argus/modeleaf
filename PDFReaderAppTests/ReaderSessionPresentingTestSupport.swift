import Foundation
@testable import PDFReaderApp

@MainActor
protocol HistoryNeutralTestSessionPresenting: ReaderSessionPresenting {}

extension HistoryNeutralTestSessionPresenting {
    var sourceURL: URL { URL(fileURLWithPath: "/tmp/\(title)") }
    var canGoBack: Bool { false }
    var canGoForward: Bool { false }
    var isNavigationHistoryHealthy: Bool { true }
    var navigationAvailabilityDetail: String { "History available" }

    @discardableResult
    func goBack() -> NavigationTransactionOutcome { .unavailable }

    @discardableResult
    func goForward() -> NavigationTransactionOutcome { .unavailable }
}
