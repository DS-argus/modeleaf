import Darwin
import Foundation

public enum StateFileStoreUpdate: Equatable, Sendable {
    case persisted
    case failed(message: String)
}

public enum StateFileStoreLoad: Equatable, Sendable {
    case loaded(StateFileDocument)
    case absent
    case invalid
    case ioError(message: String)
}

public struct RecentFileEntryDTO: Codable, Equatable, Sendable {
    public var absolutePath: String
    public var lastOpenedAt: Date

    public init(absolutePath: String, lastOpenedAt: Date) {
        self.absolutePath = absolutePath
        self.lastOpenedAt = lastOpenedAt
    }

    enum CodingKeys: String, CodingKey {
        case absolutePath = "absolute_path"
        case lastOpenedAt = "last_opened_at"
    }
}

/// The complete state document. Unknown JSON members are retained verbatim when
/// either known field is updated, so independently-developed state consumers do
/// not erase each other's data.
public struct StateFileDocument: Codable, Equatable, Sendable {
    public var selectedTheme: String?
    public var recentFiles: [RecentFileEntryDTO]?
    private var unknownFields: [String: JSONValue]

    public init(selectedTheme: String? = nil, recentFiles: [RecentFileEntryDTO]? = nil) {
        self.selectedTheme = selectedTheme
        self.recentFiles = recentFiles
        unknownFields = [:]
    }

    private enum KnownKey: String, CodingKey, CaseIterable {
        case selectedTheme = "selected_theme"
        case recentFiles = "recent_files"
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let known = try decoder.container(keyedBy: KnownKey.self)
        // Decode each owned field independently. A malformed sibling must not
        // turn a valid field into an all-or-nothing decode failure.
        selectedTheme = (try? known.decodeIfPresent(String.self, forKey: .selectedTheme)) ?? nil
        recentFiles = (try? known.decodeIfPresent([RecentFileEntryDTO].self, forKey: .recentFiles)) ?? nil

        let all = try decoder.container(keyedBy: AnyKey.self)
        var retained: [String: JSONValue] = [:]
        for key in all.allKeys where KnownKey(rawValue: key.stringValue) == nil {
            if let value = try? all.decode(JSONValue.self, forKey: key) {
                retained[key.stringValue] = value
            }
        }
        unknownFields = retained
    }

    public func encode(to encoder: Encoder) throws {
        var all = encoder.container(keyedBy: AnyKey.self)
        for (name, value) in unknownFields {
            try all.encode(value, forKey: AnyKey(stringValue: name)!)
        }
        if let selectedTheme { try all.encode(selectedTheme, forKey: AnyKey(stringValue: "selected_theme")!) }
        if let recentFiles { try all.encode(recentFiles, forKey: AnyKey(stringValue: "recent_files")!) }
    }
}

private indirect enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null }
        else if let value = try? single.decode(Bool.self) { self = .bool(value) }
        else if let value = try? single.decode(Double.self) { self = .number(value) }
        else if let value = try? single.decode(String.self) { self = .string(value) }
        else if let value = try? single.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try single.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .null: try single.encodeNil()
        case let .bool(value): try single.encode(value)
        case let .number(value): try single.encode(value)
        case let .string(value): try single.encode(value)
        case let .array(value): try single.encode(value)
        case let .object(value): try single.encode(value)
        }
    }
}

/// Low-level owner of state.json. Updates use a persistent sidecar lock to make
/// read/merge/replace one cross-process transaction.
public struct StateFileStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> StateFileStoreLoad {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return .absent
        } catch {
            return .ioError(message: String(describing: error))
        }
        guard let document = try? JSONDecoder().decode(StateFileDocument.self, from: data) else { return .invalid }
        return .loaded(document)
    }

    @discardableResult
    public func update(mutate: (inout StateFileDocument) -> Void) -> StateFileStoreUpdate {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .failed(message: String(describing: error))
        }

        let lockPath = fileURL.path + ".lock"
        let fd = lockPath.withCString { open($0, O_RDWR | O_CREAT, mode_t(0o600)) }
        guard fd >= 0 else { return .failed(message: "open lock error: errno \(errno)") }

        var locked = false
        defer {
            if locked { _ = flock(fd, LOCK_UN) }
            _ = close(fd)
        }

        let deadline = Date().addingTimeInterval(2)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                locked = true
                break
            }
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN else {
                return .failed(message: "flock error: errno \(code)")
            }
            guard Date() < deadline else { return .failed(message: "lock timeout") }
            Thread.sleep(forTimeInterval: 0.05)
        }

        var result: StateFileStoreUpdate = .persisted
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            var document: StateFileDocument
            switch loadDocument(at: coordinatedURL) {
            case let .loaded(value): document = value
            case .absent, .invalid: document = StateFileDocument()
            case let .ioError(message):
                result = .failed(message: message)
                return
            }
            mutate(&document)
            do {
                let data = try JSONEncoder().encode(document)
                try atomicallyReplace(data, at: coordinatedURL)
            } catch {
                result = .failed(message: String(describing: error))
            }
        }
        if let coordinationError { return .failed(message: String(describing: coordinationError)) }
        return result
    }

    private func loadDocument(at url: URL) -> StateFileStoreLoad {
        StateFileStore(fileURL: url).load()
    }

    private func atomicallyReplace(_ data: Data, at url: URL) throws {
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(".state-\(UUID().uuidString).tmp")
        // The temp file is CREATED owner-only (0600); the recent-path data never
        // exists on disk with broader permissions, even transiently.
        let fd = temporaryURL.path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600)) }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var closed = false
        defer { if !closed { _ = close(fd) } }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            _ = close(fd)
            closed = true
            let status = temporaryURL.path.withCString { source in
                url.path.withCString { destination in rename(source, destination) }
            }
            guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }
}
