import AppKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

// Deterministic native-window boundary tests. XCUIApplication separately proves
// delivery from the real application surface; these tests prove event ownership,
// Enter-finish, Escape-cancel, and the recorder outcomes without global permissions.
@Suite("Shortcut recording session", .serialized)
@MainActor
struct ShortcutRecordingSessionTests {
    @Test("The same event offered by menu and window routes is recorded only once")
    func sameEventOnce() throws {
        let window = makeWindow()
        defer { window.close() }
        var outcome: ShortcutRecordingSession.Outcome?
        var readerCalls = 0
        window.keyEventHandler = { _ in readerCalls += 1; return true }
        let session = ShortcutRecordingSession(
            window: window,
            target: .binding(prefix: prefixToken),
            acceptsEvent: { $1.windowNumber == $0.windowNumber },
            onChange: { _, _ in },
            onFinish: { outcome = $0 }
        )
        session.start()
        let input = try event("x", code: 7, in: window)
        #expect(window.performKeyEquivalent(with: input))
        window.sendEvent(input)
        window.sendEvent(try event("\r", code: 36, in: window))
        #expect(outcome == .recorded("x"))
        #expect(readerCalls == 0)
        window.sendEvent(try event("j", code: 38, in: window))
        #expect(readerCalls == 1)
    }

    @Test("Non-empty Escape cancels without committing the displayed candidate")
    func nonEmptyEscapeCancels() throws {
        let window = makeWindow()
        defer { window.close() }
        var outcome: ShortcutRecordingSession.Outcome?
        var changes: [(String, String?)] = []
        let session = ShortcutRecordingSession(
            window: window,
            target: .binding(prefix: prefixToken),
            acceptsEvent: { $1.windowNumber == $0.windowNumber },
            onChange: { changes.append(($0, $1)) },
            onFinish: { outcome = $0 }
        )
        session.start()
        window.sendEvent(try event("z", code: 6, in: window))
        #expect(changes.last?.0 == "z")
        window.sendEvent(try event("\u{1b}", code: 53, in: window))
        #expect(outcome == .cancelled)
    }

    @Test("Binding capture records two plain keys and finishes on Enter")
    func plainPairAndEnter() throws {
        let window = makeWindow()
        defer { window.close() }
        var forwarded = 0
        window.keyEventHandler = { _ in forwarded += 1; return true }
        var outcome: ShortcutRecordingSession.Outcome?
        var changes: [(String, String?)] = []
        let session = ShortcutRecordingSession(
            window: window,
            target: .binding(prefix: prefixToken),
            acceptsEvent: { eventWindow, event in event.windowNumber == eventWindow.windowNumber },
            onChange: { changes.append(($0, $1)) },
            onFinish: { outcome = $0 }
        )
        session.start()
        window.sendEvent(try event("j", code: 38, in: window))
        window.sendEvent(try event("k", code: 40, in: window))
        #expect(changes.last?.0 == "j → k")
        window.sendEvent(try event("\r", code: 36, in: window))
        #expect(outcome == .recorded("jk"))
        #expect(forwarded == 0)
        #expect(window.shortcutRecorder == nil)
    }

    @Test("Actual prefix followed by one plain key is stored symbolically on Enter")
    func autoPrefix() throws {
        let window = makeWindow()
        defer { window.close() }
        var outcome: ShortcutRecordingSession.Outcome?
        let session = ShortcutRecordingSession(
            window: window,
            target: .binding(prefix: prefixToken),
            acceptsEvent: { $1.windowNumber == $0.windowNumber },
            onChange: { _, _ in },
            onFinish: { outcome = $0 }
        )
        session.start()
        window.sendEvent(try event("b", code: 11, modifiers: .control, in: window))
        window.sendEvent(try event("z", code: 6, in: window))
        window.sendEvent(try event("\r", code: 36, in: window))
        #expect(outcome == .recorded("<prefix>z"))
    }

