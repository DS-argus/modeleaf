import AppKit
import Foundation
import Step0ProbeSupport

@main
@MainActor
struct Step0ProbeMain {
    static func main() throws {
        let outputURL = outputLocation(arguments: CommandLine.arguments)
        let report = try Step0ProbeRunner.run()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))

        guard report.passed else {
            throw ProbeFailure.failed(report.sections)
        }
    }

    private static func outputLocation(arguments: [String]) -> URL {
        if let index = arguments.firstIndex(of: "--output"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1])
        }
        return URL(fileURLWithPath: "artifacts/verification/step0/report.json")
    }
}
