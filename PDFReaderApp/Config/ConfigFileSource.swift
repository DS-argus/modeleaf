import Foundation
import PDFReaderCore

enum ConfigFileReadResult {
    case missing
    case loaded(Data)
    case failed(ConfigDiagnostic)
}

struct ConfigFileSource: Sendable {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    static func defaultURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("pdf-reader", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    func read(fileManager: FileManager = .default) -> ConfigFileReadResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard !isDirectory.boolValue else {
            return .failed(fileDiagnostic("Configuration path is a directory, not a TOML file."))
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? NSNumber,
               size.uint64Value > UInt64(ConfigLimits.maximumBytes)
            {
                return .failed(sizeDiagnostic(actualBytes: size.uint64Value))
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= ConfigLimits.maximumBytes else {
                return .failed(sizeDiagnostic(actualBytes: UInt64(data.count)))
            }
            return .loaded(data)
        } catch {
            return .failed(fileDiagnostic("Unable to read configuration: \(error.localizedDescription)"))
        }
    }

    private func fileDiagnostic(_ message: String) -> ConfigDiagnostic {
        ConfigDiagnostic(
            severity: .error,
            code: .fileReadFailed,
            message: message,
            semanticPath: "$",
            sourcePath: url.path
        )
    }

    private func sizeDiagnostic(actualBytes: UInt64) -> ConfigDiagnostic {
        ConfigDiagnostic(
            severity: .error,
            code: .inputTooLarge,
            message: "Configuration is \(actualBytes) bytes; the maximum is \(ConfigLimits.maximumBytes) bytes.",
            semanticPath: "$",
            sourcePath: url.path
        )
    }
}
