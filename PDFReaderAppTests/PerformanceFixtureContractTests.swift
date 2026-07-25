import PDFReaderTestSupport
import Testing

@Suite("Performance PDF fixture contract")
@MainActor
struct PerformanceFixtureContractTests {
    @Test("fixture identities, page counts, and names remain stable")
    func stableFixtureMetadata() {
        #expect(PerformancePDFFixtureKind.allCases == [.S, .L, .F, .B])
        #expect(PerformancePDFFixtureKind.S.fileName == "fixture-S-text-10.pdf")
        #expect(PerformancePDFFixtureKind.L.fileName == "fixture-L-text-300.pdf")
        #expect(PerformancePDFFixtureKind.F.fileName == "fixture-F-raster-12.pdf")
        #expect(PerformancePDFFixtureKind.B.fileName == "fixture-B-blank.pdf")
        #expect(PerformancePDFFixtureKind.S.pageCount == 10)
        #expect(PerformancePDFFixtureKind.L.pageCount == 300)
        #expect(PerformancePDFFixtureKind.F.pageCount == 12)
        #expect(PerformancePDFFixtureKind.B.pageCount == 1)
    }

    @Test("nonblank fixtures use distinct visible sentinels")
    func visibleSentinelContract() {
        let sentinels = [
            PerformancePDFFixtureKind.S,
            .L,
            .F,
        ].compactMap(PDFFixtureFactory.performanceSentinel(for:))

        #expect(sentinels.count == 3)
        #expect(Set(sentinels.map(\.pattern)).count == 3)
        #expect(sentinels.allSatisfy { $0.width > 0 && $0.height > 0 })
        #expect(PDFFixtureFactory.performanceSentinel(for: .B) == nil)
        #expect(PDFFixtureFactory.performanceFixtureGeneratorVersion == "1")
    }
}
