import CryptoKit
import Darwin
import Foundation
import PDFKit
import PDFReaderTestSupport

private struct FixtureRecord: Encodable {
    let identifier: String
    let path: String
    let sha256: String
    let byteSize: Int64
    let pageCount: Int
    let locked: Bool
    let sentinel: PerformancePDFSentinel?
    let validation: String
}

private struct ArtifactReference: Encodable {
    let path: String
    let sha256: String
    let byteSize: Int64
}

private struct ManualActionContract: Encodable {
    let actionID = "scroll.left"
    let keySequence = ["h", "h"]
    let originalInterKeyDelaySeconds: Double? = nil
    let note = "The original crash report did not preserve key timing. Manual validation must not invent it."
}

private struct PermissionPolicy: Encodable {
    let appRuntimeRequiresAutomationPermission = false
    let fixtureGenerationRequiresAutomationPermission = false
    let manualCrashValidationRequiresAutomationPermission = false
    let automatedKeyInjectionImplemented = false
    let screenCaptureImplemented = false
}

private struct ReproducerManifest: Encodable {
    let schemaVersion = 1
    let status: String
    let createdAt: String
    let generatorVersion: String
    let generatorBinary: ArtifactReference
    let crashEvidence: ArtifactReference?
    let manualAction: ManualActionContract
    let permissionPolicy: PermissionPolicy
    let fixtures: [String: FixtureRecord]
    let originalPDF: FixtureRecord?
    let remainingAcceptance: [String]
}

private enum ProbeError: Error, LocalizedError {
    case usage(String)
    case missingOption(String)
    case invalidPDF(String)
    case wrongPageCount(identifier: String, expected: Int, actual: Int)
    case invalidSize(identifier: String, bytes: Int64, expected: String)

    var errorDescription: String? {
        switch self {
        case let .usage(message): message
        case let .missingOption(option): "Missing required option: \(option)"
        case let .invalidPDF(path): "Could not open generated PDF: \(path)"
        case let .wrongPageCount(identifier, expected, actual):
            "Fixture \(identifier) has \(actual) pages; expected \(expected)."
        case let .invalidSize(identifier, bytes, expected):
            "Fixture \(identifier) is \(bytes) bytes; expected \(expected)."
        }
    }
}

private struct ParsedArguments {
    let command: String
    let options: [String: String]

    init(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            throw ProbeError.usage(Self.usage)
        }
        self.command = command

        var options: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), index + 1 < arguments.count else {
                throw ProbeError.usage(Self.usage)
            }
            options[key] = arguments[index + 1]
            index += 2
        }
        self.options = options
    }

    func required(_ name: String) throws -> String {
        guard let value = options[name], !value.isEmpty else {
            throw ProbeError.missingOption(name)
        }
        return value
    }

    static let usage = """
    Usage:
      PDFReaderOpenProbe generate-fixtures --output <directory> --manifest <file> [--original <pdf>] [--crash-evidence <json>]
      PDFReaderOpenProbe inspect --pdf <file>

    This test-only tool generates and inspects local PDF fixtures. It never injects
    keyboard input, controls another process, or captures the screen.
    """
}

