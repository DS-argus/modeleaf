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
            }) == [.viewZoomReset]
        )
        let report = ActionBindingPolicy.evaluateEffective(BuiltInDefaults.keymap)
        #expect(report.isValid)
        #expect(report.diagnostics.isEmpty)
    }

    @Test("Exact default vocabulary remains compact and viewer-first")
    func exactDefaultVocabulary() throws {
        let expected: [ActionID: [String]] = [
            .documentOpen: ["<D-o>"], .documentClose: ["<D-w>"], .appQuit: ["<D-q>"],
            .tabNext: ["N"], .tabPrevious: ["P"],
            .tabSelect1: ["<D-1>"], .tabSelect2: ["<D-2>"], .tabSelect3: ["<D-3>"],
            .tabSelect4: ["<D-4>"], .tabSelect5: ["<D-5>"], .tabSelect6: ["<D-6>"],
            .tabSelect7: ["<D-7>"], .tabSelect8: ["<D-8>"], .tabSelect9: ["<D-9>"],
            .scrollLeft: ["h"], .scrollDown: ["j"], .scrollUp: ["k"], .scrollRight: ["l"],
            .scrollLargeDown: ["d"], .scrollLargeUp: ["u"],
            .pageNext: ["n"], .pagePrevious: ["p"], .pageFirst: ["gg"], .pageLast: ["G"], .pagePrompt: ["g"],
            .promptCommit: ["<CR>"], .promptCancel: ["<Esc>"],
            .searchPrompt: ["/"], .searchNext: ["<CR>"], .searchPrevious: ["<S-CR>"], .searchCancel: ["<Esc>"],
            .viewZoomIn: ["="], .viewZoomOut: ["-"], .viewZoomReset: [],
            .viewFitWidth: ["w"], .viewFitPage: ["f"],
        ]
        let actual = BuiltInDefaults.keymap.mapValues { $0.map(\.description) }
        #expect(actual == expected)
        #expect(try KeySequenceParser.parse("g12").tokens.map(\.description) == ["g", "1", "2"])

        let excludedTerms = [
            "bookmark", "annotation", "mark", "highlight", "portal", "smart", "command", "script", "plugin", "ocr", "print", "export",
        ]
        #expect(ActionRegistry.v1.actionIDs.allSatisfy { action in
            excludedTerms.allSatisfy { !action.rawValue.lowercased().contains($0) }
        })
    }

    @Test("Built-in numeric values and bounds are exact")
    func numericDefaultsAndBounds() {
        let config = BuiltInDefaults.config
        #expect(config.navigation.smallScrollPoints == 48.0)
        #expect(config.navigation.largeScrollViewportFraction == 0.8)
        #expect(config.navigation.zoomFactor == 1.10)
        #expect(config.input.prefixTimeoutMilliseconds == 300)
        #expect(ConfigBounds.smallScrollPoints == 1.0...512.0)
        #expect(ConfigBounds.largeScrollViewportFraction == 0.1...2.0)
        #expect(ConfigBounds.zoomFactor == 1.01...2.0)
        #expect(ConfigBounds.prefixTimeoutMilliseconds == 100...2_000)
    }

    @Test("Four semantic dark themes are complete and PDF-agnostic")
    func builtInThemesAreComplete() {
        #expect(BuiltInThemes.all.map(\.id) == ThemeID.allCases)
        #expect(BuiltInDefaults.config.theme.builtIn == .catppuccinMocha)
        for theme in BuiltInThemes.all {
            #expect(Set(theme.palette.values.keys) == Set(ThemeToken.allCases))
            #expect(theme.palette.values.values.allSatisfy { $0.rawValue.hasPrefix("#") })
        }
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
        #expect(bundled.contains("\"page.prompt\" = [\"g\"]"))
        #expect(bundled.contains("built_in = \"catppuccin-mocha\""))
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
