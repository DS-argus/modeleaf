import PDFReaderCore
import Testing

@Suite("Shortcut settings draft")
struct ShortcutSettingsDraftTests {
    @Test("Editing aliases keeps immutable arrows and discard restores source")
    func aliasesAndDiscard() throws {
        let source = SparseAppConfig(keymap: ["scroll.down": ["j", "<Down>"]])
        var draft = ShortcutSettingsDraft(source: source)
        #expect(draft.aliases(for: .scrollDown) == ["j"])
        draft.setAliases([], for: .scrollDown)
        #expect(draft.isDirty)
        let config = try #require(draft.validation.validatedConfig)
        #expect(config.keymap.bindings(for: .scrollDown) == [try KeySequenceParser.parse("<Down>")])
        draft.discard()
        #expect(!draft.isDirty)
        #expect(draft.overrides == source.keymap)
    }

    @Test("Reset deletes only the selected override and preserves unrelated settings")
    func resetScope() {
        let source = SparseAppConfig(
            keymap: ["scroll.down": [], "scroll.up": []],
            navigation: SparseNavigationConfiguration(zoomFactor: 1.25),
            input: SparseInputConfiguration(prefixTimeoutMilliseconds: 650, prefix: "<C-x>"),
            links: SparseLinksConfiguration(skipExternalLinkHintConfirmation: true)
        )
        var draft = ShortcutSettingsDraft(source: source)
        draft.reset(.scrollDown)
        #expect(draft.overrides["scroll.down"] == nil)
        #expect(draft.overrides["scroll.up"] == [])
        #expect(draft.aliases(for: .scrollDown) == ["j"])
        #expect(draft.source.navigation == source.navigation)
        #expect(draft.source.links == source.links)
        #expect(draft.source.input == source.input)
    }

    @Test("Prefix remains a template and invalid draft can be repaired before apply")
    func prefixAndConflicts() {
        var draft = ShortcutSettingsDraft(source: SparseAppConfig())
        draft.setAliases(["j"], for: .viewFitWidth)
        #expect(!draft.validation.isValid)
        draft.setAliases([], for: .scrollDown)
        #expect(draft.validation.isValid)
        draft.setPrefix("<C-x>")
        #expect(draft.hasValidPrefix)
        #expect(draft.aliases(for: .paneSplitRight) == ["<prefix>|"])
        draft.setPrefix("bad prefix")
        #expect(!draft.hasValidPrefix)
    }

    @Test("Fixed actions cannot acquire mutable aliases")
    func fixedOnly() {
        var draft = ShortcutSettingsDraft(source: SparseAppConfig())
        draft.setAliases(["x"], for: .promptCancel)
        #expect(!draft.isDirty)
        #expect(draft.overrides.isEmpty)
    }

    @Test("Unedited out-of-recorder-form bindings retain their original spelling")
    func preserveExisting() {
        let source = SparseAppConfig(keymap: ["view.fitWidth": ["xyz", "<prefix><D-j>"]])
        var draft = ShortcutSettingsDraft(source: source)
        draft.setAliases([], for: .scrollDown)
        #expect(draft.overrides["view.fitWidth"] == source.keymap?["view.fitWidth"])
    }
}
