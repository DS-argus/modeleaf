import AppKit
import PDFReaderCore

@MainActor
final class ValidatedMenuBuilder {
    private let descriptors: [MenuDescriptor]
    private let actionTarget: MenuActionTarget

    init(descriptors: [MenuDescriptor], dispatch: @escaping (ActionID) -> Void) {
        self.descriptors = descriptors
        self.actionTarget = MenuActionTarget(dispatch: dispatch)
    }

    func makeMainMenu(applicationName: String = "PDF Reader") -> NSMenu {
        let mainMenu = NSMenu(title: "Main Menu")
        for placement in MenuPlacement.allCases {
            let submenu = NSMenu(title: title(for: placement, applicationName: applicationName))
            let rootItem = NSMenuItem()
            rootItem.title = submenu.title
            rootItem.submenu = submenu
            mainMenu.addItem(rootItem)

            for descriptor in descriptors where descriptor.placement == placement {
                submenu.addItem(makeItem(from: descriptor))
            }
        }
        return mainMenu
    }

    private func makeItem(from descriptor: MenuDescriptor) -> NSMenuItem {
        let equivalent = descriptor.keyEquivalent.flatMap(AppKitKeyEquivalent.init(token:))
        let item = NSMenuItem(
            title: descriptor.title,
            action: #selector(MenuActionTarget.performAction(_:)),
            keyEquivalent: equivalent?.characters ?? ""
        )
        item.target = actionTarget
        item.keyEquivalentModifierMask = equivalent?.modifiers ?? []
        item.representedObject = descriptor.actionID.rawValue
        item.identifier = NSUserInterfaceItemIdentifier(descriptor.identifier)
        item.setAccessibilityIdentifier("menu.\(descriptor.identifier)")
        return item
    }

    private func title(for placement: MenuPlacement, applicationName: String) -> String {
        switch placement {
        case .application: applicationName
        case .file: "File"
        case .tabs: "Tabs"
        case .navigation: "Navigation"
        case .find: "Find"
        case .view: "View"
        }
    }
}

@MainActor
private final class MenuActionTarget: NSObject {
    private let dispatch: (ActionID) -> Void

    init(dispatch: @escaping (ActionID) -> Void) {
        self.dispatch = dispatch
    }

    @objc func performAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let action = ActionID(rawValue: rawValue)
        else {
            assertionFailure("Validated menu item lost its action identifier")
            return
        }
        dispatch(action)
    }
}

private struct AppKitKeyEquivalent {
    let characters: String
    let modifiers: NSEvent.ModifierFlags

    init?(token: KeyToken) {
        guard token.isAppKitRepresentable else { return nil }
        switch token.symbol {
        case let .character(character):
            self.characters = character
        case let .named(key):
            guard let characters = Self.characters(for: key) else { return nil }
            self.characters = characters
        case .deadKey, .imeComposition:
            return nil
        }

        var modifiers: NSEvent.ModifierFlags = []
        if token.modifiers.contains(.command) { modifiers.insert(.command) }
        if token.modifiers.contains(.control) { modifiers.insert(.control) }
        if token.modifiers.contains(.option) { modifiers.insert(.option) }
        if token.modifiers.contains(.shift) { modifiers.insert(.shift) }
        self.modifiers = modifiers
    }

    private static func characters(for key: NamedKey) -> String? {
        switch key {
        case .escape: return "\u{1B}"
        case .carriageReturn: return "\r"
        case .backspace: return "\u{08}"
        case .deleteForward: return functionKey(NSDeleteFunctionKey)
        case .tab: return "\t"
        case .left: return functionKey(NSLeftArrowFunctionKey)
        case .right: return functionKey(NSRightArrowFunctionKey)
        case .up: return functionKey(NSUpArrowFunctionKey)
        case .down: return functionKey(NSDownArrowFunctionKey)
        case .home: return functionKey(NSHomeFunctionKey)
        case .end: return functionKey(NSEndFunctionKey)
        case .pageUp: return functionKey(NSPageUpFunctionKey)
        case .pageDown: return functionKey(NSPageDownFunctionKey)
        case .space: return " "
        case .backtick: return "`"
        case .lessThan: return "<"
        case .greaterThan: return ">"
        case .plus: return "+"
        case .minus: return "-"
        case .equal: return "="
        case .slash: return "/"
        case let .function(number):
            guard (1...24).contains(number) else { return nil }
            return functionKey(NSF1FunctionKey + number - 1)
        }
    }

    private static func functionKey(_ value: Int) -> String? {
        UnicodeScalar(value).map(String.init)
    }
}
