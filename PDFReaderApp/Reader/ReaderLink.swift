import AppKit
import PDFKit

/// A single hintable link region on the currently visible PDF page(s). A link
/// that wraps across lines is stored as several targets (one per annotation)
/// that all resolve to the same destination.
struct ReaderLinkTarget {
    /// Link rectangle in the coordinate space requested from `linkTargets(in:)`.
    /// One rectangle per visual line: a link that wraps spans several. All are
    /// outlined; the badge sits on the first (topmost) rect.
    let rects: [NSRect]
    let kind: ReaderLinkKind

    var primaryRect: NSRect { rects.first ?? .zero }
}

enum ReaderLinkKind {
    /// An in-document jump (table-of-contents style). Followed inside the viewer.
    case destination(PDFDestination)
    /// An external URL. The shell decides how to open it (browser).
    case url(URL)
}

/// What happened when a link was activated, so the caller can complete external
/// handling without the session reaching outside the viewer itself.
enum ReaderLinkActivation: Equatable {
    case navigatedInDocument
    case openExternal(URL)
    case unsupported
}

/// Read-only link access for the active reader session. Kept separate from
/// `ReaderSessionPresenting` so only the real session implements it (test doubles
/// simply aren't link providers, which the shell treats as "no links").
@MainActor
protocol ReaderLinkProviding: AnyObject {
    /// Every link on the visible page(s), with rects converted into
    /// `coordinateSpace` (a view in the same window as the PDF canvas).
    func linkTargets(in coordinateSpace: NSView) -> [ReaderLinkTarget]

    /// Follows an in-document destination immediately; returns `.openExternal`
    /// for URLs so the shell opens them. Never mutates the source PDF.
    @discardableResult
    func activateLink(_ target: ReaderLinkTarget) -> ReaderLinkActivation
}
