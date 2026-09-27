import Darwin
import Foundation
import PDFReaderCore

struct SettingsFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct SettingsSnapshot: Equatable, Sendable {
    let bytes: Data?
    let identity: SettingsFileIdentity?

    static let missing = SettingsSnapshot(bytes: nil, identity: nil)

    var exists: Bool { identity != nil }
}

enum SettingsStoreError: Error, Equatable, LocalizedError, Sendable {
    case readFailed(path: String, code: Int32)
    case unstableRead(path: String)
    case unsafeSymlink(path: String)
    case notRegular(path: String)
    case tooLarge(path: String, bytes: UInt64)
    case closeFailed(path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case let .readFailed(path, code):
            let description = String(cString: strerror(code))
            return "Unable to read settings at \(path): \(description) (errno \(code))."
        case let .unstableRead(path):
            return "Settings at \(path) changed while it was being read."
        case let .unsafeSymlink(path):
            return "Settings path \(path) is a symbolic link and was not followed."
        case let .notRegular(path):
            return "Settings path \(path) is not a regular file."
        case let .tooLarge(path, bytes):
            return "Settings at \(path) is \(bytes) bytes, above the configured maximum."
        case let .closeFailed(path, code):
            let description = String(cString: strerror(code))
            return "Unable to close settings at \(path): \(description) (errno \(code))."
        }
    }
}

enum SettingsSaveResult: Equatable, Sendable {
    case saved(snapshot: SettingsSnapshot)
    case conflict
    case precommitFailed(message: String)
    case publishedWarning(snapshot: SettingsSnapshot, message: String)
    case publicationUncertain(message: String)
}

/// Owns the durable settings.json path and cooperative, atomic publications.
///
/// The lock coordinates writers that use this store. It cannot provide a CAS
/// guarantee against arbitrary processes that rename the path without taking
/// the cooperative lock, so publication is reported as observed rather than
/// as an exclusion claim.
struct SettingsStore: Sendable {
    let fileURL: URL

    init(fileURL: URL = SettingsStore.defaultURL()) {
        self.fileURL = fileURL
    }

    static func defaultURL(home: URL? = nil) -> URL {
        let homeURL: URL
        if let home {
            homeURL = home
        } else if let environmentPointer = getenv("HOME"),
                  let environmentHome = String(validatingCString: environmentPointer),
                  !environmentHome.isEmpty {
            homeURL = URL(fileURLWithPath: environmentHome, isDirectory: true)
        } else {
            homeURL = FileManager.default.homeDirectoryForCurrentUser
        }
        return homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Modeleaf", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }
    func snapshot() throws -> SettingsSnapshot {
        try capture(maximumBytes: ConfigLimits.maximumBytes)
    }

    func save(_ data: Data, expected: SettingsSnapshot) -> SettingsSaveResult {
        guard data.count <= ConfigLimits.maximumBytes else {
            return .precommitFailed(
                message: "Settings data is \(data.count) bytes; the maximum is \(ConfigLimits.maximumBytes) bytes."
            )
        }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return .precommitFailed(message: "Unable to create the settings directory: \(error.localizedDescription)")
        }

        let lockURL = URL(fileURLWithPath: fileURL.path + ".lock")
        let lockFD = lockURL.path.withCString { path in
            open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard lockFD >= 0 else {
            return .precommitFailed(message: "Unable to open the settings lock: errno \(errno).")
        }
        var hasLock = false
        defer {
            if hasLock { _ = flock(lockFD, LOCK_UN) }
            _ = close(lockFD)
        }

        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            return .precommitFailed(message: "Settings are being saved by another window or process. Try again.")
        }
        hasLock = true

        let current: SettingsSnapshot
        do {
            current = try snapshot()
        } catch {
            return .precommitFailed(message: error.localizedDescription)
        }
        guard current == expected else { return .conflict }

        let temporaryURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".settings-\(UUID().uuidString).tmp")
        let temporaryFD = temporaryURL.path.withCString { path in
            open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        guard temporaryFD >= 0 else {
            return .precommitFailed(message: "Unable to create the temporary settings file: errno \(errno).")
        }

        var openFD: Int32? = temporaryFD
        func removeTemporary() {
            if let fd = openFD {
                _ = close(fd)
                openFD = nil
            }
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        var preparedIdentity: SettingsFileIdentity?
        do {
            try writeAll(data, to: temporaryFD)
            guard fsync(temporaryFD) == 0 else {
                let code = errno
                throw SettingsStoreError.readFailed(path: temporaryURL.path, code: code)
            }

            var prepared = stat()
            guard fstat(temporaryFD, &prepared) == 0 else {
                throw SettingsStoreError.readFailed(path: temporaryURL.path, code: errno)
            }
            let preparedMetadata = SettingsMetadata(stat: prepared)
            preparedIdentity = preparedMetadata.identity
            guard preparedMetadata.isRegular, preparedMetadata.size == UInt64(data.count) else {
                throw SettingsStoreError.unstableRead(path: temporaryURL.path)
            }
            var pathMetadata = stat()
            guard temporaryURL.path.withCString({ Darwin.lstat($0, &pathMetadata) }) == 0 else {
                throw SettingsStoreError.unstableRead(path: temporaryURL.path)
            }
            guard SettingsMetadata(stat: pathMetadata) == preparedMetadata else {
                throw SettingsStoreError.unstableRead(path: temporaryURL.path)
            }
            let closeResult = close(temporaryFD)
            openFD = nil
            guard closeResult == 0 else {
                throw SettingsStoreError.closeFailed(path: temporaryURL.path, code: errno)
            }
            openFD = nil
        } catch {
            removeTemporary()
            return .precommitFailed(message: "Unable to prepare settings publication: \(error.localizedDescription)")
        }

        // Recheck immediately before rename. This is a cooperative baseline
        // check, not a claim that arbitrary writers cannot race the rename.
        do {
            let latest = try snapshot()
            guard latest == expected else {
                try? FileManager.default.removeItem(at: temporaryURL)
                return .conflict
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            return .precommitFailed(message: "Unable to verify settings before publication: \(error.localizedDescription)")
        }

        let renameStatus = temporaryURL.path.withCString { source in
            fileURL.path.withCString { destination in
                expected.exists ? rename(source, destination) : renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, UInt32(RENAME_EXCL))
            }
        }
        guard renameStatus == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporaryURL)
            if !expected.exists && code == EEXIST { return .conflict }
            return .precommitFailed(message: "Unable to publish settings: \(String(cString: strerror(code))) (errno \(code)).")
        }

