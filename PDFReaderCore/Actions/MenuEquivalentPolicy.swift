import Foundation

public enum MenuPlacement: String, CaseIterable, Codable, Sendable {
    case application
    case file
    case tabs
    case navigation
    case find
    case view
}

public struct MenuItemDefinition: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let actionID: ActionID
    public let placement: MenuPlacement

    public init(identifier: String, title: String, actionID: ActionID, placement: MenuPlacement) {
        self.identifier = identifier
        self.title = title
        self.actionID = actionID
        self.placement = placement
    }
}

public struct MenuDescriptor: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let actionID: ActionID
    public let placement: MenuPlacement
    public let keyEquivalent: KeyToken?

    public init(
        identifier: String,
        title: String,
        actionID: ActionID,
        placement: MenuPlacement,
        keyEquivalent: KeyToken?
    ) {
        self.identifier = identifier
        self.title = title
        self.actionID = actionID
        self.placement = placement
        self.keyEquivalent = keyEquivalent
    }
}

public enum MenuItemRegistry {
    public static let v1: [MenuItemDefinition] = [
        MenuItemDefinition(identifier: "application.quit", title: "Quit PDF Reader", actionID: .appQuit, placement: .application),
        MenuItemDefinition(identifier: "file.open", title: "Open PDF…", actionID: .documentOpen, placement: .file),
        MenuItemDefinition(identifier: "file.close", title: "Close PDF", actionID: .documentClose, placement: .file),
        MenuItemDefinition(identifier: "tabs.next", title: "Next Tab", actionID: .tabNext, placement: .tabs),
        MenuItemDefinition(identifier: "tabs.previous", title: "Previous Tab", actionID: .tabPrevious, placement: .tabs),
        MenuItemDefinition(identifier: "navigation.next-page", title: "Next Page", actionID: .pageNext, placement: .navigation),
        MenuItemDefinition(identifier: "navigation.previous-page", title: "Previous Page", actionID: .pagePrevious, placement: .navigation),
        MenuItemDefinition(identifier: "navigation.first-page", title: "First Page", actionID: .pageFirst, placement: .navigation),
        MenuItemDefinition(identifier: "navigation.last-page", title: "Last Page", actionID: .pageLast, placement: .navigation),
        MenuItemDefinition(identifier: "navigation.go-to-page", title: "Go to Page…", actionID: .pagePrompt, placement: .navigation),
        MenuItemDefinition(identifier: "find.prompt", title: "Find…", actionID: .searchPrompt, placement: .find),
        MenuItemDefinition(identifier: "find.next", title: "Find Next", actionID: .searchNext, placement: .find),
        MenuItemDefinition(identifier: "find.previous", title: "Find Previous", actionID: .searchPrevious, placement: .find),
        MenuItemDefinition(identifier: "find.clear", title: "Clear Search", actionID: .searchCancel, placement: .find),
        MenuItemDefinition(identifier: "view.zoom-in", title: "Zoom In", actionID: .viewZoomIn, placement: .view),
        MenuItemDefinition(identifier: "view.zoom-out", title: "Zoom Out", actionID: .viewZoomOut, placement: .view),
        MenuItemDefinition(identifier: "view.actual-size", title: "Actual Size", actionID: .viewZoomReset, placement: .view),
        MenuItemDefinition(identifier: "view.fit-width", title: "Fit Width", actionID: .viewFitWidth, placement: .view),
        MenuItemDefinition(identifier: "view.fit-page", title: "Fit Page", actionID: .viewFitPage, placement: .view),
    ]
}

public enum MenuEquivalentPolicy {
    public static func makeDescriptors(
        definitions: [MenuItemDefinition] = MenuItemRegistry.v1,
        evaluatedBindings: [ActionID: [EvaluatedActionBinding]],
        registry: ActionRegistry = .v1
    ) -> [MenuDescriptor] {
        definitions.map { definition in
            let equivalent = eligibleEquivalent(
                for: definition.actionID,
                evaluatedBindings: evaluatedBindings,
                registry: registry
            )
            return MenuDescriptor(
                identifier: definition.identifier,
                title: definition.title,
                actionID: definition.actionID,
                placement: definition.placement,
                keyEquivalent: equivalent
            )
        }
    }

    private static func eligibleEquivalent(
        for actionID: ActionID,
        evaluatedBindings: [ActionID: [EvaluatedActionBinding]],
        registry: ActionRegistry
    ) -> KeyToken? {
        guard registry.descriptor(for: actionID)?.scope == .global else { return nil }
        let candidates = (evaluatedBindings[actionID] ?? []).sorted { $0.bindingOrder < $1.bindingOrder }
        for candidate in candidates {
            guard candidate.promptSafety.isValid,
                  let token = candidate.sequence.singleToken,
                  token.isAppKitRepresentable,
                  isGloballyUnique(candidate.sequence, in: evaluatedBindings)
            else {
                continue
            }
            return token
        }
        return nil
    }

    private static func isGloballyUnique(
        _ sequence: KeySequence,
        in evaluatedBindings: [ActionID: [EvaluatedActionBinding]]
    ) -> Bool {
        let owners = evaluatedBindings.compactMap { actionID, bindings in
            bindings.contains { $0.promptSafety.isValid && $0.sequence == sequence } ? actionID : nil
        }
        return owners.count == 1
    }
}
