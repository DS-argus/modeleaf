import Darwin
import Foundation

public enum RecentFilesPersist: Equatable, Sendable {
    case persisted
    case rejected
    case failed(message: String)
}

public struct RecentFileEntry: Codable, Equatable, Sendable {
    public let absolutePath: String
    public let lastOpenedAt: Date

    public init(absolutePath: String, lastOpenedAt: Date) {
        self.absolutePath = absolutePath
        self.lastOpenedAt = lastOpenedAt
    }
}

public struct RecentFilesStore: Sendable {
    public static let maximumEntries = 15
    public let stateFileStore: StateFileStore
    private let now: @Sendable () -> Date

    public init(fileURL: URL = ThemeSelectionStore.defaultFileURL, now: @escaping @Sendable () -> Date = Date.init) {
        stateFileStore = StateFileStore(fileURL: fileURL)
        self.now = now
    }

    public init(stateFileStore: StateFileStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.stateFileStore = stateFileStore
        self.now = now
    }

    public func load() -> [RecentFileEntry] {
        guard case let .loaded(document) = stateFileStore.load(), let files = document.recentFiles else { return [] }
        return files
            .map { RecentFileEntry(absolutePath: $0.absolutePath, lastOpenedAt: $0.lastOpenedAt) }
            .filter { Self.isPDFPath($0.absolutePath) }
    }

    @discardableResult
    public func recordOpened(absolutePath: String) -> RecentFilesPersist {
        guard Self.isPDFPath(absolutePath) else { return .rejected }
        let openedAt = now()
        return persist { entries in
            var updated = entries.filter { $0.absolutePath != absolutePath }
            updated.insert(RecentFileEntry(absolutePath: absolutePath, lastOpenedAt: openedAt), at: 0)
            if updated.count > Self.maximumEntries {
                updated.removeLast(updated.count - Self.maximumEntries)
            }
            return updated
        }
    }

    @discardableResult
    public func clear() -> RecentFilesPersist {
        persist { _ in [] }
    }

    @discardableResult
    public func prune(absolutePath: String) -> RecentFilesPersist {
        persist { $0.filter { $0.absolutePath != absolutePath } }
    }

    private static func isPDFPath(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
    }

    private func persist(_ mutate: @escaping ([RecentFileEntry]) -> [RecentFileEntry]) -> RecentFilesPersist {
        switch stateFileStore.update(mutate: { document in
            let current = (document.recentFiles ?? []).map {
                RecentFileEntry(absolutePath: $0.absolutePath, lastOpenedAt: $0.lastOpenedAt)
            }
            document.recentFiles = mutate(current).map {
                RecentFileEntryDTO(absolutePath: $0.absolutePath, lastOpenedAt: $0.lastOpenedAt)
            }
        }) {
        case .persisted: .persisted
        case let .failed(message): .failed(message: message)
        }
    }
}

public enum PathExistenceOutcome: Equatable, Sendable {
    case regularFile
    case missing
    case notAFile(reason: String)
}

/// `stat`, rather than `lstat`, deliberately follows symlinks. Thus a symlink
/// to a regular PDF remains usable while a dangling symlink is pruned as ENOENT.
public enum PathExistenceCheck {
    public static func classify(_ path: String) -> PathExistenceOutcome {
        var information = stat()
        if stat(path, &information) == 0 {
            if (information.st_mode & S_IFMT) == S_IFREG { return .regularFile }
            if (information.st_mode & S_IFMT) == S_IFDIR { return .notAFile(reason: "This path is a folder") }
            return .notAFile(reason: "Not a regular file")
        }
        switch errno {
        case ENOENT, ENOTDIR: return .missing
        case EACCES, EPERM: return .notAFile(reason: "Permission denied")
        default: return .notAFile(reason: "Could not check the path: errno \(errno)")
        }
    }
}
