import Foundation
import PDFReaderCore
import Testing

@Suite("Recent files persistence")
struct RecentFilesStoreTests {
    @Test("Recording more than fifteen files removes the oldest")
    func capsAtFifteen() throws {
        try withStore { store, url in
            for index in 0 ... 15 {
                #expect(store.recordOpened(absolutePath: "/tmp/\(index).pdf") == .persisted)
            }
            let files = store.load()
            #expect(files.count == 15)
            #expect(!files.contains { $0.absolutePath == "/tmp/0.pdf" })
            #expect(files.first?.absolutePath == "/tmp/15.pdf")
            _ = url
        }
    }

    @Test("Re-recording a path moves it to the top without duplication")
    func rerecordDeduplicates() throws {
        try withStore { store, _ in
            _ = store.recordOpened(absolutePath: "/tmp/first.pdf")
            _ = store.recordOpened(absolutePath: "/tmp/second.pdf")
            _ = store.recordOpened(absolutePath: "/tmp/first.pdf")
            #expect(store.load().map(\.absolutePath) == ["/tmp/first.pdf", "/tmp/second.pdf"])
        }
    }

    @Test("Missing, empty, malformed, and unknown-schema state safely load no recents")
    func safeFallbacks() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("state.json")
        let store = RecentFilesStore(fileURL: fileURL)
        #expect(store.load().isEmpty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for source in ["", "not json", "{\"future\":true}"] {
            try Data(source.utf8).write(to: fileURL)
            #expect(store.load().isEmpty)
        }
    }

    @Test("Clear persists an empty recent-files array")
    func clearRoundTrips() throws {
        try withStore { store, _ in
            _ = store.recordOpened(absolutePath: "/tmp/a.pdf")
            #expect(store.clear() == .persisted)
            #expect(store.load().isEmpty)
            #expect(RecentFilesStore(fileURL: store.stateFileStore.fileURL).load().isEmpty)
        }
    }

    @Test("Prune removes only the requested path")
    func pruneRemovesRequestedPath() throws {
        try withStore { store, _ in
            _ = store.recordOpened(absolutePath: "/tmp/a.pdf")
            _ = store.recordOpened(absolutePath: "/tmp/b.pdf")
            #expect(store.prune(absolutePath: "/tmp/a.pdf") == .persisted)
            #expect(store.load().map(\.absolutePath) == ["/tmp/b.pdf"])
        }
    }


    @Test("Non-PDF paths are rejected and corrupted non-PDF entries stay hidden")
    func rejectsAndFiltersNonPDFPaths() throws {
        try withStore { store, directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #expect(store.recordOpened(absolutePath: "/tmp/not-a-pdf.txt") == .rejected)
            #expect(store.load().isEmpty)

            let state = directory.appendingPathComponent("state.json")
            try Data("{\"recent_files\":[{\"absolute_path\":\"/tmp/valid.PDF\",\"last_opened_at\":0},{\"absolute_path\":\"/tmp/not-a-pdf.txt\",\"last_opened_at\":0}]}".utf8).write(to: state)
            #expect(store.load().map(\.absolutePath) == ["/tmp/valid.PDF"])
        }
    }

    @Test("Reopening remains first when timestamps are equal or move backwards")
    func reopeningIsFirstRegardlessOfTimestamp() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stateURL = directory.appendingPathComponent("state.json")
        try Data("{\"recent_files\":[{\"absolute_path\":\"/tmp/first.pdf\",\"last_opened_at\":100},{\"absolute_path\":\"/tmp/second.pdf\",\"last_opened_at\":50}]}".utf8).write(to: stateURL)
        let store = RecentFilesStore(fileURL: stateURL, now: { Date(timeIntervalSince1970: 0) })
        #expect(store.recordOpened(absolutePath: "/tmp/first.pdf") == .persisted)
        #expect(store.load().map(\.absolutePath) == ["/tmp/first.pdf", "/tmp/second.pdf"])
    }
    private func withStore(_ body: (RecentFilesStore, URL) throws -> Void) throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecentFilesStore(fileURL: directory.appendingPathComponent("state.json"))
        try body(store, directory)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RecentFilesStoreTests-\(UUID().uuidString)", isDirectory: true)
    }
}
