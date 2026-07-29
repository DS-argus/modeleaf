import PDFReaderCore
import Testing

@Suite("Link hint filtering")
struct LinkHintFilterTests {
    private let labels = ["fa", "fj", "jd"]

    @Test("filtering ignores case")
    func filteringIgnoresCase() {
        #expect(LinkHintFilter.candidates(labels, typed: "F") == [0, 1])
        #expect(LinkHintFilter.exactMatch(labels, typed: "FJ") == 1)
    }

    @Test("shortening a query restores prefix candidates")
    func shorteningQueryRestoresCandidates() {
        #expect(LinkHintFilter.candidates(labels, typed: "fj") == [1])
        #expect(LinkHintFilter.candidates(labels, typed: "f") == [0, 1])
        #expect(LinkHintFilter.candidates(labels, typed: "") == [0, 1, 2])
    }

    @Test("filter classifies unique ambiguous and absent prefixes")
    func filterClassifiesMatches() {
        #expect(LinkHintFilter.filter(labels, typed: "") == .ambiguous)
        #expect(LinkHintFilter.filter(labels, typed: "f") == .ambiguous)
        #expect(LinkHintFilter.filter(labels, typed: "FJ") == .unique(1))
        #expect(LinkHintFilter.filter(labels, typed: "z") == .none)
    }
}
