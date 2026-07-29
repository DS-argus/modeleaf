import Darwin
import Foundation
import PDFReaderCore
import PDFReaderTestSupport
@testable import PDFReaderApp
import Testing

@Suite("Config file store")
struct ConfigFileStoreTests {
    @Test("exclusive write creates owner-only default config and preserves an existing file")
    func exclusiveWrite() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("nested/config.toml")
            let store = ConfigFileStore(fileURL: url)
            let defaults = Data(BuiltInDefaults.defaultConfigTOML.utf8)
            #expect(store.writeDefaultExclusive(defaults) == .created)
            #expect(try Data(contentsOf: url) == defaults)
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            #expect((permissions?.intValue ?? 0) & 0o777 == 0o600)

            let original = Data("custom".utf8)
            try original.write(to: url)
            let originalChecksum = original.hashValue
            #expect(store.writeDefaultExclusive(defaults) == .alreadyExists)
            let retained = try Data(contentsOf: url)
            #expect(retained.hashValue == originalChecksum)
            #expect(retained == original)
        }
    }

    @Test("write fails closed while another handle owns the lock")
    func writeFailsClosedWhenLocked() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("config.toml")
            let lockURL = URL(fileURLWithPath: url.path + ".lock")
            let fd = lockURL.path.withCString { open($0, O_RDWR | O_CREAT, mode_t(0o600)) }
            #expect(fd >= 0)
            defer { _ = flock(fd, LOCK_UN); _ = close(fd) }
            #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)

            let result = ConfigFileStore(fileURL: url).writeDefaultExclusive(Data("default".utf8))
            guard case .failed = result else {
                Issue.record("A contended lock must fail closed, got \(result)")
                return
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("failed temporary fsync removes the partial temporary file")
    func failedTemporaryWriteCleansUp() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("config.toml")
            let store = ConfigFileStore(fileURL: url, synchronizeTemporary: { _ in
                errno = EIO
                return -1
            })
            guard case .failed = store.writeDefaultExclusive(Data("default".utf8)) else {
                Issue.record("The injected fsync failure must fail the write")
                return
            }
            let leftovers = try temporaryFiles(in: directory)
            #expect(leftovers.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("reset preserves the original backup and leaves it intact on a no-op")
    func reset() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("config.toml")
            let original = Data("[keymap]\n\"view.zoomIn\" = [\"z\"]\n".utf8)
            let defaults = Data(BuiltInDefaults.defaultConfigTOML.utf8)
            try original.write(to: url)
            let store = ConfigFileStore(fileURL: url)
            #expect(store.reset(defaultBytes: defaults) == .replaced)
            #expect(try Data(contentsOf: url) == defaults)
            #expect(try Data(contentsOf: url.appendingPathExtension("bak")) == original)
            #expect(store.reset(defaultBytes: defaults) == .unchanged)
            #expect(try Data(contentsOf: url.appendingPathExtension("bak")) == original)
            #expect(store.reset(defaultBytes: defaults) != .missingFile)
        }
    }

    @Test("reset recovers when a crash leaves only the backup replacement committed")
    func resetRecoversAfterBackupBoundary() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("config.toml")
            let backupURL = url.appendingPathExtension("bak")
            let original = Data("[keymap]\n\"view.zoomIn\" = [\"z\"]\n".utf8)
            let defaults = Data(BuiltInDefaults.defaultConfigTOML.utf8)
            try original.write(to: url)
            try original.write(to: backupURL) // Simulated crash after backup publication, before config replacement.

            #expect(ConfigFileStore(fileURL: url).reset(defaultBytes: defaults) == .replaced)
            #expect(try Data(contentsOf: url) == defaults)
            #expect(try Data(contentsOf: backupURL) == original)
        }
    }

    private func temporaryFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".config-") && $0.pathExtension == "tmp" }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-file-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}
