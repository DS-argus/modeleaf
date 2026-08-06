import AppKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("Config-derived native menus")
@MainActor
struct ValidatedMenuBuilderTests {
    @Test("only globally eligible config bindings become AppKit menu equivalents")
    func menuEquivalentsComeFromValidatedConfig() throws {
        let validated = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        var actions: [ActionID] = []
        let builder = ValidatedMenuBuilder(descriptors: validated.menuDescriptors) { actions.append($0) }
        let menu = builder.makeMainMenu()

        let open = try #require(menu.descendant(title: "Open PDF…"))
        #expect(open.keyEquivalent == "o")
        #expect(open.keyEquivalentModifierMask == NSEvent.ModifierFlags.command)

        let quit = try #require(menu.descendant(title: "Quit Modeleaf"))
        #expect(quit.keyEquivalent == "q")
        #expect(quit.keyEquivalentModifierMask == NSEvent.ModifierFlags.command)

        let printItem = try #require(menu.descendant(title: "Print…"))
        #expect(printItem.keyEquivalent == "p")
        #expect(printItem.keyEquivalentModifierMask == NSEvent.ModifierFlags.command)
        let close = try #require(menu.descendant(title: "Close PDF"))
        #expect(close.keyEquivalent.isEmpty)
        #expect(close.keyEquivalentModifierMask.isEmpty)
    }

    @Test("clickable menu items dispatch the same stable ActionID path")
    func menuItemDispatchesStableActionID() throws {
        let validated = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        var actions: [ActionID] = []
        let builder = ValidatedMenuBuilder(descriptors: validated.menuDescriptors) { actions.append($0) }
        let menu = builder.makeMainMenu()
        let item = try #require(menu.descendant(title: "Fit Width"))
        let action = try #require(item.action)

        _ = item.target?.perform(action, with: item)
        #expect(actions == [.viewFitWidth])
    }

    @Test("a prompt-safe remap changes the displayed equivalent without a fixed shortcut")
    func safeRemapChangesEquivalent() throws {
        let report = ConfigValidator.validate(
            SparseAppConfig(keymap: [ActionID.documentOpen.rawValue: ["<D-F12>"]])
        )
        let validated = try #require(report.validatedConfig)
        var actions: [ActionID] = []
        let builder = ValidatedMenuBuilder(descriptors: validated.menuDescriptors) { actions.append($0) }
        let menu = builder.makeMainMenu()
        let open = try #require(menu.descendant(title: "Open PDF…"))

        #expect(open.keyEquivalent == UnicodeScalar(NSF12FunctionKey).map(String.init))
        #expect(open.keyEquivalentModifierMask == NSEvent.ModifierFlags.command)
    }

    @Test("print menu uses configured Cmd+p and disables without an active document")
    func printAvailability() throws {
        let validated = try #require(ConfigValidator.validate(SparseAppConfig()).validatedConfig)
        var dispatched: [ActionID] = []
        let builder = ValidatedMenuBuilder(
            descriptors: validated.menuDescriptors,
            dispatch: { dispatched.append($0) },
            isEnabled: { $0 != .documentPrint }
        )
        let printItem = try #require(builder.makeMainMenu().descendant(title: "Print…"))
        let validator = try #require(printItem.target as? NSMenuItemValidation)

        #expect(printItem.keyEquivalent == "p")
        #expect(printItem.keyEquivalentModifierMask == .command)
        #expect(!validator.validateMenuItem(printItem))
        let action = try #require(printItem.action)
        _ = printItem.target?.perform(action, with: printItem)
        #expect(dispatched.isEmpty)
    }
}

private extension NSMenu {
    func descendant(title: String) -> NSMenuItem? {
        for item in items {
            if item.title == title { return item }
            if let nested = item.submenu?.descendant(title: title) { return nested }
        }
        return nil
    }
}
