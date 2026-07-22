import AppKit
import Foundation

@MainActor
public enum Step0ProbeRunner {
    public static func run() throws -> Step0Report {
        let sections = [
            ResponderPromptProbe.run(),
            InputAndMenuProbe.run(),
            try PDFCapabilityProbe.run(),
            try SearchProbe.run(),
            TOMLQualificationProbe.run(),
        ]

        return Step0Report(
            platform: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString); \(runtimeArchitecture())",
            sections: sections
        )
    }

    private static func runtimeArchitecture() -> String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
