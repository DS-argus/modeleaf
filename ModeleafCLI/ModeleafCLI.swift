import Darwin
import Foundation

struct CLIInvocation: Equatable {
    let executableURL: URL
    let arguments: [String]
}

protocol CLIProcessRunning {
    func run(_ invocation: CLIInvocation) throws -> Int32
}

struct SystemCLIProcessRunner: CLIProcessRunning {
    func run(_ invocation: CLIInvocation) throws -> Int32 {
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

struct CLIOutput {
    var standard: (String) -> Void
    var error: (String) -> Void

    static var terminal: CLIOutput {
        CLIOutput(
            standard: { write($0, to: .standardOutput) },
            error: { write($0, to: .standardError) }
        )
    }

    private static func write(_ text: String, to handle: FileHandle) {
        guard let data = (text + "\n").data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }
}

enum CLICommand: Equatable {
    case launch(paths: [String], newInstance: Bool)
    case update
    case remove
    case help
    case version
}

enum CLIParseError: Error, Equatable, LocalizedError {
    case unknownOption(String)
    case unexpectedArgument(String, command: String)
    case newInstanceNotSupported(command: String)

    var errorDescription: String? {
        switch self {
        case let .unknownOption(option):
            "unknown option: \(option)"
        case let .unexpectedArgument(argument, command):
            "unexpected argument for \(command): \(argument)"
        case let .newInstanceNotSupported(command):
            "--new cannot be used with \(command)"
        }
    }
}

enum CLIParser {
    static func parse(_ arguments: [String]) throws -> CLICommand {
        var newInstance = false
        var paths: [String] = []
        var explicitCommand: String?
        var treatsRemainingAsPaths = false

        for argument in arguments {
            if treatsRemainingAsPaths {
                paths.append(argument)
                continue
            }
            if argument == "--" {
                treatsRemainingAsPaths = true
                continue
            }
            switch argument {
            case "-h", "--help":
                return .help
            case "-v", "--version":
                return .version
            case "-n", "--new":
                newInstance = true
            case "open", "update", "remove" where explicitCommand == nil && paths.isEmpty:
                explicitCommand = argument
            default:
                if argument.hasPrefix("-") {
                    throw CLIParseError.unknownOption(argument)
                }
                if let explicitCommand, explicitCommand != "open" {
                    throw CLIParseError.unexpectedArgument(argument, command: explicitCommand)
                }
                paths.append(argument)
            }
        }

        switch explicitCommand {
        case "update":
            if let first = paths.first {
                throw CLIParseError.unexpectedArgument(first, command: "update")
            }
            guard !newInstance else { throw CLIParseError.newInstanceNotSupported(command: "update") }
            return .update
        case "remove":
            if let first = paths.first {
                throw CLIParseError.unexpectedArgument(first, command: "remove")
            }
            guard !newInstance else { throw CLIParseError.newInstanceNotSupported(command: "remove") }
            return .remove
        case "open", nil:
            return .launch(paths: paths, newInstance: newInstance)
        default:
            preconditionFailure("parser accepted an unknown command")
        }
    }
}

enum CLIInputError: Error, Equatable, LocalizedError {
    case missing(String)
    case notAFile(String)
    case unreadable(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case let .missing(path): "file not found: \(path)"
        case let .notAFile(path): "not a file: \(path)"
        case let .unreadable(path): "file is not readable: \(path)"
        case let .unsupported(path): "only PDF files are supported: \(path)"
        }
    }
}

struct CLIPathResolver {
    let fileManager: FileManager
    let workingDirectory: URL

    func resolve(_ paths: [String]) throws -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        result.reserveCapacity(paths.count)

