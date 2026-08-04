import Foundation
import PDFReaderCore

/// A split duplicate preserves only a verified PDF page-space reading position.
/// Its presentation remains fit-to-page in the destination pane.
struct ReaderDuplicationSnapshot: Equatable, Sendable {
    let sourceURL: URL
    let navigation: NavigationSnapshot
}

@MainActor
protocol ReaderDuplicationSnapshotProviding: AnyObject {
    var duplicationSnapshot: ReaderDuplicationSnapshot? { get }
}
