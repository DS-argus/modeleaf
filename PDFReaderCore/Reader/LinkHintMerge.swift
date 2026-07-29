import Foundation

/// Coalesces the rectangles of a logical PDF link into reading-order hint targets.
public enum LinkHintMerge {
    public static let destinationPointTolerance: CGFloat = 2.0

    public static func mergeLinks(_ raw: [RawLink]) -> [ReaderLink] {
        var buckets: [Bucket] = []

        for link in raw.sorted(by: isBeforeCanonicalOrder) {
            if let index = buckets.firstIndex(where: { $0.sourcePageIndex == link.sourcePageIndex && targetsMatch($0.target, link.target) }) {
                buckets[index].links.append(link)
            } else {
                buckets.append(Bucket(sourcePageIndex: link.sourcePageIndex, target: link.target, links: [link]))
            }
        }

        var merged: [ReaderLink] = []
        for bucket in buckets {
            let ordered = bucket.links.sorted(by: isBeforeInReadingOrder)
            var chain: [RawLink] = []

            for link in ordered {
                guard let previous = chain.last else {
                    chain.append(link)
                    continue
                }

                if shouldChain(previous.pageSpaceBounds, link.pageSpaceBounds) {
                    chain.append(link)
                } else {
                    merged.append(makeReaderLink(chain, target: bucket.target))
                    chain = [link]
                }
            }

            if !chain.isEmpty {
                merged.append(makeReaderLink(chain, target: bucket.target))
            }
        }

        return merged.sorted { lhs, rhs in
            if lhs.sourcePageIndex != rhs.sourcePageIndex {
                return lhs.sourcePageIndex < rhs.sourcePageIndex
            }
            return isBeforeInReadingOrder(lhs.primaryLabelRect, rhs.primaryLabelRect)
        }
    }

    private struct Bucket {
        let sourcePageIndex: Int
        let target: ReaderLinkTarget
        var links: [RawLink]
    }

    private static func makeReaderLink(_ chain: [RawLink], target: ReaderLinkTarget) -> ReaderLink {
        ReaderLink(
            sourcePageIndex: chain[0].sourcePageIndex,
            rects: chain.map(\.pageSpaceBounds),
            target: target,
            primaryLabelRect: chain[0].pageSpaceBounds
        )
    }

    private static func targetsMatch(_ lhs: ReaderLinkTarget, _ rhs: ReaderLinkTarget) -> Bool {
        switch (lhs, rhs) {
        case let (.url(lhsURL), .url(rhsURL)):
            return lhsURL == rhsURL
        case let (.goTo(lhsPageIndex, lhsPoint), .goTo(rhsPageIndex, rhsPoint)):
            guard lhsPageIndex == rhsPageIndex else { return false }
            switch (lhsPoint, rhsPoint) {
            case (nil, nil):
                return true
            case let (.some(lhsPoint), .some(rhsPoint)):
                let deltaX = lhsPoint.x - rhsPoint.x
                let deltaY = lhsPoint.y - rhsPoint.y
                return deltaX * deltaX + deltaY * deltaY <= destinationPointTolerance * destinationPointTolerance
            default:
                return false
            }
        default:
            return false
        }
    }

    private static func isBeforeInReadingOrder(_ lhs: RawLink, _ rhs: RawLink) -> Bool {
        isBeforeInReadingOrder(lhs.pageSpaceBounds, rhs.pageSpaceBounds)
    }

    private static func isBeforeInReadingOrder(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        if minY(lhs) != minY(rhs) {
            return minY(lhs) > minY(rhs)
        }
        return minX(lhs) < minX(rhs)
    }

    private static func isBeforeCanonicalOrder(_ lhs: RawLink, _ rhs: RawLink) -> Bool {
        if lhs.sourcePageIndex != rhs.sourcePageIndex {
            return lhs.sourcePageIndex < rhs.sourcePageIndex
        }
        if isBeforeTargetCanonicalOrder(lhs.target, rhs.target) { return true }
        if isBeforeTargetCanonicalOrder(rhs.target, lhs.target) { return false }
        return isBeforeRectCanonicalOrder(lhs.pageSpaceBounds, rhs.pageSpaceBounds)
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

    private static func isBeforeRectCanonicalOrder(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        if minY(lhs) != minY(rhs) { return minY(lhs) > minY(rhs) }
        if minX(lhs) != minX(rhs) { return minX(lhs) < minX(rhs) }
        if height(lhs) != height(rhs) { return height(lhs) < height(rhs) }
        let lhsWidth = abs(lhs.size.width)
        let rhsWidth = abs(rhs.size.width)
        if lhsWidth != rhsWidth { return lhsWidth < rhsWidth }
        return maxY(lhs) < maxY(rhs)
    }
    private static func shouldChain(_ upper: CGRect, _ lower: CGRect) -> Bool {
        let upperHeight = height(upper)
        let lowerHeight = height(lower)
        let minimumHeight = min(upperHeight, lowerHeight)
        guard minimumHeight > 0 else { return false }

        let heightRatio = max(upperHeight, lowerHeight) / minimumHeight
        guard heightRatio <= 1.5 else { return false }

        let verticalGap = minY(upper) - maxY(lower)
        return verticalGap >= -1.0 && verticalGap <= 0.6 * minimumHeight
    }

    private static func minX(_ rect: CGRect) -> CGFloat { min(rect.origin.x, rect.origin.x + rect.size.width) }
    private static func minY(_ rect: CGRect) -> CGFloat { min(rect.origin.y, rect.origin.y + rect.size.height) }
    private static func maxY(_ rect: CGRect) -> CGFloat { max(rect.origin.y, rect.origin.y + rect.size.height) }
    private static func height(_ rect: CGRect) -> CGFloat { abs(rect.size.height) }
}

public func mergeLinks(_ raw: [RawLink]) -> [ReaderLink] {
    LinkHintMerge.mergeLinks(raw)
}