        for rawPath in paths {
            let expanded = (rawPath as NSString).expandingTildeInPath
            let unresolved = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded)
                : workingDirectory.appendingPathComponent(expanded)
            let standardized = unresolved.standardizedFileURL
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else {
                throw CLIInputError.missing(standardized.path)
            }
            guard !isDirectory.boolValue else {
                throw CLIInputError.notAFile(standardized.path)
            }
            guard standardized.pathExtension.lowercased() == "pdf" else {
                throw CLIInputError.unsupported(standardized.path)
            }
            guard fileManager.isReadableFile(atPath: standardized.path) else {
                throw CLIInputError.unreadable(standardized.path)
            }

            let canonical = standardized.resolvingSymlinksInPath()
            if seen.insert(canonical.path).inserted {
                result.append(canonical)
            }
        }
        return result
    }
}

struct AppBundleVersionProvider {
    let executableURL: URL

    func version() -> String? {
        var candidate = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension.lowercased() == "app",
               let bundle = Bundle(url: candidate),
               let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               !version.isEmpty {
                return version
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}

struct ModeleafCLI {
    static let bundleIdentifier = "com.argus.modeleaf"

    let processRunner: any CLIProcessRunning
    let fileManager: FileManager
    let workingDirectory: URL
    let versionProvider: () -> String?
    let output: CLIOutput

    init(
        processRunner: any CLIProcessRunning = SystemCLIProcessRunner(),
        fileManager: FileManager = .default,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        versionProvider: @escaping () -> String? = {
            AppBundleVersionProvider(executableURL: currentExecutableURL()).version()
        },
        output: CLIOutput = .terminal
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.workingDirectory = workingDirectory
        self.versionProvider = versionProvider
        self.output = output
    }

    func run(arguments: [String]) -> Int32 {
        do {
            switch try CLIParser.parse(arguments) {
            case let .launch(paths, newInstance):
                let urls = try CLIPathResolver(
                    fileManager: fileManager,
                    workingDirectory: workingDirectory
                ).resolve(paths)
                var openArguments: [String] = []
                if newInstance { openArguments.append("-n") }
                openArguments += ["-b", Self.bundleIdentifier]
                openArguments += urls.map(\.path)
                return try processRunner.run(
                    CLIInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/open"), arguments: openArguments)
                )
            case .update:
                return try runHomebrew(["upgrade", "--cask", "modeleaf"])
            case .remove:
                return try runHomebrew(["uninstall", "--cask", "modeleaf"])
            case .help:
                output.standard(Self.help)
                return 0
            case .version:
                guard let version = versionProvider() else {
                    output.error("modeleaf: could not determine the containing app version")
                    return 1
                }
                output.standard("modeleaf \(version)")
                return 0
            }
        } catch let error as CLIParseError {
            output.error("modeleaf: \(error.localizedDescription)\nTry 'modeleaf --help' for usage.")
            return 2
        } catch let error as CLIInputError {
            output.error("modeleaf: \(error.localizedDescription)")
            return 3
        } catch {
            output.error("modeleaf: \(error.localizedDescription)")
            return 1
        }
    }

    private func runHomebrew(_ arguments: [String]) throws -> Int32 {
        try processRunner.run(
            CLIInvocation(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["brew"] + arguments
            )
        )
    }

    static let help = """
    Usage:
      modeleaf [--new] [PDF ...]
      modeleaf open [--new] [PDF ...]
      modeleaf update
      modeleaf remove
      modeleaf --version
      modeleaf --help

    Commands:
      open       Open PDFs as tabs in Modeleaf (the default command)
      update     Update the Homebrew cask
      remove     Uninstall the Homebrew cask without deleting user configuration

    Options:
      -n, --new  Open a new Modeleaf instance
      -h, --help Show this help
      -v, --version  Show the installed Modeleaf version

    Exit status:
      0 on success, 2 for invalid usage, and 3 for invalid input.
      Launch Services and Homebrew failures preserve the child process status.

    Use -- before a path that begins with a hyphen or matches a command name.
    """
}

private func currentExecutableURL() -> URL {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else {
        return Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    }
    return URL(fileURLWithPath: String(cString: buffer))
}
