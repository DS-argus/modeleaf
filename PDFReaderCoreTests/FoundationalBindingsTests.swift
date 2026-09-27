import PDFReaderCore
import Testing

@Suite("Contextual binding foundations")
struct FoundationalBindingsTests {
    @Test("Foundation lookup and editable defaults separate immutable keys from aliases")
    func lookupAndEditableDefaults() throws {
        #expect(FoundationalBindings.sequences(for: .scrollDown).map(\.description) == ["<Down>"])
        #expect(FoundationalBindings.sequences(for: .searchCancel).map(\.description) == ["<Esc>"])
        #expect(BuiltInDefaults.editableTemplatedKeymap[.scrollDown] == ["j"])
        #expect(BuiltInDefaults.editableTemplatedKeymap[.searchCancel] == [])
        #expect(BuiltInDefaults.editableTemplatedKeymap[.promptCancel] == [])
        #expect(BuiltInDefaults.editableTemplatedKeymap[.paneSplitRight] == ["<prefix>|"])
        #expect(BuiltInDefaults.editableTemplatedKeymap[.promptCancel, default: []].isEmpty)
    }

    @Test("Removing a scroll alias retains the bare arrow foundation")
    func emptyAliasOverrideRetainsFoundation() throws {
        let report = ConfigValidator.validate(
            SparseAppConfig(keymap: [ActionID.scrollDown.rawValue: []])
        )
        let active = try #require(report.validatedConfig)
        let down = try sequence("<Down>")
        let j = try sequence("j")

        #expect(report.isValid)
        #expect(active.keymap.bindings(for: .scrollDown) == [down])
        #expect(active.keymap.action(forExact: down, in: .navigation) == .scrollDown)
        #expect(active.keymap.action(forExact: j, in: .navigation) == nil)
    }

    @Test("Missing overrides and policy reset restore editable aliases")
    func defaultsAndReset() throws {
        let defaults = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        let down = try sequence("<Down>")
        let j = try sequence("j")
        #expect(defaults.keymap.bindings(for: .scrollDown) == [down, j])

        let reset = defaults.keymap.replacingBindings(for: .scrollDown, with: [])
        let resetKeymap = try #require(reset.validatedKeymap)
        #expect(reset.isValid)
        #expect(resetKeymap.bindings(for: .scrollDown) == [down])

        let restored = defaults.keymap.replacingBindings(for: .scrollDown, with: [j])
        #expect(restored.validatedKeymap?.bindings(for: .scrollDown) == [down, j])
    }

    @Test("An own source foundation is effective exactly once")
    func ownFoundationOnce() throws {
        let report = ConfigValidator.validate(
            SparseAppConfig(keymap: [ActionID.scrollDown.rawValue: ["<Down>"]])
        )
        let active = try #require(report.validatedConfig)
        #expect(report.isValid)
        #expect(active.keymap.bindings(for: .scrollDown) == [try sequence("<Down>")])

        let duplicate = ConfigValidator.validate(
            SparseAppConfig(keymap: [ActionID.scrollDown.rawValue: ["<Down>", "<Down>"]])
        )
        #expect(!duplicate.isValid)
        #expect(duplicate.diagnostics.contains { $0.code == .duplicateBinding })
    }

    @Test("Duplicate aliases remain errors")
    func duplicateAliases() {
        let report = ConfigValidator.validate(
            SparseAppConfig(keymap: [ActionID.scrollDown.rawValue: ["j", "j"]])
        )
        #expect(!report.isValid)
        #expect(report.diagnostics.contains { $0.code == .duplicateBinding })
    }

    @Test("Reassigning an arrow in overlapping reader contexts is rejected")
    func overlappingFoundationConflict() {
        let report = ConfigValidator.validate(
            SparseAppConfig(keymap: [ActionID.pageNext.rawValue: ["<Down>"]])
        )
        let conflict = report.diagnostics.first { $0.code == .conflictingBinding }
        #expect(!report.isValid)
        #expect(conflict?.actions == [ActionID.scrollDown.rawValue, ActionID.pageNext.rawValue])
        #expect(conflict?.contexts == [.navigation, .searchResults])
    }

    @Test("Search Escape is scoped to search results rather than globally reserved")
    func searchEscapeContexts() throws {
        let empty = ConfigValidator.validate(
            SparseAppConfig(keymap: [ActionID.searchCancel.rawValue: []])
        )
        let active = try #require(empty.validatedConfig)
        let escape = try sequence("<Esc>")

        #expect(empty.isValid)
        #expect(active.keymap.bindings(for: .searchCancel) == [escape])
        #expect(active.keymap.action(forExact: escape, in: .searchResults) == .searchCancel)
        #expect(active.keymap.action(forExact: escape, in: .navigation) == nil)

        let ownSource = ConfigValidator.validate(
            SparseAppConfig(keymap: [ActionID.searchCancel.rawValue: ["<Esc>"]])
        )
        #expect(ownSource.isValid)
        #expect(ownSource.validatedConfig?.keymap.bindings(for: .searchCancel) == [escape])
        let alias = ConfigValidator.validate(
            SparseAppConfig(keymap: [ActionID.searchCancel.rawValue: ["x"]])
        )
        #expect(alias.isValid)
        #expect(alias.validatedConfig?.keymap.bindings(for: .searchCancel) == [escape, try sequence("x")])
    }

    @Test("Foundation conflicts use only overlapping contexts")
    func foundationConflictContextIntersection() throws {
        let registry = ActionRegistry(descriptors: [
            ActionDescriptor(id: .scrollDown, title: "Scroll Down", scope: .contexts([.navigation, .searchResults])),
            ActionDescriptor(id: .searchCancel, title: "Clear Search", scope: .contexts([.searchResults])),
        ])
        let bindings: [ActionID: [KeySequence]] = [
            .scrollDown: [try sequence("<Down>")],
            .searchCancel: [try sequence("<Esc>")],
        ]
        let report = ActionBindingPolicy.evaluateEffective(bindings, registry: registry)
        #expect(report.isValid)
        #expect(report.diagnostics.isEmpty)
    }

    private func sequence(_ source: String) throws -> KeySequence {
        try KeySequenceParser.parse(source)
    }
    @Test("Editable defaults contain aliases while effective hints retain foundations")
    func generatedDefaultsSeparateAliasesAndFoundations() {
        #expect(BuiltInDefaults.editableTemplatedKeymap[.scrollDown] == ["j"])
        #expect(BuiltInDefaults.editableTemplatedKeymap[.searchCancel] == [])
        #expect(BuiltInDefaults.keymap[.scrollDown]?.first?.description == "<Down>")
        #expect(BuiltInDefaults.keymap[.searchCancel]?.first?.description == "<Esc>")
    }

}
