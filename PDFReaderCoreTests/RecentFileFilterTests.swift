import Foundation
import PDFReaderCore
import Testing

@Suite("Recent file fuzzy filtering")
struct RecentFileFilterTests {
    private let entries = [
        RecentFileEntry(absolutePath: "/one/Alpha Report.pdf", lastOpenedAt: .distantPast),
        RecentFileEntry(absolutePath: "/two/Beta.pdf", lastOpenedAt: .distantPast),
    ]

    @Test("An empty query keeps persisted order")
    func emptyQueryIsIdentity() {
        #expect(RecentFileFilter.rank(entries, query: "").map(\.entry) == entries)
    }

    @Test("Only the filename participates in fuzzy matching")
    func pathDoesNotMatch() {
        #expect(RecentFileFilter.rank(entries, query: "one").isEmpty)
        #expect(RecentFileFilter.rank(entries, query: "report").map(\.entry.absolutePath) == ["/one/Alpha Report.pdf"])
    }

    @Test("Matched indices describe the filename subsequence case-insensitively")
    func matchedIndicesAreAccurate() {
        let matches = RecentFileFilter.rank(entries, query: "aRp")
        #expect(matches.first?.entry.absolutePath == "/one/Alpha Report.pdf")
        #expect(matches.first?.matchedIndices == [0, 6, 8])
    }
}
