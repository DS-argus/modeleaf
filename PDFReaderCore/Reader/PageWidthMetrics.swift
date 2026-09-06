import Foundation

/// The page widths a continuous layout has to reconcile.
public struct PageWidthSummary: Equatable, Sendable {
    /// The width shared by the most pages: what fit-width should target.
    public let representative: CGFloat
    /// The widest page in the document: what a continuous layout has to be wide enough to hold.
    public let widest: CGFloat

    public init(representative: CGFloat, widest: CGFloat) {
        self.representative = representative
        self.widest = widest
    }

    /// Whether every page shares the representative width, so fitting the
    /// representative width and fitting the widest page are the same thing.
    public var isUniform: Bool {
        widest <= representative + PageWidthMetrics.groupingTolerance
    }
}

/// Pure page-width statistics.
///
/// A continuous layout can only apply one scale to the whole document, so a
/// single oversized page would otherwise shrink every ordinary page. These
/// statistics let the reader fit the width it is actually read at.
public enum PageWidthMetrics {
    /// Widths within this many points describe the same physical page size.
    public static let groupingTolerance: CGFloat = 1

    /// Summarizes page widths, or nil when none of them are usable.
    ///
    /// The representative width is the one shared by the most pages. Ties
    /// resolve to the larger width so that the fewest pages overflow.
    public static func summary(of widths: [CGFloat]) -> PageWidthSummary? {
        var buckets: [Int: (count: Int, width: CGFloat)] = [:]
        var widest: CGFloat = 0

        for width in widths where width.isFinite && width > 0 {
            widest = max(widest, width)
            let key = Int((width / groupingTolerance).rounded())
            var bucket = buckets[key] ?? (count: 0, width: width)
            bucket.count += 1
            bucket.width = max(bucket.width, width)
            buckets[key] = bucket
        }

        guard let winner = buckets.values.max(by: { lhs, rhs in
            lhs.count == rhs.count ? lhs.width < rhs.width : lhs.count < rhs.count
        }) else {
            return nil
        }
        return PageWidthSummary(representative: winner.width, widest: widest)
    }
}
