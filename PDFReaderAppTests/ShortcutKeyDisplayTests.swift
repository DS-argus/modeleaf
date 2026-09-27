import AppKit
import Testing
import PDFReaderCore
@testable import PDFReaderApp

@Suite("Shortcut key display")
@MainActor
struct ShortcutKeyDisplayTests {
    private func withLayout(
        _ provider: @escaping (UInt16, NSEvent.ModifierFlags) -> String?,
        _ body: () throws -> Void
    ) rethrows {
        let original = ShortcutKeyDisplay.layoutCharactersProvider
        ShortcutKeyDisplay.layoutCharactersProvider = provider
        defer { ShortcutKeyDisplay.layoutCharactersProvider = original }
        try body()
    }

    @Test("logical shortcuts use symbolic modifiers, lowercase letters, arrows, and prefix notation")
    func ordinaryDisplay() {
        #expect(ShortcutKeyDisplay.text(for: "U") == "U")
        #expect(ShortcutKeyDisplay.text(for: "jk") == "j → k")
        #expect(ShortcutKeyDisplay.text(for: "<D-S-p>") == "⌘⇧p")
        #expect(ShortcutKeyDisplay.text(for: "<A-C-n>") == "⌃⌥n")
        #expect(ShortcutKeyDisplay.text(for: "<prefix>r") == "<pre> → r")
        #expect(ShortcutKeyDisplay.text(for: "<C-!>") == "⌃!")
    }

    @Test("primary display retains produced punctuation under the active layout")
    func punctuation() throws {
        let layout: (UInt16, NSEvent.ModifierFlags) -> String? = { keyCode, modifiers in
            switch keyCode {
            case 18: return modifiers.contains(.shift) ? "!" : "1"
            case 24: return modifiers.contains(.shift) ? "+" : "="
            case 42: return modifiers.contains(.shift) ? "|" : "\\"
            default: return nil
            }
        }
        withLayout(layout) {
            #expect(ShortcutKeyDisplay.text(for: "|") == "|")
            #expect(ShortcutKeyDisplay.text(for: "!") == "!")
            #expect(ShortcutKeyDisplay.text(for: "+") == "+")
        }
    }

    @Test("unshifted and unknown punctuation remains literal under alternate layouts")
    func alternateLayout() throws {
        let alternateLayout: (UInt16, NSEvent.ModifierFlags) -> String? = { keyCode, modifiers in
            switch keyCode {
            case 42: return modifiers.contains(.shift) ? "¦" : "|"
            default: return nil
            }
        }
        withLayout(alternateLayout) {
            #expect(ShortcutKeyDisplay.text(for: "|") == "|")
            #expect(ShortcutKeyDisplay.text(for: "?") == "?")
        }
    }

    @Test("resolved sequences mark the configured prefix and explain layout-produced shifts")
    func resolvedSequenceAndInputDescription() throws {
        let sequence = try KeySequenceParser.parse("<C-b>r")
        #expect(ShortcutKeyDisplay.text(for: sequence, prefix: "<C-b>") == "<pre> → r")
        #expect(ShortcutKeyDisplay.text(for: sequence, prefix: "<C-x>") == "⌃b → r")
        let layout: (UInt16, NSEvent.ModifierFlags) -> String? = { keyCode, modifiers in
            switch keyCode {
            case 18: return modifiers.contains(.shift) ? "!" : "1"
            case 30: return modifiers.contains(.shift) ? "U" : "u"
            case 42: return modifiers.contains(.shift) ? "|" : "\\"
            default: return nil
            }
        }
        withLayout(layout) {
            #expect(ShortcutKeyDisplay.inputDescription(for: "U") == "⇧u")
            #expect(ShortcutKeyDisplay.inputDescription(for: "|") == "⇧backslash")
            #expect(ShortcutKeyDisplay.inputDescription(for: "<C-!>") == "⌃⇧1")
            #expect(ShortcutKeyDisplay.inputDescription(for: "?") == nil)
            #expect(ShortcutKeyDisplay.inputDescription(for: "<prefix>U") == "<pre> → ⇧u")
        }
    }

    @Test("editable aliases precede foundational bindings")
    func aliasPriority() throws {
        let validated = try #require(
            ConfigValidator.validate(SparseAppConfig(keymap: ["scroll.down": ["x"]])).validatedConfig
        )
        let bindings = ShortcutKeyDisplay.orderedBindings(for: .scrollDown, keymap: validated.keymap)
        #expect(bindings.map(\.description) == ["x", "<Down>"])
    }
}
