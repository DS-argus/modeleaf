import Foundation
import PDFReaderCore
import PDFReaderTestSupport
@testable import PDFReaderApp
import Testing

@Suite("Settings store")
struct SettingsStoreTests {
    @Test("default URL uses the injected home directory")
    func defaultURL() {
        let home = URL(fileURLWithPath: "/tmp/settings-home", isDirectory: true)
        #expect(
            SettingsStore.defaultURL(home: home).path
                == "/tmp/settings-home/Library/Application Support/Modeleaf/settings.json"
        )
    }

    @Test("missing snapshot does not create the settings path")
    func missingSnapshot() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("settings.json")
            let store = SettingsStore(fileURL: url)
            let snapshot = try store.snapshot()
            #expect(!snapshot.exists)
            #expect(snapshot.bytes == nil)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("settings.json.lock").path))
        }
    }

    @Test("save publishes atomically and stale snapshots conflict")
    func saveAndConflict() throws {
        try withTemporaryDirectory { directory in
            let store = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
            let missing = try store.snapshot()
            let first = Data(#"{"version":1,"settings":{}}"#.utf8)
            let saved = store.save(first, expected: missing)
            guard case let .saved(published) = saved else {
                Issue.record("Expected saved result, got \(saved)")
                return
            }
            #expect(published.bytes == first)
            #expect(try store.snapshot() == published)
            #expect((try Data(contentsOf: store.fileURL)) == first)
            let stale = store.save(Data("different".utf8), expected: missing)
            #expect(stale == .conflict)
        }
    }

    @Test("a preparation failure is distinct from a conflict")
    func preparationFailure() throws {
        try withTemporaryDirectory { directory in
            let blockedParent = directory.appendingPathComponent("not-a-directory")
            try Data("blocked".utf8).write(to: blockedParent)
            let store = SettingsStore(fileURL: blockedParent.appendingPathComponent("settings.json"))
            let result = store.save(Data("{}".utf8), expected: .missing)
            guard case .precommitFailed = result else {
                Issue.record("Expected a precommit failure, got \(result)")
                return
            }
        }
    }

    @Test("published bytes retain owner-only permissions")
    func permissions() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("settings.json")
            let store = SettingsStore(fileURL: url)
            let result = store.save(Data("{}".utf8), expected: .missing)
            guard case .saved = result else {
                Issue.record("Expected saved result, got \(result)")
                return
            }
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            #expect((permissions?.intValue ?? 0) & 0o777 == 0o600)
        }
    }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}