        let directoryWarning = synchronizeDirectory()
        let published: SettingsSnapshot
        do {
            published = try snapshot()
        } catch {
            return .publicationUncertain(message: "Settings were published, but the resulting file could not be verified: \(error.localizedDescription)")
        }
        guard published.bytes == data, published.identity == preparedIdentity else {
            return .publicationUncertain(message: "Settings changed during publication; the saved bytes could not be confirmed.")
        }
        if let directoryWarning {
            return .publishedWarning(snapshot: published, message: directoryWarning)
        }
        return .saved(snapshot: published)
    }

    private func capture(maximumBytes: Int?) throws -> SettingsSnapshot {
        let path = fileURL.path
        var initial = stat()
        guard path.withCString({ Darwin.lstat($0, &initial) }) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return .missing }
            throw SettingsStoreError.readFailed(path: path, code: code)
        }

        let initialMetadata = SettingsMetadata(stat: initial)
        guard initialMetadata.isRegular else {
            if initialMetadata.isSymlink {
                throw SettingsStoreError.unsafeSymlink(path: path)
            }
            throw SettingsStoreError.notRegular(path: path)
        }

        let fd = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard fd >= 0 else {
            let code = errno
            if code == ELOOP { throw SettingsStoreError.unsafeSymlink(path: path) }
            if code == ENOENT || code == ENOTDIR { throw SettingsStoreError.unstableRead(path: path) }
            throw SettingsStoreError.readFailed(path: path, code: code)
        }
        defer { _ = close(fd) }

        var before = stat()
        guard fstat(fd, &before) == 0 else {
            throw SettingsStoreError.readFailed(path: path, code: errno)
        }
        let beforeMetadata = SettingsMetadata(stat: before)
        guard beforeMetadata.isRegular, beforeMetadata.identity == initialMetadata.identity else {
            throw SettingsStoreError.unstableRead(path: path)
        }
        let data = try readAll(fd: fd, path: path, maximumBytes: maximumBytes)

        var after = stat()
        guard fstat(fd, &after) == 0 else {
            throw SettingsStoreError.readFailed(path: path, code: errno)
        }
        let afterMetadata = SettingsMetadata(stat: after)
        guard afterMetadata == beforeMetadata, data.count == Int(afterMetadata.size) else {
            throw SettingsStoreError.unstableRead(path: path)
        }

        var finalPath = stat()
        guard path.withCString({ Darwin.lstat($0, &finalPath) }) == 0 else {
            throw SettingsStoreError.unstableRead(path: path)
        }
        let finalMetadata = SettingsMetadata(stat: finalPath)
        guard finalMetadata == afterMetadata else {
            if finalMetadata.isSymlink {
                throw SettingsStoreError.unsafeSymlink(path: path)
            }
            throw SettingsStoreError.unstableRead(path: path)
        }
        return SettingsSnapshot(bytes: data, identity: afterMetadata.identity)
    }

    private func readAll(fd: Int32, path: String, maximumBytes: Int?) throws -> Data {
        var data = Data()
        if let maximumBytes { data.reserveCapacity(maximumBytes) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, bytes.count)
            }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw SettingsStoreError.readFailed(path: path, code: errno)
            }
            if let maximumBytes, data.count > maximumBytes - count {
                throw SettingsStoreError.tooLarge(path: path, bytes: UInt64(data.count + count))
            }
            data.append(contentsOf: buffer[0..<count])
        }
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, baseAddress.advanced(by: offset), bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SettingsStoreError.readFailed(path: temporaryPath(for: fd), code: errno)
                }
                guard written > 0 else {
                    throw SettingsStoreError.readFailed(path: temporaryPath(for: fd), code: EIO)
                }
                offset += written
            }
        }
    }

    private func temporaryPath(for _: Int32) -> String { "settings temporary file" }

    private func synchronizeDirectory() -> String? {
        let directoryURL = fileURL.deletingLastPathComponent()
        let fd = directoryURL.path.withCString { path in
            open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard fd >= 0 else {
            return "Settings were published, but the containing directory could not be opened for synchronization (errno \(errno))."
        }
        defer { _ = close(fd) }
        guard fsync(fd) == 0 else {
            return "Settings were published, but the containing directory could not be synchronized (errno \(errno))."
        }
        return nil
    }

    private struct SettingsMetadata: Equatable {
        let identity: SettingsFileIdentity
        let mode: UInt32
        let size: UInt64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64

        init(stat value: Darwin.stat) {
            identity = SettingsFileIdentity(
                device: UInt64(bitPattern: Int64(value.st_dev)),
                inode: UInt64(value.st_ino)
            )
            mode = UInt32(value.st_mode)
            size = value.st_size < 0 ? 0 : UInt64(value.st_size)
            modificationSeconds = Int64(value.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changeSeconds = Int64(value.st_ctimespec.tv_sec)
            changeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        }

        var isRegular: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFREG) }
        var isSymlink: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFLNK) }
    }
}
