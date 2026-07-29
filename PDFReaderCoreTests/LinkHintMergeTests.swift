import Foundation
import PDFReaderCore
import Testing

@Suite("Link hint merging")
struct LinkHintMergeTests {
    private let url = ReaderLinkTarget.url("https://example.com")

    @Test("t1: line-wrapped text merges into one two-rect hint")
    func wrappedTextMerges() {
        let links = mergeLinks([
            raw(0, rect(10, 100, 40, 9.2)),
            raw(0, rect(10, 88.8, 40, 9.2)),
        ])
        #expect(links.count == 1)
        #expect(links[0].rects.count == 2)
        #expect(links[0].primaryLabelRect.origin.x == 10)
        #expect(links[0].primaryLabelRect.origin.y == 100)
    }

    @Test("t2: overlapping QR and text links remain separate")
    func overlappingQRAndTextRemainSeparate() {
        let links = mergeLinks([
            raw(0, rect(0, 100, 68, 69)),
            raw(0, rect(80, 100, 100, 10)),
        ])
        #expect(links.count == 2)
    }

    @Test("t3: maximum positive vertical gap is included")
    func positiveVerticalGapBoundary() {
        #expect(mergeLinks([raw(0, rect(0, 100, 10, 10)), raw(0, rect(0, 84, 10, 10))]).count == 1)
        #expect(mergeLinks([raw(0, rect(0, 100, 10, 10)), raw(0, rect(0, 83.9, 10, 10))]).count == 2)
    }

    @Test("t4: maximum overlap is included")
    func negativeVerticalGapBoundary() {
        #expect(mergeLinks([raw(0, rect(0, 100, 10, 10)), raw(0, rect(0, 91, 10, 10))]).count == 1)
        #expect(mergeLinks([raw(0, rect(0, 100, 10, 10)), raw(0, rect(0, 91.1, 10, 10))]).count == 2)
    }

    @Test("t5: height-ratio boundary is included")
    func heightRatioBoundary() {
        #expect(mergeLinks([raw(0, rect(0, 100, 10, 15)), raw(0, rect(0, 84, 10, 10))]).count == 1)
        #expect(mergeLinks([raw(0, rect(0, 100, 10, 15.1)), raw(0, rect(0, 84, 10, 10))]).count == 2)
    }

    @Test("t6: distant mentions of the same URL remain separate")
    func distantSameURLRemainsSeparate() {
        #expect(mergeLinks([raw(0, rect(0, 100, 10, 10)), raw(0, rect(0, 0, 10, 10))]).count == 2)
    }

    @Test("t7: adjacent rectangles with different targets remain separate")
    func differentTargetsRemainSeparate() {
        let links = mergeLinks([
            raw(0, rect(0, 100, 10, 10), target: .url("https://one.example")),
            raw(0, rect(0, 84, 10, 10), target: .url("https://two.example")),
        ])
        #expect(links.count == 2)
    }

    @Test("t8: merge order is deterministic across provider permutations")
    func mergeOrderIsDeterministic() {
        let near = ReaderLinkTarget.goTo(pageIndex: 3, point: CGPoint(x: 1.5, y: 40))
        let base = ReaderLinkTarget.goTo(pageIndex: 3, point: CGPoint(x: 0, y: 40))
        let beyond = ReaderLinkTarget.goTo(pageIndex: 3, point: CGPoint(x: 3, y: 40))
        let input = [
            raw(0, rect(20, 50, 10, 10), target: .url("https://example.com/other")),
            raw(0, rect(10, 100, 10, 10), target: near),
            raw(0, rect(10, 84, 10, 10), target: base),
            raw(0, rect(10, 68, 10, 10), target: beyond),
        ]
        let expected = mergeLinks(input)
        #expect(mergeLinks(Array(input.reversed())) == expected)
        #expect(mergeLinks([input[2], input[0], input[3], input[1]]) == expected)
        #expect(mergeLinks([input[1], input[3], input[0], input[2]]) == expected)
        #expect(expected.contains { $0.target == base && $0.rects.count == 2 })
    }

    @Test("t9: same target on separate source pages remains separate")
    func separateSourcePagesRemainSeparate() {
        #expect(mergeLinks([raw(0, rect(0, 100, 10, 10)), raw(1, rect(0, 100, 10, 10))]).count == 2)
    }

    @Test("t10: GoTo points use an inclusive two-point tolerance")
    func goToPointToleranceBoundary() {
        let base = ReaderLinkTarget.goTo(pageIndex: 3, point: CGPoint(x: 0, y: 0))
        let within = ReaderLinkTarget.goTo(pageIndex: 3, point: CGPoint(x: 2, y: 0))
        let beyond = ReaderLinkTarget.goTo(pageIndex: 3, point: CGPoint(x: 2.01, y: 0))
        #expect(mergeLinks([raw(0, rect(0, 100, 10, 10), target: base), raw(0, rect(0, 84, 10, 10), target: within)]).count == 1)
        #expect(mergeLinks([raw(0, rect(0, 100, 10, 10), target: base), raw(0, rect(0, 84, 10, 10), target: beyond)]).count == 2)
    }

    private func raw(_ page: Int, _ bounds: CGRect, target: ReaderLinkTarget? = nil) -> RawLink {
        RawLink(sourcePageIndex: page, pageSpaceBounds: bounds, target: target ?? url)
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
    }
}
