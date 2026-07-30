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

        try withPinnedUnmodifiedCharacters("g") {
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

        try withPinnedUnmodifiedCharacters("n") {
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

        try withPinnedUnmodifiedCharacters("=") {
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

    @Test("empty and multi-scalar composition events stay native-capable tokens")
    func compositionTokens() throws {
        let deadKey = try #require(makeKeyEvent(characters: ""))
        let ime = try #require(makeKeyEvent(characters: "한글"))

        #expect(AppKitKeyEventAdapter.tokens(for: deadKey) == [.deadKey])
        #expect(AppKitKeyEventAdapter.tokens(for: ime) == [.imeComposition])
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
