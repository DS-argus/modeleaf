import AppKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("AppKit key event adaptation")
@MainActor
struct AppKitKeyEventAdapterTests {
    /// Pins the adapter's layout-translation seam so synthesized Shift-chord
    /// events do not depend on the machine's active keyboard input source.
    private func withPinnedUnmodifiedCharacters(
        _ value: String,
        _ body: () throws -> Void
    ) rethrows {
        let original = AppKitKeyEventAdapter.unmodifiedCharactersProvider
        AppKitKeyEventAdapter.unmodifiedCharactersProvider = { _ in value }
        defer { AppKitKeyEventAdapter.unmodifiedCharactersProvider = original }
        try body()
    }

    @Test("literal uppercase Vim keys are preferred while explicit Shift chords remain candidates")
    func uppercaseCandidates() throws {
        let event = try #require(makeKeyEvent(
            characters: "G",
            charactersIgnoringModifiers: "G",
            modifiers: [.shift],
            keyCode: 5
        ))

        withPinnedUnmodifiedCharacters("g") {
            #expect(AppKitKeyEventAdapter.tokens(for: event).map(\.description) == ["G"])
        }
    }

    @Test("real AppKit Shift semantics still produce literal uppercase Vim keys")
    func uppercaseCandidatesWithShiftPreservedInCharactersIgnoringModifiers() throws {
        let event = try #require(makeKeyEvent(
            characters: "N",
            charactersIgnoringModifiers: "N",
            modifiers: [.shift],
            keyCode: 45
        ))

        withPinnedUnmodifiedCharacters("n") {
            let candidates = AppKitKeyEventAdapter.tokens(for: event).map(\.description)
            #expect(candidates.first == "N")
            #expect(candidates == ["N"])
        }
    }

    @Test("Shift-produced punctuation is preferred before the physical key chord")
    func shiftedPunctuationCandidates() throws {
        let event = try #require(makeKeyEvent(
            characters: "+",
            charactersIgnoringModifiers: "+",
            modifiers: [.shift],
            keyCode: 24
        ))

        withPinnedUnmodifiedCharacters("=") {
            #expect(
                AppKitKeyEventAdapter.tokens(for: event).map(\.description)
                    == ["+", "<S-=>", "<S-Equal>"]
            )
        }
    }

    @Test("Option and Command chords do not become produced-character literals")
    func modifiedPunctuationStaysAChord() throws {
        let option = try #require(makeKeyEvent(
            characters: "≠",
            charactersIgnoringModifiers: "=",
            modifiers: [.option]
        ))
        let command = try #require(makeKeyEvent(
            characters: "=",
            charactersIgnoringModifiers: "=",
            modifiers: [.command]
        ))

        #expect(AppKitKeyEventAdapter.tokens(for: option).map(\.description) == ["<A-=>", "<A-Equal>"])
        #expect(AppKitKeyEventAdapter.tokens(for: command).map(\.description) == ["<D-=>", "<D-Equal>"])
    }

    @Test("command and shifted return chords preserve only supported modifiers")
    func chordCandidates() throws {
        let commandOpen = try #require(makeKeyEvent(characters: "o", modifiers: [.command, .capsLock]))
        let shiftedReturn = try #require(makeKeyEvent(characters: "\r", modifiers: [.shift], keyCode: 36))

        #expect(AppKitKeyEventAdapter.tokens(for: commandOpen).map(\.description) == ["<D-o>"])
        #expect(AppKitKeyEventAdapter.tokens(for: shiftedReturn).map(\.description) == ["<S-Enter>"])
    }

    @Test("named navigation keys map to the stable key-token grammar")
    func namedKeys() throws {
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let event = try #require(makeKeyEvent(characters: left, keyCode: 123))

        #expect(AppKitKeyEventAdapter.tokens(for: event).map(\.description) == ["<Left>"])
    }

    @Test("physical Ctrl-I remains distinct from hardware Tab")
    func controlIVersusTab() throws {
        let controlI = try #require(makeKeyEvent(
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            modifiers: [.control],
            keyCode: 34
        ))
        let tab = try #require(makeKeyEvent(characters: "\t", keyCode: 48))

        #expect(AppKitKeyEventAdapter.tokens(for: controlI).map(\.description) == ["<C-i>"])
        #expect(AppKitKeyEventAdapter.tokens(for: tab).map(\.description) == ["<Tab>"])
    }

    @Test("empty and multi-scalar composition events stay native-capable tokens")
    func compositionTokens() throws {
        let deadKey = try #require(makeKeyEvent(characters: ""))
        let ime = try #require(makeKeyEvent(characters: "한글"))

        #expect(AppKitKeyEventAdapter.tokens(for: deadKey) == [.deadKey])
        #expect(AppKitKeyEventAdapter.tokens(for: ime) == [.imeComposition])
    }
    @Test("recording chooses the parseable named spelling for Ctrl-minus")
    func recordingCtrlMinus() throws {
        let event = try #require(makeKeyEvent(
            characters: "\u{001F}",
            charactersIgnoringModifiers: "-",
            modifiers: [.control],
            keyCode: 27
        ))

        let token = try #require(AppKitKeyEventAdapter.recordingToken(for: event))
        #expect(token.description == "<C-Minus>")
        let parsed = try KeySequenceParser.parseSingleToken(token.description)
        #expect(parsed == token)
    }

    @Test("recorded Shift keys preserve canonical literal identities")
    func recordingShiftKeys() throws {
        let uppercase = try #require(makeKeyEvent(
            characters: "U",
            charactersIgnoringModifiers: "U",
            modifiers: [.shift],
            keyCode: 32
        ))
        try withPinnedUnmodifiedCharacters("u") {
            let token = try #require(AppKitKeyEventAdapter.recordingToken(for: uppercase))
            #expect(token.description == "U")
            let parsed = try KeySequenceParser.parseSingleToken(token.description)
            #expect(parsed == token)
        }

        let punctuation = try #require(makeKeyEvent(
            characters: "|",
            charactersIgnoringModifiers: "|",
            modifiers: [.shift],
            keyCode: 42
        ))
        try withPinnedUnmodifiedCharacters("\\") {
            let token = try #require(AppKitKeyEventAdapter.recordingToken(for: punctuation))
            #expect(token.description == "|")
            let parsed = try KeySequenceParser.parseSingleToken(token.description)
            #expect(parsed == token)
        }
    }

    @Test("named delimiter and ordinary modifier recordings round trip through the parser")
    func recordingRoundTrips() throws {
        for (character, expected) in [("<", "<LT>"), (">", "<GT>")] {
            let event = try #require(makeKeyEvent(characters: character, keyCode: character == "<" ? 43 : 47))
            let token = try #require(AppKitKeyEventAdapter.recordingToken(for: event))
            #expect(token.description == expected)
            let parsed = try KeySequenceParser.parseSingleToken(token.description)
            #expect(parsed == token)
        }

        let modifiedEvents = [
            makeKeyEvent(characters: "k", modifiers: [.command], keyCode: 40),
            makeKeyEvent(characters: "k", modifiers: [.control], keyCode: 40),
            makeKeyEvent(characters: "k", modifiers: [.option], keyCode: 40),
            makeKeyEvent(characters: "=", charactersIgnoringModifiers: "=", modifiers: [.shift], keyCode: 24),
        ]
        for event in modifiedEvents {
            let event = try #require(event)
            let token = try #require(AppKitKeyEventAdapter.recordingToken(for: event))
            let parsed = try KeySequenceParser.parseSingleToken(token.description)
            #expect(parsed == token)
        }
    }

}

@MainActor
func makeKeyEvent(
    characters: String,
    charactersIgnoringModifiers: String? = nil,
    modifiers: NSEvent.ModifierFlags = [],
    keyCode: UInt16 = 0,
    isRepeat: Bool = false,
    windowNumber: Int = 0
) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
        isARepeat: isRepeat,
        keyCode: keyCode
    )
}
