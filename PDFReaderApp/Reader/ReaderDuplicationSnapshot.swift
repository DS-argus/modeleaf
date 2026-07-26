import Foundation

/// The split-duplicate contract: a duplicated pane opens the SAME page as its
/// source but always fit-to-page in its own (smaller) pane. View mode and zoom
/// are intentionally NOT carried — preserving an absolute manual zoom into a
/// half-size pane made the page overflow and feel "too big" (user review,
/// 2026-07-26). Same reading position is kept; the zoom fits the new pane.
struct ReaderDuplicationSnapshot: Equatable, Sendable {
    let sourceURL: URL
    let oneBasedPage: Int
}

@MainActor
protocol ReaderDuplicationSnapshotProviding: AnyObject {
    var duplicationSnapshot: ReaderDuplicationSnapshot { get }
}
