import Foundation

/// Shared action membership and ordering for help and shortcut settings.
/// Membership never depends on the currently assigned key, so unbinding a
/// command cannot remove the row needed to bind it again.
public enum ActionHelpCatalog {
    public struct Section: Sendable {
        public let title: String
        public let actions: [ActionID]
    }

    public static var sections: [Section] {
        var titles: [String] = []
        var grouped: [String: [ActionID]] = [:]
        for descriptor in ActionRegistry.v1.descriptors {
            // Prompt confirmation/cancellation is native UI operation, not a
            // reader command. Search result navigation remains in keyboard help.
            guard descriptor.id != .promptCommit, descriptor.id != .promptCancel else { continue }
            let title = BuiltInDefaults.categoryTitle(for: descriptor.id)
            if grouped[title] == nil { titles.append(title) }
            grouped[title, default: []].append(descriptor.id)
        }
        return titles.map { Section(title: $0, actions: grouped[$0, default: []]) }
    }

    public static func isEditableInSettings(_ action: ActionID) -> Bool {
        guard let descriptor = ActionRegistry.v1.descriptor(for: action), !descriptor.isFixedBinding else { return false }
        let foundations = FoundationalBindings.sequences(for: action)
        return foundations.isEmpty || !BuiltInDefaults.editableTemplatedKeymap[action, default: []].isEmpty
    }
}
