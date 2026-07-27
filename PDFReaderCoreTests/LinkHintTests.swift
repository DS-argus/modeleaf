import PDFReaderCore
import Testing

@Suite("Link hint labels and matching")
struct LinkHintTests {
    @Test("no links yields no labels")
    func emptyIsEmpty() {
        #expect(LinkHintLabels.generate(count: 0).isEmpty)
    }

    @Test("labels are unique, equal-length, and prefix-free")
    func labelsArePrefixFree() {
        for count in [1, 5, 25, 26, 27, 100, 700] {
            let labels = LinkHintLabels.generate(count: count)
            #expect(labels.count == count)
            #expect(Set(labels).count == count)                       // unique
            #expect(Set(labels.map(\.count)).count == 1)              // all same length
            // Equal length => no label is a strict prefix of another.
            #expect(!labels.contains { a in labels.contains { b in a != b && b.hasPrefix(a) } })
        }
    }

    @Test("small counts fit single characters from the home row")
    func smallCountsAreSingleChars() {
        let labels = LinkHintLabels.generate(count: 3)
        #expect(labels == ["f", "j", "d"]) // first three of the default alphabet
        #expect(labels.allSatisfy { $0.count == 1 })
    }

    @Test("counts above the alphabet grow to two characters")
    func overflowGrowsLength() {
        let labels = LinkHintLabels.generate(count: 27) // > 26
        #expect(labels.allSatisfy { $0.count == 2 })
    }

    @Test("candidate filtering narrows by typed prefix")
    func candidateFiltering() {
        let labels = ["fa", "fj", "jd", "jk"]
        #expect(LinkHintFilter.candidates(labels, typed: "") == [0, 1, 2, 3]) // empty shows all
        #expect(LinkHintFilter.candidates(labels, typed: "f") == [0, 1])
        #expect(LinkHintFilter.candidates(labels, typed: "F") == [0, 1])      // case-insensitive
        #expect(LinkHintFilter.candidates(labels, typed: "fj") == [1])
        #expect(LinkHintFilter.candidates(labels, typed: "z").isEmpty)
    }

    @Test("exact match resolves a single link")
    func exactMatch() {
        let labels = ["fa", "fj", "jd"]
        #expect(LinkHintFilter.exactMatch(labels, typed: "fj") == 1)
        #expect(LinkHintFilter.exactMatch(labels, typed: "FJ") == 1)
        #expect(LinkHintFilter.exactMatch(labels, typed: "f") == nil) // prefix, not exact
        #expect(LinkHintFilter.exactMatch(labels, typed: "zz") == nil)
    }
}
