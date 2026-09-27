import AppKit
import Testing
@testable import PDFReaderApp

@Suite("Settings close confirmation", .serialized)
@MainActor
struct SettingsCloseConfirmationTests {
    @Test("Escape, n, y, and Enter resolve the documented close choices")
    func keyboardChoices() throws {
        let cases: [(UInt16, String, SettingsCloseConfirmationView.Choice)] = [
            (53, "", .continueEditing),
            (0, "n", .discardAndClose),
            (0, "y", .saveAndClose),
            (36, "", .saveAndClose),
        ]

        for (keyCode, characters, expected) in cases {
            let prompt = makePrompt()
            #expect(prompt.selectedChoiceForTesting == .saveAndClose)
            let event = try #require(keyEvent(characters: characters, keyCode: keyCode))
            #expect(prompt.handleKeyDown(event))
            #expect(resolvedChoice(in: prompt) == expected)
        }
    }

    @Test("h/l and arrow keys move the selected close choice with clamped boundaries")
    func choiceNavigation() throws {
        let prompt = makePrompt()
        let leftArrow = try #require(keyEvent(characters: "", keyCode: 123))
        let rightArrow = try #require(keyEvent(characters: "", keyCode: 124))
        let h = try #require(keyEvent(characters: "h"))
        let l = try #require(keyEvent(characters: "l"))

        #expect(prompt.selectedChoiceForTesting == .saveAndClose)
        #expect(prompt.handleKeyDown(leftArrow))
        #expect(prompt.selectedChoiceForTesting == .discardAndClose)
        #expect(prompt.handleKeyDown(h))
        #expect(prompt.selectedChoiceForTesting == .continueEditing)
        #expect(prompt.handleKeyDown(h))
        #expect(prompt.selectedChoiceForTesting == .continueEditing)
        #expect(prompt.handleKeyDown(rightArrow))
        #expect(prompt.selectedChoiceForTesting == .discardAndClose)
        #expect(prompt.handleKeyDown(l))
        #expect(prompt.selectedChoiceForTesting == .saveAndClose)
        #expect(prompt.handleKeyDown(l))
        #expect(prompt.selectedChoiceForTesting == .saveAndClose)
        #expect(resolvedChoice(in: prompt) == nil)
    }

    @Test("held repeats are consumed without changing or resolving the prompt")
    func repeatedKeys() throws {
        let prompt = makePrompt()
        let repeatLeft = try #require(keyEvent(characters: "", keyCode: 123, isRepeat: true))
        let repeatEscape = try #require(keyEvent(characters: "", keyCode: 53, isRepeat: true))
        let repeatSave = try #require(keyEvent(characters: "y", isRepeat: true))

        #expect(prompt.handleKeyDown(repeatLeft))
        #expect(prompt.handleKeyDown(repeatEscape))
        #expect(prompt.handleKeyDown(repeatSave))
        #expect(prompt.selectedChoiceForTesting == .saveAndClose)
        #expect(resolvedChoice(in: prompt) == nil)
    }

    @Test("close prompt hints format key tokens separately from word descriptions")
    func hintFormatting() throws {
        let prompt = makePrompt()
        let hint = try #require(descendant(in: prompt, identifier: "settings.closeConfirmation.hint") as? NSTextField)
        let attributed = hint.attributedStringValue
        #expect(attributed.string == "h / l  Select    ↩  Choose    Esc  Continue    n  Discard    y  Save")

        let keyRange = (attributed.string as NSString).range(of: "h / l")
        let wordRange = (attributed.string as NSString).range(of: "Select")
        let keyFont = attributed.attribute(.font, at: keyRange.location, effectiveRange: nil) as? NSFont
        let wordFont = attributed.attribute(.font, at: wordRange.location, effectiveRange: nil) as? NSFont
        let keyColor = attributed.attribute(.foregroundColor, at: keyRange.location, effectiveRange: nil) as? NSColor
        let wordColor = attributed.attribute(.foregroundColor, at: wordRange.location, effectiveRange: nil) as? NSColor
        let theme = AppKitTheme(themeID: .tokyoNight)
        #expect(keyFont?.familyName == NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold).familyName)
        #expect(wordFont?.familyName != keyFont?.familyName)
        #expect(keyColor?.usingColorSpace(.sRGB)?.redComponent == theme[.accent].usingColorSpace(.sRGB)?.redComponent)
        #expect(wordColor?.usingColorSpace(.sRGB)?.redComponent == theme[.mutedText].usingColorSpace(.sRGB)?.redComponent)
    }

    private func makePrompt() -> SettingsCloseConfirmationView {
        SettingsCloseConfirmationView(frame: NSRect(x: 0, y: 0, width: 440, height: 140))
    }

    private func keyEvent(
        characters: String,
        keyCode: UInt16 = 0,
        isRepeat: Bool = false
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isRepeat,
            keyCode: keyCode
        )
    }

    private func resolvedChoice(in prompt: SettingsCloseConfirmationView) -> SettingsCloseConfirmationView.Choice? {
        guard let value = Mirror(reflecting: prompt).children
            .first(where: { $0.label?.contains("result") == true })?.value
        else { return nil }
        if let choice = value as? SettingsCloseConfirmationView.Choice { return choice }
        return Mirror(reflecting: value).children.first?.value as? SettingsCloseConfirmationView.Choice
    }

    private func descendant(in view: NSView, identifier: String) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        for child in view.subviews {
            if let match = descendant(in: child, identifier: identifier) { return match }
        }
        return nil
    }
}
