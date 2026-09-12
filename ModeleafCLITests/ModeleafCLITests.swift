import Foundation
import Testing
@testable import ModeleafCLI

@Suite("Modeleaf CLI")
struct ModeleafCLITests {
    @Test("no arguments activates or launches Modeleaf")
    func emptyLaunch() throws {
        let fixture = try Fixture()
        #expect(fixture.run() == 0)
        #expect(fixture.runner.invocations == [
            CLIInvocation(
                executableURL: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: ["-b", ModeleafCLI.bundleIdentifier]
            ),
        ])
    }

    @Test("default and explicit open normalize, preserve order, and deduplicate PDF paths")
    func opensPDFs() throws {
        let fixture = try Fixture()
        let first = try fixture.makeFile("reports/one.pdf")
        let second = try fixture.makeFile("two spaces.pdf")
        let symlink = fixture.directory.appendingPathComponent("alias.pdf")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: first)

        #expect(fixture.run("open", "reports/../reports/one.pdf", second.path, symlink.path) == 0)
        #expect(fixture.runner.invocations.only?.arguments == [
            "-b", ModeleafCLI.bundleIdentifier,
            first.resolvingSymlinksInPath().path,
            second.path,
        ])
    }

    @Test("new instance is forwarded to Launch Services")
    func newInstance() throws {
        let fixture = try Fixture()
        let pdf = try fixture.makeFile("sample.pdf")

        #expect(fixture.run("--new", "sample.pdf") == 0)
        #expect(fixture.runner.invocations.only?.arguments == [
            "-n", "-b", ModeleafCLI.bundleIdentifier, pdf.path,
        ])
    }

    @Test("double dash treats command names and hyphen-prefixed values as paths")
    func doubleDashPaths() throws {
        let fixture = try Fixture()
        let update = try fixture.makeFile("update")
        let hyphen = try fixture.makeFile("-report.pdf")

        #expect(fixture.run("--", "update") == 3)
        #expect(fixture.error.only?.contains("only PDF files") == true)

        fixture.resetOutput()
        #expect(fixture.run("open", "--", "-report.pdf") == 0)
        #expect(fixture.runner.invocations.only?.arguments.last == hyphen.path)
        #expect(FileManager.default.fileExists(atPath: update.path))
    }

    @Test("missing, directory, and unsupported inputs fail before launching")
    func rejectsInvalidInputs() throws {
        let cases: [(String, String)] = [
            ("missing.pdf", "file not found"),
            ("folder.pdf", "not a file"),
            ("notes.txt", "only PDF files"),
        ]
        for (path, diagnostic) in cases {
            let fixture = try Fixture()
            if path == "folder.pdf" {
                try FileManager.default.createDirectory(
                    at: fixture.directory.appendingPathComponent(path),
                    withIntermediateDirectories: true
                )
            } else if path == "notes.txt" {
                _ = try fixture.makeFile(path)
            }
            #expect(fixture.run(path) == 3)
            #expect(fixture.runner.invocations.isEmpty)
            #expect(fixture.error.only?.contains(diagnostic) == true)
        }
    }

    @Test("unknown options and invalid command combinations are usage errors")
    func rejectsInvalidSyntax() throws {
        for arguments in [
            ["--bogus"],
            ["update", "extra"],
            ["remove", "extra"],
            ["update", "--", "extra"],
            ["remove", "--", "extra"],
            ["--new", "update"],
        ] {
            let fixture = try Fixture()
            #expect(fixture.run(arguments) == 2)
            #expect(fixture.runner.invocations.isEmpty)
            #expect(fixture.error.only?.contains("Try 'modeleaf --help'") == true)
        }
    }

    @Test("help and version do not launch a process")
    func helpAndVersion() throws {
        let help = try Fixture(version: "9.8.7")
        #expect(help.run("--help") == 0)
        #expect(help.standard.only?.contains("modeleaf [--new] [PDF ...]") == true)
        #expect(help.runner.invocations.isEmpty)

        for option in ["-v", "--version"] {
            let version = try Fixture(version: "9.8.7")
            #expect(version.run(option) == 0)
            #expect(version.standard == ["modeleaf 9.8.7"])
            #expect(version.runner.invocations.isEmpty)
        }
    }

    @Test("version fails clearly outside an app bundle")
    func missingVersion() throws {
        let fixture = try Fixture(version: nil)
        #expect(fixture.run("--version") == 1)
        #expect(fixture.error == ["modeleaf: could not determine the containing app version"])
    }

    @Test("update and remove delegate to Homebrew without modifying configuration")
    func homebrewCommands() throws {
        let update = try Fixture()
        #expect(update.run("update") == 0)
        #expect(update.runner.invocations == [
            CLIInvocation(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["brew", "upgrade", "--cask", "modeleaf"]
            ),
        ])

        let remove = try Fixture()
        #expect(remove.run("remove") == 0)
        #expect(remove.runner.invocations == [
            CLIInvocation(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["brew", "uninstall", "--cask", "modeleaf"]
            ),
        ])
    }

    @Test("failed exec returns a POSIX error without replacing the test process")
    func execFailure() {
        let executable = URL(fileURLWithPath: "/definitely/missing/modeleaf-" + UUID().uuidString)
        #expect(throws: POSIXError(.ENOENT)) {
            try SystemCLIProcessRunner().run(
                CLIInvocation(executableURL: executable, arguments: ["sentinel", "--value"])
            )
        }
    }

    @Test("child exit status is preserved")
    func preservesExitStatus() throws {
        let fixture = try Fixture(status: 42)
        #expect(fixture.run("update") == 42)
        #expect(fixture.run("remove") == 42)
        #expect(fixture.run() == 42)
    }

    @Test("version is read from the app bundle containing the CLI")
    func appBundleVersion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModeleafCLIVersionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = directory.appendingPathComponent("Modeleaf.app/Contents", isDirectory: true)
        let executable = contents.appendingPathComponent("SharedSupport/modeleaf")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.argus.modeleaf",
            "CFBundleName": "Modeleaf",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "7.6.5",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try Data().write(to: executable)

        #expect(AppBundleVersionProvider(executableURL: executable).version() == "7.6.5")
    }
}

