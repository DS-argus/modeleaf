import PDFReaderCore
import Testing

@Suite("Page width metrics")
struct PageWidthMetricsTests {
    @Test("the width shared by the most pages represents the document")
    func representativeWidthIsTheMostCommonWidth() throws {
        let summary = try #require(PageWidthMetrics.summary(of: [515, 515, 2480, 515, 2480, 515]))

        #expect(summary.representative == 515)
        #expect(summary.widest == 2480)
        #expect(!summary.isUniform)
    }

    @Test("widths within the grouping tolerance describe one page size")
    func nearEqualWidthsGroupTogether() throws {
        let summary = try #require(PageWidthMetrics.summary(of: [612, 612.4, 611.8]))

        #expect(summary.representative == 612.4)
        #expect(summary.widest == 612.4)
        #expect(summary.isUniform)
    }

    @Test("a tie resolves to the larger width so the fewest pages overflow")
    func tiesResolveToTheLargerWidth() throws {
        let summary = try #require(PageWidthMetrics.summary(of: [400, 400, 800, 800]))

        #expect(summary.representative == 800)
        #expect(summary.widest == 800)
        #expect(summary.isUniform)
    }

    @Test("a single page size is uniform")
    func singlePageSizeIsUniform() throws {
        let summary = try #require(PageWidthMetrics.summary(of: [612, 612, 612]))

        #expect(summary.representative == 612)
        #expect(summary.isUniform)
    }

    @Test("unusable widths are ignored")
    func unusableWidthsAreIgnored() throws {
        #expect(PageWidthMetrics.summary(of: []) == nil)
        #expect(PageWidthMetrics.summary(of: [0, -10, .nan, .infinity]) == nil)

        let summary = try #require(PageWidthMetrics.summary(of: [0, 300, .nan, 300, 900]))
        #expect(summary.representative == 300)
        #expect(summary.widest == 900)
    }
}
