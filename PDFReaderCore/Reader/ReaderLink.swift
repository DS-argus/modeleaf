import Foundation

public enum ReaderLinkTarget: Equatable, Sendable {
    case url(String)
    case goTo(pageIndex: Int, point: CGPoint?)

    public static func == (lhs: ReaderLinkTarget, rhs: ReaderLinkTarget) -> Bool {
        switch (lhs, rhs) {
        case let (.url(lhsURL), .url(rhsURL)):
            lhsURL == rhsURL
        case let (.goTo(lhsPageIndex, lhsPoint), .goTo(rhsPageIndex, rhsPoint)):
            lhsPageIndex == rhsPageIndex && pointsEqual(lhsPoint, rhsPoint)
        default:
            false
        }
    }
}

public struct RawLink: Equatable, Sendable {
    public let sourcePageIndex: Int
    public let pageSpaceBounds: CGRect
    public let target: ReaderLinkTarget

    public init(sourcePageIndex: Int, pageSpaceBounds: CGRect, target: ReaderLinkTarget) {
        self.sourcePageIndex = sourcePageIndex
        self.pageSpaceBounds = pageSpaceBounds
        self.target = target
    }

    public static func == (lhs: RawLink, rhs: RawLink) -> Bool {
        lhs.sourcePageIndex == rhs.sourcePageIndex
            && rectsEqual(lhs.pageSpaceBounds, rhs.pageSpaceBounds)
            && lhs.target == rhs.target
    }
}

public struct ReaderLink: Equatable, Sendable {
    public let sourcePageIndex: Int
    public let rects: [CGRect]
    public let target: ReaderLinkTarget
    public let primaryLabelRect: CGRect

    public init(
        sourcePageIndex: Int,
        rects: [CGRect],
        target: ReaderLinkTarget,
        primaryLabelRect: CGRect
    ) {
        self.sourcePageIndex = sourcePageIndex
        self.rects = rects
        self.target = target
        self.primaryLabelRect = primaryLabelRect
    }

    public static func == (lhs: ReaderLink, rhs: ReaderLink) -> Bool {
        lhs.sourcePageIndex == rhs.sourcePageIndex
            && lhs.rects.elementsEqual(rhs.rects, by: rectsEqual)
            && lhs.target == rhs.target
            && rectsEqual(lhs.primaryLabelRect, rhs.primaryLabelRect)
    }
}

private func pointsEqual(_ lhs: CGPoint?, _ rhs: CGPoint?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        true
    case let (.some(lhs), .some(rhs)):
        lhs.x == rhs.x && lhs.y == rhs.y
    default:
        false
    }
}

private func rectsEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    lhs.origin.x == rhs.origin.x
        && lhs.origin.y == rhs.origin.y
        && lhs.size.width == rhs.size.width
        && lhs.size.height == rhs.size.height
}
