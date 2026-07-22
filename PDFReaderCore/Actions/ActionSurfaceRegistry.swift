import Foundation

public enum ActionSurfaceKind: String, Codable, CaseIterable, Sendable {
    case keyBinding
    case menuItem
    case promptControl
    case emptyStateControl
    case tabControl
}

public struct ActionSurfaceDescriptor: Equatable, Sendable {
    public let identifier: String
    public let kind: ActionSurfaceKind
    public let actionID: ActionID

    public init(identifier: String, kind: ActionSurfaceKind, actionID: ActionID) {
        self.identifier = identifier
        self.kind = kind
        self.actionID = actionID
    }
}

public enum ActionSurfaceIssue: Equatable, Sendable {
    case duplicateIdentifier(String)
    case orphanSurface(String, ActionID)
    case actionWithoutSurface(ActionID)
}

public enum ActionSurfaceRegistry {
    public static let v1: [ActionSurfaceDescriptor] = {
        let keySurfaces = ActionRegistry.v1.actionIDs.map { actionID in
            ActionSurfaceDescriptor(
                identifier: "key.\(actionID.rawValue)",
                kind: .keyBinding,
                actionID: actionID
            )
        }
        let menuSurfaces = MenuItemRegistry.v1.map { definition in
            ActionSurfaceDescriptor(
                identifier: "menu.\(definition.identifier)",
                kind: .menuItem,
                actionID: definition.actionID
            )
        }
        let controls = [
            ActionSurfaceDescriptor(identifier: "empty.open", kind: .emptyStateControl, actionID: .documentOpen),
            ActionSurfaceDescriptor(identifier: "tab.select.next", kind: .tabControl, actionID: .tabNext),
            ActionSurfaceDescriptor(identifier: "tab.select.previous", kind: .tabControl, actionID: .tabPrevious),
            ActionSurfaceDescriptor(identifier: "tab.close", kind: .tabControl, actionID: .documentClose),
            ActionSurfaceDescriptor(identifier: "prompt.commit", kind: .promptControl, actionID: .promptCommit),
            ActionSurfaceDescriptor(identifier: "prompt.cancel", kind: .promptControl, actionID: .promptCancel),
            ActionSurfaceDescriptor(identifier: "search.clear", kind: .promptControl, actionID: .searchCancel),
        ]
        return keySurfaces + menuSurfaces + controls
    }()

    public static func validate(
        _ surfaces: [ActionSurfaceDescriptor] = v1,
        against registry: ActionRegistry = .v1
    ) -> [ActionSurfaceIssue] {
        var issues: [ActionSurfaceIssue] = []
        let groupedIdentifiers = Dictionary(grouping: surfaces, by: \.identifier)
        for identifier in groupedIdentifiers.keys.sorted() where groupedIdentifiers[identifier, default: []].count > 1 {
            issues.append(.duplicateIdentifier(identifier))
        }

        let knownActions = Set(registry.actionIDs)
        for surface in surfaces where !knownActions.contains(surface.actionID) {
            issues.append(.orphanSurface(surface.identifier, surface.actionID))
        }
        let surfacedActions = Set(surfaces.map(\.actionID))
        for actionID in registry.actionIDs where !surfacedActions.contains(actionID) {
            issues.append(.actionWithoutSurface(actionID))
        }
        return issues
    }
}
