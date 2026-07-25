import Foundation

struct ReaderDuplicationSnapshot: Equatable, Sendable {
    let sourceURL: URL
    let oneBasedPage: Int
    let viewMode: ReaderViewMode
    let scaleFactor: Double
}

@MainActor
protocol ReaderDuplicationSnapshotProviding: AnyObject {
    var duplicationSnapshot: ReaderDuplicationSnapshot { get }
}