    @Test("Slash is captured literally; unmodified Enter finishes and modified Enter remains valid")
    func slashAndEnter() throws {
        let window = makeWindow()
        defer { window.close() }
        var outcome: ShortcutRecordingSession.Outcome?
        let session = ShortcutRecordingSession(
            window: window,
            target: .binding(prefix: prefixToken),
            acceptsEvent: { $1.windowNumber == $0.windowNumber },
            onChange: { _, _ in },
            onFinish: { outcome = $0 }
        )
        session.start()
        window.sendEvent(try event("/", code: 44, in: window))
        window.sendEvent(try event("\r", code: 36, in: window))
        #expect(outcome == .recorded("/"))

        var modifiedOutcome: ShortcutRecordingSession.Outcome?
        let modified = ShortcutRecordingSession(
            window: window,
            target: .binding(prefix: prefixToken),
            acceptsEvent: { $1.windowNumber == $0.windowNumber },
            onChange: { _, _ in },
            onFinish: { modifiedOutcome = $0 }
        )
        modified.start()
        window.sendEvent(try event("\r", code: 36, modifiers: .command, in: window))
        window.sendEvent(try event("\r", code: 36, in: window))
        #expect(modifiedOutcome == .recorded("<D-Enter>"))
    }

    @Test("A shared-prefix follower accepts command and Shift modifiers")
    func modifiedPrefixFollower() throws {
        let window = makeWindow()
        defer { window.close() }
        var outcome: ShortcutRecordingSession.Outcome?
        let session = ShortcutRecordingSession(
            window: window,
            target: .binding(prefix: prefixToken),
            acceptsEvent: { $1.windowNumber == $0.windowNumber },
            onChange: { _, _ in },
            onFinish: { outcome = $0 }
        )
        session.start()
        window.sendEvent(try event("b", code: 11, modifiers: .control, in: window))
        let originalUnmodifiedCharactersProvider = AppKitKeyEventAdapter.unmodifiedCharactersProvider
        AppKitKeyEventAdapter.unmodifiedCharactersProvider = { _ in "k" }
        defer { AppKitKeyEventAdapter.unmodifiedCharactersProvider = originalUnmodifiedCharactersProvider }
        window.sendEvent(try event("K", code: 40, modifiers: [.command, .shift], in: window))
        window.sendEvent(try event("\r", code: 36, in: window))
        #expect(outcome == .recorded("<prefix><D-S-k>"))
        #expect(try KeySequenceParser.parseSingleToken("<D-S-k>").description == "<D-S-k>")
    }

    @Test("A physically shifted U is captured as a canonical direct single")
    func shiftedUSingle() throws {
        let window = makeWindow()
        defer { window.close() }
        var outcome: ShortcutRecordingSession.Outcome?
        let session = ShortcutRecordingSession(
            window: window,
            target: .binding(prefix: prefixToken),
            acceptsEvent: { $1.windowNumber == $0.windowNumber },
            onChange: { _, _ in },
            onFinish: { outcome = $0 }
        )
        session.start()
        window.sendEvent(try event("U", code: 32, modifiers: .shift, in: window))
        window.sendEvent(try event("\r", code: 36, in: window))
        #expect(outcome == .recorded("U"))
    }

    @Test("Invalid input reports invalid on Enter and never reaches the reader")
    func overlengthIsInvalidOnEnter() throws {
        let window = makeWindow()
        defer { window.close() }
        var forwarded = 0
        window.keyEventHandler = { _ in forwarded += 1; return true }
        var outcome: ShortcutRecordingSession.Outcome?
        var errors: [String] = []
        let session = ShortcutRecordingSession(
            window: window,
            target: .binding(prefix: prefixToken),
            acceptsEvent: { $1.windowNumber == $0.windowNumber },
            onChange: { _, error in if let error { errors.append(error) } },
            onFinish: { outcome = $0 }
        )
        session.start()
        for (character, code) in [("a", UInt16(0)), ("b", UInt16(11)), ("c", UInt16(8))] {
            window.sendEvent(try event(character, code: code, in: window))
        }
        #expect(!errors.isEmpty)
        window.sendEvent(try event("\r", code: 36, in: window))
        guard case let .invalid(message) = outcome else {
            Issue.record("Expected invalid outcome, got \(String(describing: outcome))")
            return
        }
        #expect(message.contains("physically unmodified"))
        #expect(forwarded == 0)
    }

