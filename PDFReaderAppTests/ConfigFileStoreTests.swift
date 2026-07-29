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

    @Test("publication fault boundaries preserve durable data and clean temporary files")
    func publicationFaultMatrix() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("config.toml")
            let defaults = Data("default".utf8)

            var renameFault = ConfigFileStore.Operations.live()
            renameFault.renameExclusive = { _, _ in errno = EIO; return -1 }
            #expect(failed(ConfigFileStore(fileURL: url, operations: renameFault).writeDefaultExclusive(defaults)))
            #expect(!FileManager.default.fileExists(atPath: url.path))
            let renameLeftovers = try temporaryFiles(in: directory)
            #expect(renameLeftovers.isEmpty)

            var linkFault = ConfigFileStore.Operations.live()
            linkFault.renameExclusive = { _, _ in errno = ENOTSUP; return -1 }
            linkFault.link = { _, _ in errno = EIO; return -1 }
            #expect(failed(ConfigFileStore(fileURL: url, operations: linkFault).writeDefaultExclusive(defaults)))
            #expect(!FileManager.default.fileExists(atPath: url.path))
            let linkLeftovers = try temporaryFiles(in: directory)
            #expect(linkLeftovers.isEmpty)

            var unlinkFault = ConfigFileStore.Operations.live()
            unlinkFault.renameExclusive = { _, _ in errno = ENOTSUP; return -1 }
            unlinkFault.unlink = { _ in errno = EIO; return -1 }
            #expect(ConfigFileStore(fileURL: url, operations: unlinkFault).writeDefaultExclusive(defaults) == .created)
            let linked = try Data(contentsOf: url)
            #expect(linked == defaults)
            let unlinkLeftovers = try temporaryFiles(in: directory)
            #expect(unlinkLeftovers.isEmpty)
        }
    }

    @Test("directory sync failure after publication reports failure but leaves the committed config recoverable")
    func publicationDirectorySyncFault() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("config.toml")
            let defaults = Data("default".utf8)
            var operations = ConfigFileStore.Operations.live()
            operations.synchronizeDirectory = { _ in errno = EIO; return -1 }

            #expect(failed(ConfigFileStore(fileURL: url, operations: operations).writeDefaultExclusive(defaults)))
            let committed = try Data(contentsOf: url)
            #expect(committed == defaults)
            let leftovers = try temporaryFiles(in: directory)
            #expect(leftovers.isEmpty)
            #expect(ConfigFileStore(fileURL: url).writeDefaultExclusive(defaults) == .alreadyExists)
        }
    }

    @Test("reset fault boundaries retain backup and converge on a later reset")
    func resetFaultMatrix() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("config.toml")
            let backupURL = url.appendingPathExtension("bak")
            let original = Data("custom".utf8)
            let defaults = Data("default".utf8)

            for boundary in ["backup-sync", "final-replace", "final-sync"] {
                try original.write(to: url)
                try? FileManager.default.removeItem(at: backupURL)
                let calls = CallCounter()
                var operations = ConfigFileStore.Operations.live()
                switch boundary {
                case "backup-sync":
                    operations.synchronizeDirectory = { _ in
                        calls.count += 1
                        if calls.count == 1 { errno = EIO; return -1 }
                        return ConfigFileStore.Operations.live().synchronizeDirectory("")
                    }
                case "final-replace":
                    operations.replace = { source, destination in
                        calls.count += 1
                        if calls.count == 2 { errno = EIO; return -1 }
                        return ConfigFileStore.Operations.live().replace(source, destination)
                    }
                default:
                    operations.synchronizeDirectory = { path in
                        calls.count += 1
                        if calls.count == 2 { errno = EIO; return -1 }
                        return ConfigFileStore.Operations.live().synchronizeDirectory(path)
                    }
                }

                #expect(failed(ConfigFileStore(fileURL: url, operations: operations).reset(defaultBytes: defaults)))
                let backup = try Data(contentsOf: backupURL)
                let leftovers = try temporaryFiles(in: directory)
                #expect(backup == original)
                #expect(leftovers.isEmpty)
                if boundary == "final-sync" {
                    let committed = try Data(contentsOf: url)
                    #expect(committed == defaults)
                    #expect(ConfigFileStore(fileURL: url).reset(defaultBytes: defaults) == .unchanged)
                } else {
                    let retained = try Data(contentsOf: url)
                    #expect(retained == original)
                    #expect(ConfigFileStore(fileURL: url).reset(defaultBytes: defaults) == .replaced)
                    let converged = try Data(contentsOf: url)
                    #expect(converged == defaults)
                }
            }
        }
    }

    private final class CallCounter {
        var count = 0
    }

    private func failed(_ result: ConfigFileWriteResult) -> Bool {
        if case .failed = result { return true }
        return false
    }

    private func failed(_ result: ConfigFileResetResult) -> Bool {
        if case .failed = result { return true }
        return false
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