private final class RecordingRunner: CLIProcessRunning {
    var invocations: [CLIInvocation] = []
    let status: Int32

    init(status: Int32) {
        self.status = status
    }

    func run(_ invocation: CLIInvocation) throws -> Int32 {
        invocations.append(invocation)
        return status
    }
}

private final class OutputRecorder {
    var standard: [String] = []
    var error: [String] = []
}

private final class Fixture {
    let directory: URL
    let runner: RecordingRunner
    private let outputRecorder: OutputRecorder
    private let cli: ModeleafCLI

    var standard: [String] { outputRecorder.standard }
    var error: [String] { outputRecorder.error }

    init(status: Int32 = 0, version: String? = "0.11.1") throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModeleafCLITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        runner = RecordingRunner(status: status)
        let outputRecorder = OutputRecorder()
        self.outputRecorder = outputRecorder
        cli = ModeleafCLI(
            processRunner: runner,
            workingDirectory: directory,
            versionProvider: { version },
            output: CLIOutput(
                standard: { outputRecorder.standard.append($0) },
                error: { outputRecorder.error.append($0) }
            )
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeFile(_ relativePath: String) throws -> URL {
        let url = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("%PDF-1.7\n".utf8).write(to: url)
        return url.standardizedFileURL
    }

    func run(_ arguments: String...) -> Int32 {
        cli.run(arguments: arguments)
    }

    func run(_ arguments: [String]) -> Int32 {
        cli.run(arguments: arguments)
    }

    func resetOutput() {
        outputRecorder.standard.removeAll()
        outputRecorder.error.removeAll()
        runner.invocations.removeAll()
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
