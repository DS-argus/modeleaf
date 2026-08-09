import Foundation
import PDFReaderCore
import Testing

@Suite("Link hint merging")
struct LinkHintMergeTests {
    private let url = ReaderLinkTarget.url("https://example.com")

    @Test("adjacent same-destination annotations remain independent")
    func adjacentSameDestinationRemainsSeparate() {
        let links = mergeLinks([
            raw(0, rect(10, 100, 40, 9.2)),
            raw(0, rect(10, 88.8, 40, 9.2)),
        ])

        #expect(links.count == 2)
        #expect(links.allSatisfy { $0.rects.count == 1 })
        #expect(links.map(\.primaryLabelRect.origin.y) == [100, 88.8])
    }

    @Test("exact duplicate annotations coalesce")
    func exactDuplicatesCoalesce() {
        let duplicate = raw(0, rect(10, 100, 40, 9.2))
        let links = mergeLinks([duplicate, duplicate])

        #expect(links.count == 1)
        #expect(links[0].rects.count == 1)
        #expect(links[0].rects.first?.origin.x == duplicate.pageSpaceBounds.origin.x)
        #expect(links[0].rects.first?.origin.y == duplicate.pageSpaceBounds.origin.y)
        #expect(links[0].rects.first?.size.width == duplicate.pageSpaceBounds.size.width)
        #expect(links[0].rects.first?.size.height == duplicate.pageSpaceBounds.size.height)
    }

    @Test("overlapping QR and text links remain separate")
    func overlappingQRAndTextRemainSeparate() {
        let links = mergeLinks([
            raw(0, rect(0, 100, 68, 69)),
            raw(0, rect(80, 100, 100, 10)),
        ])
        #expect(links.count == 2)
    }

    @Test("distant mentions of the same URL remain separate")
    func distantSameURLRemainsSeparate() {
        #expect(mergeLinks([
            raw(0, rect(0, 100, 10, 10)),
            raw(0, rect(0, 0, 10, 10)),
        ]).count == 2)
    }

    @Test("adjacent rectangles with different targets remain separate")
    func differentTargetsRemainSeparate() {
        let links = mergeLinks([
            raw(0, rect(0, 100, 10, 10), target: .url("https://one.example")),
            raw(0, rect(0, 84, 10, 10), target: .url("https://two.example")),
        ])
        #expect(links.count == 2)
    }

    @Test("ordering is deterministic across provider permutations")
    func mergeOrderIsDeterministic() {
        let input = [
            raw(0, rect(20, 50, 10, 10), target: .url("https://example.com/other")),
            raw(0, rect(10, 100, 10, 10), target: .goTo(pageIndex: 3, point: CGPoint(x: 1.5, y: 40))),
            raw(0, rect(10, 84, 10, 10), target: .goTo(pageIndex: 3, point: CGPoint(x: 0, y: 40))),
            raw(0, rect(10, 68, 10, 10), target: .goTo(pageIndex: 3, point: CGPoint(x: 3, y: 40))),
        ]
        let expected = mergeLinks(input)

        #expect(mergeLinks(Array(input.reversed())) == expected)
        #expect(mergeLinks([input[2], input[0], input[3], input[1]]) == expected)
        #expect(mergeLinks([input[1], input[3], input[0], input[2]]) == expected)
        #expect(expected.map(\.primaryLabelRect.origin.y) == [100, 84, 68, 50])
    }

    @Test("same target on separate source pages remains separate")
    func separateSourcePagesRemainSeparate() {
        #expect(mergeLinks([
            raw(0, rect(0, 100, 10, 10)),
            raw(1, rect(0, 100, 10, 10)),
        ]).count == 2)
    }

    @Test("nearby GoTo points remain independent without exact duplicate evidence")
    func nearbyGoToPointsRemainSeparate() {
        let base = ReaderLinkTarget.goTo(pageIndex: 3, point: CGPoint(x: 0, y: 0))
        let nearby = ReaderLinkTarget.goTo(pageIndex: 3, point: CGPoint(x: 0.01, y: 0))

        #expect(mergeLinks([
            raw(0, rect(0, 100, 10, 10), target: base),
            raw(0, rect(0, 84, 10, 10), target: nearby),
        ]).count == 2)
    }

    private func raw(_ page: Int, _ bounds: CGRect, target: ReaderLinkTarget? = nil) -> RawLink {
        RawLink(sourcePageIndex: page, pageSpaceBounds: bounds, target: target ?? url)
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
    }
}
