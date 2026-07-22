import AppKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("AppKit key event adaptation")
@MainActor
struct AppKitKeyEventAdapterTests {
    @Test("literal uppercase Vim keys are preferred while explicit Shift chords remain candidates")
    func uppercaseCandidates() throws {
        let event = try #require(makeKeyEvent(
            characters: "G",
            charactersIgnoringModifiers: "g",
            modifiers: [.shift]
        ))

        #expect(AppKitKeyEventAdapter.tokens(for: event).map(\.description) == ["G", "<S-g>"])
    }

    @Test("command and shifted return chords preserve only supported modifiers")
    func chordCandidates() throws {
        let commandOpen = try #require(makeKeyEvent(characters: "o", modifiers: [.command, .capsLock]))
        let shiftedReturn = try #require(makeKeyEvent(characters: "\r", modifiers: [.shift], keyCode: 36))

        #expect(AppKitKeyEventAdapter.tokens(for: commandOpen).map(\.description) == ["<D-o>"])
        #expect(AppKitKeyEventAdapter.tokens(for: shiftedReturn).map(\.description) == ["<S-CR>"])
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