    @Test("Cmd-Q/W/O/P are consumed by capture before menu equivalents and finish on Enter")
    func commandSuppression() throws {
        let window = makeWindow()
        defer { window.close() }
        var forwarded = 0
        window.keyEventHandler = { _ in forwarded += 1; return true }
        for (key, code) in [("q", UInt16(12)), ("w", UInt16(13)), ("o", UInt16(31)), ("p", UInt16(35))] {
            var outcome: ShortcutRecordingSession.Outcome?
            let session = ShortcutRecordingSession(
                window: window,
                target: .binding(prefix: prefixToken),
                acceptsEvent: { $1.windowNumber == $0.windowNumber },
                onChange: { _, _ in },
                onFinish: { outcome = $0 }
            )
            session.start()
            #expect(window.performKeyEquivalent(with: try event(key, code: code, modifiers: .command, in: window)))
            window.sendEvent(try event("\r", code: 36, in: window))
            #expect(outcome == .recorded("<D-\(key)>"))
        }
        #expect(forwarded == 0)
    }

    @Test("Empty Enter unbinds a binding but cancels a blank prefix recording")
    func blankOutcomes() throws {
        let window = makeWindow()
        defer { window.close() }
        var bindingOutcome: ShortcutRecordingSession.Outcome?
        let binding = ShortcutRecordingSession(
            window: window,
            target: .binding(prefix: prefixToken),
            acceptsEvent: { $1.windowNumber == $0.windowNumber },
            onChange: { _, _ in },
            onFinish: { bindingOutcome = $0 }
        )
        binding.start()
        window.sendEvent(try event("\r", code: 36, in: window))
        #expect(bindingOutcome == .recorded(""))

        var prefixOutcome: ShortcutRecordingSession.Outcome?
        let prefix = ShortcutRecordingSession(
            window: window,
            target: .prefix,
            acceptsEvent: { $1.windowNumber == $0.windowNumber },
            onChange: { _, _ in },
            onFinish: { prefixOutcome = $0 }
        )
        prefix.start()
        window.sendEvent(try event("\r", code: 36, in: window))
        #expect(prefixOutcome == .cancelled)
    }

    @Test("A repeated starting Enter is ignored and does not finish a later recording")
    func repeatedStartingEnter() throws {
        let window = makeWindow()
        defer { window.close() }
        var outcome: ShortcutRecordingSession.Outcome?
        let session = ShortcutRecordingSession(
            window: window,
            target: .binding(prefix: prefixToken),
            acceptsEvent: { $1.windowNumber == $0.windowNumber },
            onChange: { _, _ in },
            onFinish: { outcome = $0 }
        )
        session.start()
        window.sendEvent(try event("\r", code: 36, isRepeat: true, in: window))
        #expect(outcome == nil)
        window.sendEvent(try event("x", code: 7, in: window))
        window.sendEvent(try event("\r", code: 36, in: window))
        #expect(outcome == .recorded("x"))
    }

    @Test("Window deactivation cancels and removes the recorder route")
    func lifecycleCleanup() throws {
        let window = makeWindow()
        defer { window.close() }
        var outcome: ShortcutRecordingSession.Outcome?
        let session = ShortcutRecordingSession(
            window: window,
            target: .prefix,
            acceptsEvent: { $1.windowNumber == $0.windowNumber },
            onChange: { _, _ in },
            onFinish: { outcome = $0 }
        )
        session.start()
        #expect(window.shortcutRecorder === session)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(outcome == .cancelled)
        #expect(window.shortcutRecorder == nil)
        #expect(!session.consume(try event("a", code: 0, in: window)))
    }

    private var prefixToken: KeyToken {
        KeyToken(symbol: .character("b"), modifiers: [.control])
    }

    private func makeWindow() -> ReaderWindow {
        _ = NSApplication.shared
        let window = ReaderWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func event(
        _ characters: String,
        code: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        isRepeat: Bool = false,
        in window: NSWindow
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isRepeat,
            keyCode: code
        ))
    }
}
