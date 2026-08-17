import Foundation
import PDFReaderCore
import Testing

@Suite("Canonical defaults, themes, and documentation")
struct BuiltInDefaultsTests {
    @Test("Built-in keymap is complete and accepted by pure policies")
    func defaultKeymapIsCompleteAndValid() {
        #expect(Set(BuiltInDefaults.keymap.keys) == Set(ActionRegistry.v1.actionIDs))
        #expect(
            Set(BuiltInDefaults.keymap.compactMap { action, bindings in
                bindings.isEmpty ? action : nil
            }) == [.viewZoomReset, .configWriteDefault, .configResetDefault]
        )
        let report = ActionBindingPolicy.evaluateEffective(BuiltInDefaults.keymap)
        #expect(report.isValid)
        #expect(report.diagnostics.isEmpty)
    }

    @Test("Exact default vocabulary remains compact and viewer-first")
    func exactDefaultVocabulary() throws {
        let expected: [ActionID: [String]] = [
            .documentOpen: ["<D-o>"], .documentClose: ["<D-w>"], .documentPrint: ["<D-p>"], .documentCopyPath: ["yy"], .documentRevealInFinder: ["of"], .appQuit: ["<D-q>"], .appNew: ["<D-n>"], .paletteOpen: [":", "<D-S-p>"], .helpShow: ["?"],
            .tabNext: ["N"], .tabPrevious: ["P"],
            .tabSelect1: ["<D-1>"], .tabSelect2: ["<D-2>"], .tabSelect3: ["<D-3>"],
            .tabSelect4: ["<D-4>"], .tabSelect5: ["<D-5>"], .tabSelect6: ["<D-6>"],
            .tabSelect7: ["<D-7>"], .tabSelect8: ["<D-8>"], .tabSelect9: ["<D-9>"],
            .scrollLeft: ["h", "<Left>"], .scrollDown: ["j", "<Down>"], .scrollUp: ["k", "<Up>"], .scrollRight: ["l", "<Right>"],
            .scrollLargeDown: ["d"], .scrollLargeUp: ["u"],
            .tocToggle: ["t"], .tocScrollDown: ["J"], .tocScrollUp: ["K"],
            .pageNext: ["n"], .pagePrevious: ["p"], .pageFirst: ["gg"], .pageLast: ["G"], .pagePrompt: ["g"],
            .historyBack: ["<C-o>"], .historyForward: ["<C-i>"],
            .promptCommit: ["<Enter>"], .promptCancel: ["<Esc>"],
            .searchPrompt: ["/"], .searchNext: ["<Enter>"], .searchPrevious: ["<S-Enter>"], .searchCancel: ["<Esc>"],
            .viewZoomIn: ["="], .viewZoomOut: ["-"], .viewZoomReset: [],
            .viewFitWidth: ["w"], .viewFitPage: ["F"], .viewRotateLeft: ["["], .viewRotateRight: ["]"], .linkHint: ["f"],
            .themePicker: ["T"], .indicatorPicker: ["I"], .updateShow: ["U"],
            .configReload: ["<C-b>r"], .configWriteDefault: [], .configResetDefault: [],
            .paneSplitRight: ["<C-b>|"], .paneSplitDown: ["<C-b>-"], .paneUnsplit: ["<C-b>o"],
            .paneFocusLeft: ["<C-h>"], .paneFocusDown: ["<C-j>"], .paneFocusUp: ["<C-k>"], .paneFocusRight: ["<C-l>"],
        ]
        let actual = BuiltInDefaults.keymap.mapValues { $0.map(\.description) }
        #expect(actual == expected)
        #expect(try KeySequenceParser.parse("g12").tokens.map(\.description) == ["g", "1", "2"])

        let excludedTerms = [
            "bookmark", "annotation", "mark", "highlight", "portal", "smart", "command", "script", "plugin", "ocr", "export",
        ]
        #expect(ActionRegistry.v1.actionIDs.allSatisfy { action in
            excludedTerms.allSatisfy { !action.rawValue.lowercased().contains($0) }
        })
    }

    @Test("History commands have navigation-only registry defaults")
    func historyCommandDefaults() {
        let back = ActionRegistry.v1.descriptor(for: .historyBack)
        let forward = ActionRegistry.v1.descriptor(for: .historyForward)

        #expect(ActionID.historyBack.rawValue == "history.back")
        #expect(ActionID.historyForward.rawValue == "history.forward")
        #expect(back?.title == "Back")
        #expect(forward?.title == "Forward")
        #expect(BuiltInDefaults.keymap[.historyBack]?.map(\.description) == ["<C-o>"])
        #expect(BuiltInDefaults.keymap[.historyForward]?.map(\.description) == ["<C-i>"])
        #expect(back?.scope == .contexts([.navigation]))
        #expect(forward?.scope == .contexts([.navigation]))
        #expect(back?.repeatPolicy == .suppressed)
        #expect(forward?.repeatPolicy == .suppressed)
        #expect(back?.isFixedBinding == false)
        #expect(forward?.isFixedBinding == false)
        #expect(BuiltInDefaults.categoryTitle(for: .historyBack) == "Navigation")
        #expect(BuiltInDefaults.categoryTitle(for: .historyForward) == "Navigation")
    }

    @Test("key hints preserve literal character case unless Shift is explicit")
    func keyHintCaseContract() throws {
        #expect(KeyBindingHint.text(for: try KeySequenceParser.parse("<D-o>")) == "Cmd+o")
        #expect(KeyBindingHint.text(for: try KeySequenceParser.parse("<C-b>")) == "Ctrl+b")
        #expect(KeyBindingHint.text(for: try KeySequenceParser.parse("<D-S-p>")) == "Cmd+Shift+P")
        #expect(KeyBindingHint.text(for: try KeySequenceParser.parse("F")) == "F")
    }

    @Test("Built-in numeric values and bounds are exact")
    func numericDefaultsAndBounds() {
        let config = BuiltInDefaults.config
        #expect(config.navigation.smallScrollPoints == 32.0)
        #expect(config.navigation.largeScrollViewportFraction == 0.8)
        #expect(config.navigation.zoomFactor == 1.10)
        #expect(config.input.prefixTimeoutMilliseconds == 400)
        #expect(ConfigBounds.smallScrollPoints == 1.0...512.0)
        #expect(ConfigBounds.largeScrollViewportFraction == 0.1...2.0)
        #expect(ConfigBounds.zoomFactor == 1.01...2.0)
        #expect(ConfigBounds.prefixTimeoutMilliseconds == 100...2_000)
    }

    @Test("Seven built-in themes are complete and PDF-agnostic")
    func builtInThemesAreComplete() {
        #expect(ThemeID.allCases.count == 7)
        #expect(BuiltInThemes.all.count == 7)
        #expect(BuiltInThemes.all.map(\.id) == ThemeID.allCases)
        for theme in BuiltInThemes.all {
            #expect(Set(theme.palette.values.keys) == Set(ThemeToken.allCases))
            #expect(theme.palette.values.values.allSatisfy { ThemeColor(rawValue: $0.rawValue) != nil })
        }

        let nord = BuiltInThemes.theme(for: .nord)
        #expect(nord.palette[.background].rawValue == "#2E3440")
        #expect(nord.palette[.accent].rawValue == "#88C0D0")
        let latte = BuiltInThemes.theme(for: .catppuccinLatte)
        #expect(latte.palette[.background].rawValue == "#EFF1F5")
        #expect(latte.palette[.background] != BuiltInThemes.theme(for: .tokyoNight).palette[.background])
        #expect(ThemeToken.allCases.allSatisfy { !$0.rawValue.lowercased().contains("pdf") })
    }

    @Test("Bundled DefaultConfig.toml is generated from BuiltInDefaults")
    func defaultConfigSnapshot() throws {
        let root = repositoryRoot()
        let bundled = try String(
            contentsOf: root.appendingPathComponent("PDFReaderApp/Resources/DefaultConfig.toml"),
            encoding: .utf8
        )
        #expect(bundled == BuiltInDefaults.defaultConfigTOML)
        #expect(bundled.contains("page.prompt") && bundled.contains("[\"g\"]"))
        #expect(bundled.contains("prefix = \"<C-b>\""))
        #expect(bundled.contains("<prefix>|"))
        #expect(!bundled.contains("prompt.commit"))
        #expect(!bundled.contains("[theme]"))
        #expect(!bundled.localizedCaseInsensitiveContains("script"))
    }

    @Test("CONFIG.md generated blocks and grammar remain synchronized")
    func configDocumentationSnapshot() throws {
        let root = repositoryRoot()
        let checkedIn = try String(contentsOf: root.appendingPathComponent("CONFIG.md"), encoding: .utf8)
        #expect(checkedIn == ConfigDocumentation.markdown)
        #expect(checkedIn.contains("<!-- BEGIN GENERATED: PROMPT_NATIVE_RESERVATION_V1 -->"))
        #expect(checkedIn.contains("<!-- BEGIN GENERATED: SYSTEM_KEY_RESERVATION_V1 -->"))
        #expect(checkedIn.contains("Configuration is declarative data only"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
