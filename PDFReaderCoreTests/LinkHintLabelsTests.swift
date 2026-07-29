import PDFReaderCore
import Testing

@Suite("Link hint labels")
struct LinkHintLabelsTests {
    @Test("zero links yields no labels")
    func emptyIsEmpty() {
        #expect(LinkHintLabels.generate(count: 0).isEmpty)
    }

    @Test("labels are unique")
    func labelsAreUnique() {
        let labels = LinkHintLabels.generate(count: 700)
        #expect(Set(labels).count == labels.count)
    }

    @Test("labels are prefix-free")
    func labelsArePrefixFree() {
        let labels = LinkHintLabels.generate(count: 100)
        #expect(!labels.contains { label in labels.contains { $0 != label && $0.hasPrefix(label) } })
    }

    @Test("small counts use home-row-first single-character labels")
    func smallCountsUseHomeRowCharacters() {
        #expect(LinkHintLabels.generate(count: 3) == ["f", "j", "d"])
    }

    @Test("labels grow from one to two characters above the alphabet size")
    func labelLengthGrowsAtCapacity() {
        #expect(LinkHintLabels.generate(count: 26).allSatisfy { $0.count == 1 })
        #expect(LinkHintLabels.generate(count: 27).allSatisfy { $0.count == 2 })
    }

    @Test("generation is deterministic")
    func generationIsDeterministic() {
        #expect(LinkHintLabels.generate(count: 100) == LinkHintLabels.generate(count: 100))
    }
}
