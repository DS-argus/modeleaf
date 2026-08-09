import Foundation

/// Produces deterministic hint targets while coalescing only exact duplicate annotations.
///
/// A shared destination and adjacent geometry are not sufficient evidence that two PDF
/// annotations are fragments of one logical link. PDF generators commonly emit separate
/// table-of-contents entries that share the same destination. Keeping distinct annotations
/// independent is safer; a wrapped link may receive multiple hints rather than hiding a
/// separately clickable entry.
public enum LinkHintMerge {
    public static func mergeLinks(_ raw: [RawLink]) -> [ReaderLink] {
        var unique: [RawLink] = []

        for link in raw.sorted(by: isBeforeCanonicalOrder) where !unique.contains(link) {
            unique.append(link)
        }

        return unique.map { link in
            ReaderLink(
                sourcePageIndex: link.sourcePageIndex,
                rects: [link.pageSpaceBounds],
                target: link.target,
                primaryLabelRect: link.pageSpaceBounds
            )
        }
    }

    private static func isBeforeCanonicalOrder(_ lhs: RawLink, _ rhs: RawLink) -> Bool {
        if lhs.sourcePageIndex != rhs.sourcePageIndex {
            return lhs.sourcePageIndex < rhs.sourcePageIndex
        }
        if isBeforeInReadingOrder(lhs.pageSpaceBounds, rhs.pageSpaceBounds) { return true }
        if isBeforeInReadingOrder(rhs.pageSpaceBounds, lhs.pageSpaceBounds) { return false }
        return isBeforeTargetCanonicalOrder(lhs.target, rhs.target)
    }

    private static func isBeforeInReadingOrder(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        if minY(lhs) != minY(rhs) {
            return minY(lhs) > minY(rhs)
        }
        return minX(lhs) < minX(rhs)
    }

    private static func isBeforeTargetCanonicalOrder(_ lhs: ReaderLinkTarget, _ rhs: ReaderLinkTarget) -> Bool {
        switch (lhs, rhs) {
        case let (.url(lhsURL), .url(rhsURL)):
            return lhsURL < rhsURL
        case (.url, .goTo):
            return true
        case (.goTo, .url):
            return false
        case let (.goTo(lhsPage, lhsPoint), .goTo(rhsPage, rhsPoint)):
            if lhsPage != rhsPage { return lhsPage < rhsPage }
            switch (lhsPoint, rhsPoint) {
            case (nil, .some): return true
            case (.some, nil): return false
            case (nil, nil): return false
            case let (.some(lhsPoint), .some(rhsPoint)):
                if lhsPoint.y != rhsPoint.y { return lhsPoint.y > rhsPoint.y }
                return lhsPoint.x < rhsPoint.x
            }
        }
    }

    private static func minX(_ rect: CGRect) -> CGFloat {
        min(rect.origin.x, rect.origin.x + rect.size.width)
    }

    private static func minY(_ rect: CGRect) -> CGFloat {
        min(rect.origin.y, rect.origin.y + rect.size.height)
    }
}

public func mergeLinks(_ raw: [RawLink]) -> [ReaderLink] {
    LinkHintMerge.mergeLinks(raw)
}
