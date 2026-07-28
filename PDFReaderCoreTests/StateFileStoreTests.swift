import Foundation
import PDFReaderCore
import Testing

@Suite("Shared state file transactions")
struct StateFileStoreTests {
    @Test("Theme and recent-file updates preserve each other and unknown keys")
    func fieldsCoexistAndUnknownKeysSurvive() throws {
        try withFileURL { fileURL in
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{\"future\":{\"keep\":true}}".utf8).write(to: fileURL)
            #expect(ThemeSelectionStore(fileURL: fileURL).persist(.dracula) == .persisted)
            #expect(RecentFilesStore(fileURL: fileURL).recordOpened(absolutePath: "/tmp/a.pdf") == .persisted)

            #expect(ThemeSelectionStore(fileURL: fileURL).load() == .selected(.dracula))
            #expect(RecentFilesStore(fileURL: fileURL).load().map(\.absolutePath) == ["/tmp/a.pdf"])
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
            #expect((object?["future"] as? [String: Bool])?["keep"] == true)
        }
    }

    @Test("A legacy theme-only file remains readable")
    func legacyThemeOnlyFile() throws {
        try withFileURL { fileURL in
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{\"selected_theme\":\"dracula\"}".utf8).write(to: fileURL)
            #expect(ThemeSelectionStore(fileURL: fileURL).load() == .selected(.dracula))
            #expect(RecentFilesStore(fileURL: fileURL).load().isEmpty)
        }
    }

    @Test("Malformed sibling fields are isolated")
    func malformedSiblingIsolation() throws {
        try withFileURL { fileURL in
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{\"selected_theme\":\"dracula\",\"recent_files\":{}}".utf8).write(to: fileURL)
            #expect(ThemeSelectionStore(fileURL: fileURL).load() == .selected(.dracula))
            #expect(RecentFilesStore(fileURL: fileURL).load().isEmpty)

            try Data("{\"selected_theme\":{},\"recent_files\":[{\"absolute_path\":\"/tmp/a.pdf\",\"last_opened_at\":0}]}".utf8).write(to: fileURL)
            #expect(ThemeSelectionStore(fileURL: fileURL).load() == .invalid)
            #expect(RecentFilesStore(fileURL: fileURL).load().map(\.absolutePath) == ["/tmp/a.pdf"])
        }
    }

    @Test("Stat follows usable symlinks and prunes only missing paths")
    func pathExistenceClassification() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PathExistenceCheckTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("file.pdf")
        try Data().write(to: file)
        let link = directory.appendingPathComponent("link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(PathExistenceCheck.classify(file.path) == .regularFile)
        #expect(PathExistenceCheck.classify(link.path) == .regularFile)
        try FileManager.default.removeItem(at: file)
        #expect(PathExistenceCheck.classify(link.path) == .missing)
        #expect(PathExistenceCheck.classify(directory.appendingPathComponent("none.pdf").path) == .missing)
        #expect(PathExistenceCheck.classify(directory.path) == .notAFile(reason: "경로가 폴더입니다"))
    }

    @Test("Only ENOENT and ENOTDIR are missing; directories and denied parents are retained")
    func errnoClassificationBoundaries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PathErrnoTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let intermediateFile = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: intermediateFile)
        #expect(PathExistenceCheck.classify(intermediateFile.appendingPathComponent("child.pdf").path) == .missing)

        let denied = directory.appendingPathComponent("denied", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        let deniedFile = denied.appendingPathComponent("file.pdf")
        try Data().write(to: deniedFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        #expect(PathExistenceCheck.classify(deniedFile.path) == .notAFile(reason: "권한이 없습니다"))
    }


    @Test("State updates write state.json with owner-only permissions")
    func stateFilePermissionsAreOwnerOnly() throws {
        try withFileURL { fileURL in
            #expect(StateFileStore(fileURL: fileURL).update { $0.selectedTheme = "dracula" } == .persisted)
            let permissions = try #require(FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber)
            #expect(permissions.intValue & 0o777 == 0o600)
        }
    }
    private func withFileURL(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StateFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("state.json"))

    }
    @Test("Separate child processes preserve independently updated fields")
    func childProcessConcurrentUpdates() throws {
        try withFileURL { fileURL in
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let helperSource = directory.appendingPathComponent("main.swift") // top-level code requires main.swift
            let helper = directory.appendingPathComponent("StateFileStoreChild")
            let barrier = directory.appendingPathComponent("barrier")
            try Data("""
            import Foundation
            let stateURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let barrierURL = URL(fileURLWithPath: CommandLine.arguments[2])
            let field = CommandLine.arguments[3]
            while !FileManager.default.fileExists(atPath: barrierURL.path) {
                Thread.sleep(forTimeInterval: 0.01)
            }
            let store = StateFileStore(fileURL: stateURL)
            _ = store.update { state in
                if field == "theme" {
                    state.selectedTheme = "dracula"
                } else {
                    state.recentFiles = [RecentFileEntryDTO(absolutePath: "/tmp/a.pdf", lastOpenedAt: Date())]
                }
            }
            """.utf8).write(to: helperSource)

            let coreSource = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("PDFReaderCore/Recent/StateFileStore.swift")
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            compiler.arguments = ["swiftc", coreSource.path, helperSource.path, "-o", helper.path]
            try compiler.run()
            compiler.waitUntilExit()
            #expect(compiler.terminationStatus == 0)

            let theme = Process()
            theme.executableURL = helper
            theme.arguments = [fileURL.path, barrier.path, "theme"]
            let recent = Process()
            recent.executableURL = helper
            recent.arguments = [fileURL.path, barrier.path, "recent"]
            try theme.run()
            try recent.run()
            try Data().write(to: barrier)
            theme.waitUntilExit()
            recent.waitUntilExit()
            #expect(theme.terminationStatus == 0)
            #expect(recent.terminationStatus == 0)
            guard case let .loaded(state) = StateFileStore(fileURL: fileURL).load() else {
                Issue.record("child updates did not produce a readable state file")
                return
            }
            #expect(state.selectedTheme == "dracula")
            #expect(state.recentFiles?.map(\.absolutePath) == ["/tmp/a.pdf"])
        }
    }
}
