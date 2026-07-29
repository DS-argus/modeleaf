import PDFReaderCore
import Testing

@Suite("Action registry and binding policy")
struct ActionRegistryTests {
    @Test("U-ACT-01 exact stable action set")
    func exactStableActionSet() {
        let expected: Set<String> = [
            "document.open", "document.close", "app.quit", "app.new", "palette.open", "help.show",
            "tab.next", "tab.previous",
            "tab.select.1", "tab.select.2", "tab.select.3",
            "tab.select.4", "tab.select.5", "tab.select.6",
            "tab.select.7", "tab.select.8", "tab.select.9",
            "scroll.left", "scroll.down", "scroll.up", "scroll.right", "scroll.largeDown", "scroll.largeUp",
            "page.next", "page.previous", "page.first", "page.last", "page.prompt",
            "prompt.commit", "prompt.cancel",
            "search.prompt", "search.next", "search.previous", "search.cancel",
            "view.zoomIn", "view.zoomOut", "view.zoomReset", "view.fitWidth", "view.fitPage", "link.hint",
            "pane.splitRight", "pane.splitDown", "pane.focusLeft", "pane.focusDown", "pane.focusUp", "pane.focusRight", "pane.unsplit",
            "theme.picker",
            "config.reload", "config.writeDefault", "config.resetDefault",
        ]
        let registry = ActionRegistry.v1
        #expect(registry.descriptors.count == 51)
        #expect(Set(registry.actionIDs).count == registry.actionIDs.count)
        #expect(Set(registry.actionIDs.map(\.rawValue)) == expected)
        #expect(Set(InputContext.allCases) == [.navigation, .pagePrompt, .searchPrompt, .searchResults])
    }

    @Test("U-ACT-02 every action binds, dispatches, and unbinds")
    func everyActionBindsDispatchesAndUnbinds() throws {
        let registry = ActionRegistry.v1
        let report = ActionBindingPolicy.evaluateEffective(BuiltInDefaults.keymap, registry: registry)
        #expect(report.diagnostics.isEmpty)
        let keymap = try #require(report.validatedKeymap)

        #expect(
            Set(registry.actionIDs.filter { !keymap.isBound($0) })
                == [.viewZoomReset, .configWriteDefault, .configResetDefault]
        )

        for descriptor in registry.descriptors where keymap.isBound(descriptor.id) {
            let sequence = try #require(keymap.bindings(for: descriptor.id).first)
            let context = try #require(InputContext.allCases.first(where: descriptor.isActive))
            let dispatcher = RecordingDispatcher()
            #expect(keymap.dispatchExact(sequence, in: context, using: dispatcher))
            #expect(dispatcher.actions == [descriptor.id])

            let unboundReport = keymap.replacingBindings(for: descriptor.id, with: [], registry: registry)
            #expect(unboundReport.diagnostics.isEmpty)
            let unbound = try #require(unboundReport.validatedKeymap)
            #expect(!unbound.isBound(descriptor.id))
            #expect(unbound.action(forExact: sequence, in: context) != descriptor.id)

            let menuBefore = MenuEquivalentPolicy.makeDescriptors(
                evaluatedBindings: report.evaluatedBindings,
                registry: registry
            ).first { $0.actionID == descriptor.id }
            let menuAfter = MenuEquivalentPolicy.makeDescriptors(
                evaluatedBindings: unboundReport.evaluatedBindings,
                registry: registry
            ).first { $0.actionID == descriptor.id }
            if descriptor.scope == .global, menuBefore != nil {
                #expect(menuBefore?.keyEquivalent != nil)
                #expect(menuAfter?.keyEquivalent == nil)
            }
        }