@main
@MainActor
private struct PDFReaderOpenProbe {
    static func main() {
        do {
            let arguments = try ParsedArguments(Array(CommandLine.arguments.dropFirst()))
            switch arguments.command {
            case "generate-fixtures":
                try generateFixtures(arguments)
            case "inspect":
                let record = try inspectPDF(
                    identifier: "O",
                    url: fileURL(try arguments.required("--pdf")),
                    sentinel: nil
                )
                try writeJSON(record, to: nil)
            default:
                throw ProbeError.usage(ParsedArguments.usage)
            }
        } catch {
            FileHandle.standardError.write(Data("PDFReaderOpenProbe: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func generateFixtures(_ arguments: ParsedArguments) throws {
        let fileManager = FileManager.default
        let outputDirectory = fileURL(try arguments.required("--output"))
        let manifestURL = fileURL(try arguments.required("--manifest"))
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var fixtures: [String: FixtureRecord] = [:]
        for kind in PerformancePDFFixtureKind.allCases {
            let destination = outputDirectory.appendingPathComponent(kind.fileName)
            try? fileManager.removeItem(at: destination)
            let url = try PDFFixtureFactory.makePerformancePDF(kind, in: outputDirectory)
            let record = try inspectPDF(
                identifier: kind.rawValue,
                url: url,
                sentinel: PDFFixtureFactory.performanceSentinel(for: kind)
            )
            try validate(record, as: kind)
            fixtures[kind.rawValue] = record
        }

        let originalPDF = try arguments.options["--original"].map {
            try inspectPDF(identifier: "O", url: fileURL($0), sentinel: nil)
        }
        let crashEvidence = try arguments.options["--crash-evidence"].map {
            try artifactReference(fileURL($0))
        }
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let manifest = ReproducerManifest(
            status: originalPDF == nil ? "blocked-original-pdf-missing" : "prepared-manual-validation-pending",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            generatorVersion: PDFFixtureFactory.performanceFixtureGeneratorVersion,
            generatorBinary: try artifactReference(executableURL),
            crashEvidence: crashEvidence,
            manualAction: ManualActionContract(),
            permissionPolicy: PermissionPolicy(),
            fixtures: fixtures,
            originalPDF: originalPDF,
            remainingAcceptance: [
                "Run the signed Release app with F and O.",
                "Press h twice through the normal application input path.",
                "Confirm no crash, hang, abnormal exit, or new matching .ips report.",
                "Record subjective first-page readiness separately; no screen-capture permission is required.",
            ]
        )
        try writeJSON(manifest, to: manifestURL)
        print(manifestURL.path)
    }

    private static func inspectPDF(
        identifier: String,
        url: URL,
        sentinel: PerformancePDFSentinel?
    ) throws -> FixtureRecord {
        guard let document = PDFDocument(url: url) else {
            throw ProbeError.invalidPDF(url.path)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return FixtureRecord(
            identifier: identifier,
            path: url.standardizedFileURL.path,
            sha256: try PDFFixtureFactory.sha256(of: url),
            byteSize: size,
            pageCount: document.pageCount,
            locked: document.isLocked,
            sentinel: sentinel,
            validation: "passed"
        )
    }

    private static func validate(
        _ record: FixtureRecord,
        as kind: PerformancePDFFixtureKind
    ) throws {
        guard record.pageCount == kind.pageCount else {
            throw ProbeError.wrongPageCount(
                identifier: kind.rawValue,
                expected: kind.pageCount,
                actual: record.pageCount
            )
        }
        let mebibyte: Int64 = 1_048_576
        let valid: Bool
        let expectation: String
        switch kind {
        case .S:
            valid = record.byteSize > 0 && record.byteSize <= mebibyte
            expectation = "0 < size <= 1 MiB"
        case .L:
            valid = record.byteSize > 0 && record.byteSize <= 8 * mebibyte
            expectation = "0 < size <= 8 MiB"
        case .F:
            valid = record.byteSize >= 20 * mebibyte && record.byteSize <= 40 * mebibyte
            expectation = "20 MiB <= size <= 40 MiB"
        case .B:
            valid = record.byteSize > 0 && record.byteSize <= mebibyte
            expectation = "0 < size <= 1 MiB"
        }
        guard valid else {
            throw ProbeError.invalidSize(
                identifier: kind.rawValue,
                bytes: record.byteSize,
                expected: expectation
            )
        }
    }

    private static func artifactReference(_ url: URL) throws -> ArtifactReference {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return ArtifactReference(
            path: url.standardizedFileURL.path,
            sha256: sha256(url),
            byteSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0
        )
    }

    private static func sha256(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "unavailable" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL?) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value) + Data("\n".utf8)
        if let url {
            try data.write(to: url, options: .atomic)
        } else {
            FileHandle.standardOutput.write(data)
        }
    }
}
