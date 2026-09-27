import PDFReaderCore
import Testing

@Suite("Shared help and shortcut catalog")
struct ActionHelpCatalogTests {
    @Test("Settings actions belong to help and fixed-only actions stay hidden")
    func membership() {
        let help = ActionHelpCatalog.sections.flatMap(\.actions)
        #expect(Set(help).count == help.count)
        let editable = help.filter(ActionHelpCatalog.isEditableInSettings)
        #expect(editable.contains(.scrollDown))
        #expect(editable.contains(.paletteOpen))
        #expect(editable.contains(.viewZoomReset))
        #expect(!editable.contains(.searchCancel))
        #expect(!editable.contains(.searchNext))
        #expect(!editable.contains(.promptCommit))
        #expect(editable.contains(.settingsOpen))
        #expect(Set(ActionHelpCatalog.sections.map(\.title)).count == ActionHelpCatalog.sections.count)
        #expect(help.allSatisfy { !$0.rawValue.hasPrefix("config.") })
    }

    @Test("Unassigned actions retain catalog identity and category order")
    func unassigned() throws {
        let before = ActionHelpCatalog.sections.flatMap(\.actions)
        let config = try #require(ConfigValidator.validate(SparseAppConfig(keymap: ["help.show": []])).validatedConfig)
        #expect(config.keymap.bindings(for: .helpShow).isEmpty)
        #expect(ActionHelpCatalog.sections.flatMap(\.actions) == before)
        #expect(before.contains(.helpShow))
    }

    @Test("Palette command chord survives removal of the editable colon")
    func paletteFoundation() throws {
        #expect(BuiltInDefaults.editableTemplatedKeymap[.paletteOpen] == [":"])
        let config = try #require(ConfigValidator.validate(SparseAppConfig(keymap: ["palette.open": []])).validatedConfig)
        #expect(config.keymap.bindings(for: .paletteOpen).map(\.description) == ["<D-S-p>"])
        #expect(!ConfigValidator.validate(SparseAppConfig(keymap: ["view.zoomReset": ["<D-S-p>"]])).isValid)
    }

    @Test("Common prefix cannot be bound by itself even after followers are removed")
    func prefixReservation() {
        let source = SparseAppConfig(keymap: [
            "pane.splitRight": [], "pane.splitDown": [], "pane.unsplit": [],
            "view.zoomReset": ["<C-b>"],
        ])
        let report = ConfigValidator.validate(source)
        #expect(!report.isValid)
        #expect(report.diagnostics.contains { $0.code == .invalidExactPrefix && $0.actions.contains("view.zoomReset") })
    }
}