        let actualSize = try sequence("0")
        let reboundReport = keymap.replacingBindings(for: .viewZoomReset, with: [actualSize], registry: registry)
        let rebound = try #require(reboundReport.validatedKeymap)
        let dispatcher = RecordingDispatcher()
        #expect(rebound.dispatchExact(actualSize, in: .navigation, using: dispatcher))
        #expect(dispatcher.actions == [.viewZoomReset])
    }

    @Test("U-ACT-02 every declared UI surface is registry-backed")
    func everySurfaceIsRegistryBacked() {
        #expect(ActionSurfaceRegistry.validate().isEmpty)
        let keySurfaceActions = Set(
            ActionSurfaceRegistry.v1
                .filter { $0.kind == .keyBinding }
                .map(\.actionID)
        )
        #expect(keySurfaceActions == Set(ActionRegistry.v1.actionIDs))
        #expect(MenuItemRegistry.v1.allSatisfy { item in
            ActionSurfaceRegistry.v1.contains {
                $0.kind == .menuItem && $0.actionID == item.actionID
            }
        })
        let tabControlActions = Set(
            ActionSurfaceRegistry.v1
                .filter { $0.kind == .tabControl }
                .map(\.actionID)
        )
        #expect(tabControlActions == [.tabNext, .tabPrevious, .documentClose])
    }

    @Test("U-ACT-03 pure menu equivalents derive from evaluated bindings")
    func menuEquivalentPolicy() throws {
        let defaults = ActionBindingPolicy.evaluateEffective(BuiltInDefaults.keymap)
        let descriptors = MenuEquivalentPolicy.makeDescriptors(evaluatedBindings: defaults.evaluatedBindings)
        #expect(descriptors.first { $0.actionID == .documentOpen }?.keyEquivalent?.description == "<D-o>")
        #expect(descriptors.first { $0.actionID == .appQuit }?.keyEquivalent?.description == "<D-q>")
        #expect(descriptors.filter { ![.documentOpen, .appQuit, .appNew].contains($0.actionID) }.allSatisfy { $0.keyEquivalent == nil })

        var reordered = BuiltInDefaults.keymap
        reordered[.documentOpen] = [try sequence("<D-F12>"), try sequence("<D-o>")]
        let reorderedReport = ActionBindingPolicy.evaluateEffective(reordered)
        #expect(reorderedReport.isValid)
        let reorderedMenus = MenuEquivalentPolicy.makeDescriptors(evaluatedBindings: reorderedReport.evaluatedBindings)
        #expect(reorderedMenus.first { $0.actionID == .documentOpen }?.keyEquivalent?.description == "<D-F12>")

        var ambiguous = BuiltInDefaults.keymap
        ambiguous[.pageNext] = [try sequence("<D-o>")]
        let ambiguousReport = ActionBindingPolicy.evaluateEffective(ambiguous)
        #expect(!ambiguousReport.isValid)
        let ambiguousMenus = MenuEquivalentPolicy.makeDescriptors(evaluatedBindings: ambiguousReport.evaluatedBindings)
        #expect(ambiguousMenus.first { $0.actionID == .documentOpen }?.keyEquivalent == nil)

        var unsafe = BuiltInDefaults.keymap
        unsafe[.documentOpen] = [try sequence("go")]
        let unsafeReport = ActionBindingPolicy.evaluateEffective(unsafe)
        #expect(!unsafeReport.isValid)
        #expect(MenuEquivalentPolicy.makeDescriptors(evaluatedBindings: unsafeReport.evaluatedBindings)
            .first { $0.actionID == .documentOpen }?.keyEquivalent == nil)

        var unbound = BuiltInDefaults.keymap
        unbound[.documentOpen] = []
        let unboundReport = ActionBindingPolicy.evaluateEffective(unbound)
        #expect(unboundReport.isValid)
        #expect(MenuEquivalentPolicy.makeDescriptors(evaluatedBindings: unboundReport.evaluatedBindings)
            .first { $0.actionID == .documentOpen }?.keyEquivalent == nil)
    }

    @Test("U-ACT-04 repeat policy blocks lifecycle actions")
    func repeatPolicy() {
        let allowed: Set<ActionID> = [
            .scrollLeft, .scrollDown, .scrollUp, .scrollRight, .scrollLargeDown, .scrollLargeUp,
            .pageNext, .pagePrevious, .searchNext, .searchPrevious, .viewZoomIn, .viewZoomOut,
        ]
        for descriptor in ActionRegistry.v1.descriptors {
            #expect(ActionBindingPolicy.shouldDispatch(eventIsRepeat: false, action: descriptor))
            #expect(
                ActionBindingPolicy.shouldDispatch(eventIsRepeat: true, action: descriptor)
                    == allowed.contains(descriptor.id)
            )
        }
        let neverRepeat: Set<ActionID> = [
            .documentOpen, .documentClose, .appQuit, .promptCommit, .promptCancel, .searchCancel,
        ]
        #expect(ActionRegistry.v1.descriptors.filter { neverRepeat.contains($0.id) }.allSatisfy {
            $0.repeatPolicy == .suppressed
        })
    }

    @Test("U-ACT-05 context and global classification is exact")
    func contextEligibility() throws {
        let registry = ActionRegistry.v1
        let globals = Set(registry.descriptors.filter { $0.scope == .global }.map(\.id))
        #expect(globals == [.documentOpen, .appQuit, .appNew, .configWriteDefault, .configResetDefault])

        let commit = try #require(registry.descriptor(for: .promptCommit))
        let cancel = try #require(registry.descriptor(for: .promptCancel))
        #expect(commit.activeContexts == [.pagePrompt, .searchPrompt])
        #expect(cancel.activeContexts == [.pagePrompt, .searchPrompt])
        #expect(commit.isPromptLifecycle && cancel.isPromptLifecycle)

        let searchNext = try #require(registry.descriptor(for: .searchNext))
        let searchPrevious = try #require(registry.descriptor(for: .searchPrevious))
        let searchCancel = try #require(registry.descriptor(for: .searchCancel))
        #expect(searchNext.activeContexts == [.searchResults])
        #expect(searchPrevious.activeContexts == [.searchResults])
        #expect(searchCancel.activeContexts == [.searchResults])

        let pagePrompt = try #require(registry.descriptor(for: .pagePrompt))

        let linkHint = try #require(registry.descriptor(for: .linkHint))
        #expect(linkHint.activeContexts == [.navigation])
        #expect(!linkHint.isFixedBinding)
        #expect(pagePrompt.prefixFallbackPolicy == .transitionAndReplay(to: .pagePrompt, acceptedToken: .decimalDigit))
    }

    private func sequence(_ source: String) throws -> KeySequence {
        try KeySequenceParser.parse(source)
    }
}

private final class RecordingDispatcher: ActionDispatching {
    private(set) var actions: [ActionID] = []

    func dispatch(_ action: ActionID) {
        actions.append(action)
    }
}
