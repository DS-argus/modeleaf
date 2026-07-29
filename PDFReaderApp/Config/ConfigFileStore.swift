import Darwin
import Foundation

enum ConfigFileWriteResult: Equatable {
    case created
    case alreadyExists
    case failed(message: String)
}

enum ConfigFileResetResult: Equatable {
    case replaced
    case unchanged
    case missingFile
    case failed(message: String)
}

/// Owns the durable, cross-process-safe mutations of config.toml.
struct ConfigFileStore {
    let fileURL: URL
    private let synchronizeTemporary: (Int32) -> Int32

    init(fileURL: URL, synchronizeTemporary: @escaping (Int32) -> Int32 = fsync) {
        self.fileURL = fileURL
        self.synchronizeTemporary = synchronizeTemporary
    }

    func writeDefaultExclusive(_ data: Data) -> ConfigFileWriteResult {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            return .failed(message: error.localizedDescription)
        }
        return withLock(operation: {
            do {
                let temporaryURL = try writeTemporary(data)
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                let cleanupWarning = try publishExclusive(temporaryURL, to: fileURL)
                try synchronizeDirectory()
                if cleanupWarning {
                    NSLog("Config default publication succeeded but could not remove its temporary file.")
                }
                return .created
            } catch let error as POSIXError where error.code == .EEXIST {
                return .alreadyExists
            } catch {
                return .failed(message: error.localizedDescription)
            }
        }, lockFailure: { error in
            .failed(message: error.localizedDescription)
        })
    }

    func reset(defaultBytes: Data) -> ConfigFileResetResult {
        withLock(operation: {
            let original: Data
            do {
                original = try Data(contentsOf: fileURL)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return .missingFile
            } catch {
                return .failed(message: error.localizedDescription)
            }
            guard original != defaultBytes else { return .unchanged }
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let backupURL = fileURL.appendingPathExtension("bak")
                let backupTemporaryURL = try writeTemporary(original)
                defer { try? FileManager.default.removeItem(at: backupTemporaryURL) }
                try replace(backupTemporaryURL, at: backupURL)
                try synchronizeDirectory()

                let defaultTemporaryURL = try writeTemporary(defaultBytes)
                defer { try? FileManager.default.removeItem(at: defaultTemporaryURL) }
                try replace(defaultTemporaryURL, at: fileURL)
                try synchronizeDirectory()
                return .replaced
            } catch {
                return .failed(message: error.localizedDescription)
            }
        }, lockFailure: { error in
            .failed(message: error.localizedDescription)
        })
    }

    private var directoryURL: URL { fileURL.deletingLastPathComponent() }

    private func withLock<Result>(operation: () -> Result, lockFailure: (POSIXError) -> Result) -> Result {
        let lockURL = URL(fileURLWithPath: fileURL.path + ".lock")
        let fd = lockURL.path.withCString { open($0, O_RDWR | O_CREAT, mode_t(0o600)) }
        guard fd >= 0 else { return lockFailure(posixError()) }
        defer { _ = flock(fd, LOCK_UN); _ = close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return lockFailure(posixError()) }
        return operation()
    }

    private func writeTemporary(_ data: Data) throws -> URL {
        let temporaryURL = directoryURL.appendingPathComponent(".config-\(UUID().uuidString).tmp")
        var fd = temporaryURL.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600)) }
        guard fd >= 0 else { throw posixError() }
        var completed = false
        defer {
            if fd >= 0 { _ = close(fd) }
            if !completed { try? FileManager.default.removeItem(at: temporaryURL) }
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard written > 0 else { throw posixError() }
                offset += written
            }
        }
        guard synchronizeTemporary(fd) == 0 else { throw posixError() }
        let closeResult = close(fd)
        fd = -1
        guard closeResult == 0 else { throw posixError() }
        completed = true
        return temporaryURL
    }

    /// Returns whether link/unlink publication left a temporary cleanup warning.
    private func publishExclusive(_ source: URL, to destination: URL) throws -> Bool {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renameatx_np(AT_FDCWD, sourcePath, AT_FDCWD, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard result != 0 else { return false }
        let renameError = errno
        // Only filesystems that explicitly reject renameatx_np's exclusive
        // capability use link/unlink; ordinary publication never falls back.
        guard renameError == ENOTSUP else { throw posixError(code: renameError) }
        let linked = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in link(sourcePath, destinationPath) }
        }
        guard linked == 0 else { throw posixError() }
        return unlink(source.path) != 0
    }

    private func replace(_ source: URL, at destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in rename(sourcePath, destinationPath) }
        }
        guard result == 0 else { throw posixError() }
    }

    private func synchronizeDirectory() throws {
        let fd = directoryURL.path.withCString { open($0, O_RDONLY) }
        guard fd >= 0 else { throw posixError() }
        defer { _ = close(fd) }
        guard fsync(fd) == 0 else { throw posixError() }
    }

    private func posixError(code: Int32 = errno) -> POSIXError { POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
}
