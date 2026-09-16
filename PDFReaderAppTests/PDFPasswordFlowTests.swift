import AppKit
import PDFKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("Password-protected PDF application flow")
@MainActor
struct PDFPasswordFlowTests {
    @Test("native password prompt masks input and explains incorrect passwords")
    func nativePrompt() throws {
        let presenter = NativePDFPasswordPresenter()
        let url = URL(fileURLWithPath: "/tmp/private.pdf")
        let alert = presenter.makeAlert(for: url, invalidPassword: false)
        let field = try #require(alert.accessoryView as? NSSecureTextField)
        #expect(alert.window.initialFirstResponder === field)
        #expect(alert.buttons.map(\.title) == ["Open", "Cancel"])
        #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
        #expect(alert.informativeText.contains("private.pdf"))
        let retry = presenter.makeAlert(for: url, invalidPassword: true)
        #expect(retry.informativeText.contains("Incorrect password"))
        #expect(retry.informativeText.contains("Try again"))
    }

    @Test("wrong password then success inserts only one session in the requested pane")
    func retryAndTargetPane() throws {
        try withDirectory { directory in
            let normal = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 1)
            let locked = try PDFFixtureFactory.makeLockedPDF(in: directory)
            let originalBytes = try Data(contentsOf: locked)
            let prompt = PasswordPromptStub(responses: ["incorrect", "reader-test-secret"])
            let recents = RecentFilesStore(fileURL: directory.appendingPathComponent("recents.json"))
            let controller = makeController(directory: directory, prompt: prompt, recents: recents)
            defer { controller.mainWindowController.close() }
            #expect(controller.openDocument(at: normal))
            let target = try #require(controller.coordinator.activePaneID)
            _ = try #require(controller.coordinator.split(direction: .sideBySide))
            #expect(controller.coordinator.activePaneID != target)
            prompt.onRequest = {
                #expect(controller.coordinator.store(for: target)?.sessionCount == 1)
                #expect(!recents.load().contains { $0.absolutePath == locked.path })
            }

            #expect(controller.openDocument(at: locked, target: .existing(target)))
            #expect(prompt.invalidAttempts == [false, true])
            #expect(controller.coordinator.activePaneID == target)
            #expect(controller.coordinator.store(for: target)?.sessionCount == 2)
            #expect(controller.coordinator.activeSession?.pageCount == 1)
            #expect(controller.mainWindowController.window?.firstResponder === controller.coordinator.snapshot.activeFocusView)
            #expect(recents.load().map(\.absolutePath) == [locked.path, normal.path])
            let persisted = try String(contentsOf: directory.appendingPathComponent("recents.json"), encoding: .utf8)
            #expect(!persisted.contains("reader-test-secret"))
            #expect(!persisted.contains("incorrect"))
            #expect(try Data(contentsOf: locked) == originalBytes)
            #expect(PDFDocument(url: locked)?.isLocked == true)
        }
    }

    @Test("cancel leaves an empty workspace without recent-file state", arguments: [false, true])
    func cancelEmptyWorkspace(afterWrongPassword: Bool) throws {
        try withDirectory { directory in
            let locked = try PDFFixtureFactory.makeLockedPDF(in: directory)
            let prompt = PasswordPromptStub(responses: afterWrongPassword ? ["wrong", nil] : [nil])
            let recentsURL = directory.appendingPathComponent("recents.json")
            let recents = RecentFilesStore(fileURL: recentsURL)
            let controller = makeController(directory: directory, prompt: prompt, recents: recents)
            defer { controller.mainWindowController.close() }
            #expect(!controller.openDocument(at: locked))
            #expect(controller.coordinator.snapshot.panes.isEmpty)
            #expect(controller.mainWindowController.window?.firstResponder === controller.mainWindowController.rootView.emptyState.openButton)
            #expect(controller.sessionStore.sessionCount == 0)
            #expect(recents.load().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: recentsURL.path))
            #expect(prompt.invalidAttempts == (afterWrongPassword ? [false, true] : [false]))
        }
    }

    @Test("external cancel restores existing reader focus and continues to the next URL")
    func externalCancelAndContinue() throws {
        try withDirectory { directory in
            let first = try PDFFixtureFactory.makeTextPDF(in: directory, name: "first.pdf", pageCount: 1)
            let next = try PDFFixtureFactory.makeTextPDF(in: directory, name: "next.pdf", pageCount: 2)
            let locked = try PDFFixtureFactory.makeLockedPDF(in: directory)
            let prompt = PasswordPromptStub(responses: [nil, nil])
            let recents = RecentFilesStore(fileURL: directory.appendingPathComponent("recents.json"))
            let controller = makeController(directory: directory, prompt: prompt, recents: recents)
            defer { controller.mainWindowController.close() }
            #expect(controller.openDocument(at: first))
            let originalID = controller.coordinator.activeSession?.id
            controller.openExternalDocuments([locked])
            #expect(controller.coordinator.activeSession?.id == originalID)
            #expect(controller.mainWindowController.window?.firstResponder === controller.coordinator.snapshot.activeFocusView)
            #expect(recents.load().map(\.absolutePath) == [first.path])
            controller.openExternalDocuments([locked, next])
            #expect(controller.sessionStore.sessionCount == 2)
            #expect(controller.coordinator.activeSession?.pageCount == 2)
            #expect(recents.load().map(\.absolutePath) == [next.path, first.path])
        }
    }

    @Test("picker and external locked PDFs share the password flow")
    func pickerAndExternal() throws {
        try withDirectory { directory in
            let locked = try PDFFixtureFactory.makeLockedPDF(in: directory)
            let prompt = PasswordPromptStub(responses: ["reader-test-secret", "reader-test-secret"])
            let recents = RecentFilesStore(fileURL: directory.appendingPathComponent("recents.json"))
            let controller = makeController(directory: directory, prompt: prompt, recents: recents, picker: PasswordFlowOpenPanel(url: locked))
            defer { controller.mainWindowController.close() }
            _ = controller.mainWindowController
            controller.dispatch(.documentOpen)
            _ = controller.mainWindowController.routeKeyEventForTesting(try #require(makeKeyEvent(characters: "\r", keyCode: 36)))
            #expect(controller.sessionStore.sessionCount == 1)
            controller.openExternalDocuments([locked])
            #expect(controller.sessionStore.sessionCount == 2)
            #expect(prompt.invalidAttempts == [false, false])
            #expect(recents.load().map(\.absolutePath) == [locked.path])
        }
    }

    @Test("duplicating a protected PDF asks again and cancellation preserves the original pane")
    func protectedDuplication() throws {
        try withDirectory { directory in
            let locked = try PDFFixtureFactory.makeLockedPDF(in: directory)
            let prompt = PasswordPromptStub(responses: ["reader-test-secret", nil, "reader-test-secret"])
            let recents = RecentFilesStore(fileURL: directory.appendingPathComponent("recents.json"))
            let controller = makeController(directory: directory, prompt: prompt, recents: recents)
            defer { controller.mainWindowController.close() }
            #expect(controller.openDocument(at: locked))
            let originalID = controller.coordinator.activeSession?.id
            #expect(controller.coordinator.split(direction: .sideBySide) == nil)
            #expect(controller.coordinator.snapshot.panes.count == 1)
            #expect(controller.coordinator.activeSession?.id == originalID)
            #expect(controller.mainWindowController.window?.firstResponder === controller.coordinator.snapshot.activeFocusView)
            _ = try #require(controller.coordinator.split(direction: .sideBySide))
            #expect(controller.coordinator.snapshot.panes.count == 2)
            #expect(controller.coordinator.activeSession?.id != originalID)
            #expect(controller.coordinator.activeSession?.pageCount == 1)
            #expect(prompt.invalidAttempts == [false, false, false])
            #expect(recents.load().map(\.absolutePath) == [locked.path])
        }
    }
    private func makeController(
        directory: URL,
        prompt: PasswordPromptStub,
        recents: RecentFilesStore,
        picker: any PDFOpenPanelPresenting = NativePDFOpenPanelPresenter()
    ) -> ApplicationController {
        ApplicationController(
            configService: ConfigService(source: ConfigFileSource(url: directory.appendingPathComponent("missing.toml"))),
            openMetrics: NoopPDFOpenMetrics(),
            openPanelPresenter: picker,
            passwordPresenter: prompt,
            themeStore: ThemeSelectionStore(fileURL: directory.appendingPathComponent("theme.json")),
            indicatorSettingsStore: LinkDestinationIndicatorSettingsStore(fileURL: directory.appendingPathComponent("indicator.json")),
            recentFilesStore: recents,
            terminationHandler: {}
        )
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("password-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

@MainActor
private final class PasswordPromptStub: PDFPasswordPresenting {
    var responses: [String?]
    var invalidAttempts: [Bool] = []
    var onRequest: (() -> Void)?

    init(responses: [String?]) { self.responses = responses }

    func requestPassword(for url: URL, invalidPassword: Bool) -> String? {
        invalidAttempts.append(invalidPassword)
        onRequest?()
        guard !responses.isEmpty else {
            Issue.record("Unexpected password request")
            return nil
        }
        return responses.removeFirst()
    }
}

@MainActor
private final class PasswordFlowOpenPanel: PDFOpenPanelPresenting {
    let url: URL
    init(url: URL) { self.url = url }
    func present(attachedTo window: NSWindow?, completion: @escaping (URL?) -> Void) { completion(url) }
}
